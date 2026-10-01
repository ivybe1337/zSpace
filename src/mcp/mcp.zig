//! zspace-mcp — stdio Model Context Protocol server for ZSpace.
//!
//! Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout, exactly as the
//! MCP stdio spec requires. **stdout carries protocol frames only** — every
//! diagnostic goes to stderr, because a stray byte on stdout corrupts the
//! stream for the host agent.
//!
//! Design rules that are not negotiable (see docs/MASTER_PLAN.md §6):
//!   1. Tool handlers call the *same* core functions the CLI calls. There is no
//!      second implementation to drift.
//!   2. Read-only by default. Destructive tools require an explicit
//!      `allow_write: true` argument and always return a receipt, so `undo` is
//!      one call away.
//!   3. Paths are emitted as JSON **data**, never as prose. A filename is
//!      attacker-controlled input; it must never be able to read as an
//!      instruction to the calling model.
//!   4. `clean_propose` never mutates. Only `clean_apply` does.

const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const cleaner = @import("../core/cleaner.zig");
const snapshot_mod = @import("../core/snapshot.zig");
const disks = @import("../core/disks.zig");
const json = @import("../core/json.zig");
const tui_select = @import("../core/tui_select.zig");
const classifier = @import("../core/classifier.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
});

extern "c" fn __error() *c_int;

pub const PROTOCOL_VERSION = "2024-11-05";
pub const SERVER_NAME = "zspace";
pub const SERVER_VERSION = "0.1.0";

/// JSON-RPC 2.0 error codes.
const PARSE_ERROR: i32 = -32700;
const INVALID_REQUEST: i32 = -32600;
const METHOD_NOT_FOUND: i32 = -32601;
const INVALID_PARAMS: i32 = -32602;
const INTERNAL_ERROR: i32 = -32603;

fn logStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(2, slice.ptr, slice.len);
    _ = c.write(2, "\n".ptr, 1);
}

/// Write every byte to fd 1. Partial writes are possible on a pipe, so loop.
/// A closed consumer (EPIPE) means the host is gone; stop quietly.
fn writeStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(1, (bytes.ptr + off), bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// Newline-delimited frame reader over fd 0.
///
/// A returned slice is valid only until the next call to `next()`: the buffer
/// is compacted in place between reads. Callers must fully process a message
/// before asking for the following one (which is how the dispatcher works).
const LineReader = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 },
    start: usize = 0,
    eof: bool = false,

    fn deinit(self: *LineReader) void {
        self.buf.deinit(self.allocator);
    }

    /// Next complete line without its trailing '\n', or null at end of input.
    fn next(self: *LineReader) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf.items[self.start..], '\n')) |rel| {
                const line = self.buf.items[self.start .. self.start + rel];
                self.start += rel + 1;
                return line;
            }
            if (self.eof) {
                if (self.start >= self.buf.items.len) return null;
                const line = self.buf.items[self.start..];
                self.start = self.buf.items.len;
                return if (line.len == 0) null else line;
            }
            // Compact the consumed prefix so a long-lived session cannot grow
            // the buffer without bound.
            if (self.start > 0) {
                const rem = self.buf.items.len - self.start;
                std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[self.start..]);
                self.buf.items.len = rem;
                self.start = 0;
            }
            var chunk: [64 * 1024]u8 = undefined;
            const n = c.read(0, &chunk, chunk.len);
            if (n < 0) {
                if (__error().* == c.EINTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) {
                self.eof = true;
                continue;
            }
            try self.buf.appendSlice(self.allocator, chunk[0..@intCast(n)]);
        }
    }
};

// --- Response framing -------------------------------------------------------

/// Serialize the request id. std.json.Value discards the original token text, so
/// numbers are re-rendered here (integers stay integers — a float id would
/// break strict JSON-RPC clients).
fn writeId(w: *json.JsonWriter, id: ?std.json.Value) !void {
    const v = id orelse {
        try w.writeAll("null");
        return;
    };
    switch (v) {
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try json.writeJsonEscaped(s, w),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

fn sendFramed(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), id: ?std.json.Value, payload_key: []const u8, payload_json: []const u8) void {
    out_buf.clearRetainingCapacity();
    var w = json.JsonWriter{ .list = out_buf, .allocator = allocator };
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    writeId(&w, id) catch return;
    w.writeAll(",\"") catch return;
    w.writeAll(payload_key) catch return;
    w.writeAll("\":") catch return;
    w.writeAll(payload_json) catch return;
    w.writeAll("}\n") catch return;
    writeStdout(out_buf.items);
}

fn sendResult(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), id: ?std.json.Value, result_json: []const u8) void {
    sendFramed(allocator, out_buf, id, "result", result_json);
}

fn sendError(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), id: ?std.json.Value, code: i32, message: []const u8) void {
    out_buf.clearRetainingCapacity();
    var w = json.JsonWriter{ .list = out_buf, .allocator = allocator };
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    writeId(&w, id) catch return;
    w.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch return;
    json.writeJsonEscaped(message, &w) catch return;
    w.writeAll("}}\n") catch return;
    writeStdout(out_buf.items);
}

/// tools/call result envelope: a single text content block carrying JSON.
/// `is_error` maps to the protocol's `isError` flag (a *tool* failure, not a
/// transport failure).
fn sendToolResult(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), id: ?std.json.Value, text_json: []const u8, is_error: bool) void {
    out_buf.clearRetainingCapacity();
    var w = json.JsonWriter{ .list = out_buf, .allocator = allocator };
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    writeId(&w, id) catch return;
    w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":") catch return;
    json.writeJsonEscaped(text_json, &w) catch return;
    w.writeAll("}],\"isError\":") catch return;
    w.writeAll(if (is_error) "true" else "false") catch return;
    w.writeAll("}}\n") catch return;
    writeStdout(out_buf.items);
}

/// Escape a string into a fresh temp buffer and return a json.JsonWriter aimed
/// at it. Used to build nested objects inside tool output.
fn beginJsonObject(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) json.JsonWriter {
    buf.clearRetainingCapacity();
    return json.JsonWriter{ .list = buf, .allocator = allocator };
}

const ToolError = error{
    MissingArgument,
    InvalidArgument,
    WriteNotAllowed,
};

fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: ?std.json.Value, key: []const u8) ?i64 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn argBoolOr(args: ?std.json.Value, key: []const u8, default: bool) bool {
    const a = args orelse return default;
    if (a != .object) return default;
    const v = a.object.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}

fn requireString(args: ?std.json.Value, key: []const u8) ToolError![]const u8 {
    return argString(args, key) orelse ToolError.MissingArgument;
}

/// Destructive tools must be opted into explicitly, per call. There is no
/// session-level "allow write" switch, so a prompt-injected instruction cannot
/// escalate once the host has started a read-only session.
fn requireWrite(args: ?std.json.Value) ToolError!void {
    if (!argBoolOr(args, "allow_write", false)) return ToolError.WriteNotAllowed;
}

fn writePathField(w: *json.JsonWriter, key: []const u8, value: []const u8) !void {
    try w.writeAll("\"");
    try w.writeAll(key);
    try w.writeAll("\":");
    try json.writeJsonEscaped(value, w);
}

fn riskLabel(r: analyzer.RiskLevel) []const u8 {
    return switch (r) {
        .Safe_ZeroRisk => "safe",
        .Recommended_Cache => "recommended",
        .Review_Needed => "review",
        .Locked_Danger => "locked",
    };
}

// --- Tool catalogue ---------------------------------------------------------
// Declared as one static document: the schemas are part of the wire contract
// and are far easier to audit as literal text than as assembled strings.

const TOOLS_JSON =
    \\{"tools":[
    \\{"name":"scan","description":"Scan a directory tree and return aggregate sizes plus the largest files. Read-only.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute directory path to scan."},"top":{"type":"integer","description":"How many largest files to return (default 10, max 200)."}},"required":["path"]}},
    \\{"name":"drives","description":"List mounted volumes with capacity, usage and APFS/SIP status. Read-only.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"dedup","description":"Find duplicate files using the 3-tier engine (size, sparse sample, full Blake3). Report only, never modifies.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory to analyse."},"min_size":{"type":"integer","description":"Ignore files smaller than this many bytes (default 1024)."}},"required":["path"]}},
    \\{"name":"clean_propose","description":"Propose numbered cleanup candidates with a risk rating. Never mutates anything. Pass the returned ids to clean_apply.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory to analyse."},"limit":{"type":"integer","description":"Maximum candidates to return (default 50, max 500)."}},"required":["path"]}},
    \\{"name":"clean_apply","description":"Move the selected candidates to the macOS Trash and return a receipt for each. DESTRUCTIVE: requires allow_write=true. Pass dry_run=true to preview.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory the ids were proposed from."},"select":{"type":"string","description":"Selection spec: \"3\" | \"3,7,12\" | \"3-7\" | \"safe\" | \"all\" | \"none\"."},"allow_write":{"type":"boolean","description":"Must be true or the call is refused."},"dry_run":{"type":"boolean","description":"Preview only; default false."},"limit":{"type":"integer","description":"Must match the limit used for clean_propose (default 50)."}},"required":["path","select","allow_write"]}},
    \\{"name":"history","description":"Return recent trash journal entries as raw JSON objects, newest last. Read-only.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Maximum entries (default 50, max 1000)."}}}},
    \\{"name":"undo","description":"Restore a trashed item by receipt id and verify its Blake3 digest. DESTRUCTIVE: requires allow_write=true.","inputSchema":{"type":"object","properties":{"receipt":{"type":"string","description":"Receipt id from clean_apply or history."},"allow_write":{"type":"boolean","description":"Must be true or the call is refused."}},"required":["receipt","allow_write"]}},
    \\{"name":"snapshot_save","description":"Write a ZSNP2 snapshot of a tree (per-file Blake3 + mtime) for later diffing.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory to snapshot."},"output":{"type":"string","description":"Destination .zsnap file path."}},"required":["path","output"]}},
    \\{"name":"snapshot_diff","description":"Diff two snapshots, reporting added/removed/grew/shrunk paths with byte deltas, largest first. Read-only.","inputSchema":{"type":"object","properties":{"a":{"type":"string","description":"Earlier .zsnap file."},"b":{"type":"string","description":"Later .zsnap file."}},"required":["a","b"]}}
    \\,{"name":"index_status","description":"Inspect the local optional index cache without creating it.","inputSchema":{"type":"object","properties":{}}}
    \\]}
;

fn clampInt(v: ?i64, default: i64, min: i64, max: i64) i64 {
    const raw = v orelse default;
    return @max(min, @min(max, raw));
}

// --- Tool implementations ---------------------------------------------------
// Every handler runs against a per-request arena, so a tool can allocate a full
// DiskNode tree without any cleanup choreography: the arena resets once the
// response has been written.

const ToolOutcome = struct {
    text: []const u8,
    is_error: bool = false,
};

fn ok(text: []const u8) ToolOutcome {
    return .{ .text = text, .is_error = false };
}

fn fail(text: []const u8) ToolOutcome {
    return .{ .text = text, .is_error = true };
}

fn toolScan(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const path = try requireString(args, "path");
    const top = @as(usize, @intCast(clampInt(argInt(args, "top"), 10, 0, 200)));

    var sc = scanner.Scanner.init(arena, .{});
    defer sc.deinit();

    const t0 = types.getMonotonicNs();
    const root = try sc.scan(path);
    const t1 = types.getMonotonicNs();

    var an = analyzer.Analyzer.init(arena);
    const largest = try an.findTopLargestFiles(root, top);

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{");
    try writePathField(&w, "path", root.path);
    const status = @tagName(sc.last_status);
    try w.print(",\"status\":\"{s}\",\"complete\":{s},\"total_bytes\":{d},\"allocated_bytes\":{d},\"file_count\":{d},\"dir_count\":{d},\"errors\":{d},\"elapsed_ms\":{d:.2},\"truncated\":{s}",
        .{ status,
            if (sc.last_status == .complete) "true" else "false",
            root.size_bytes, root.allocated_bytes, root.file_count, root.dir_count,
            sc.telemetry.errors_count,
            @as(f64, @floatFromInt(t1 - t0)) / 1_000_000.0,
            if (sc.last_status != .complete) "true" else "false" });
    try w.writeAll(",\"top_files\":[");
    for (largest.items, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writePathField(&w, "path", f.path);
        try w.print(",\"size_bytes\":{d},\"mtime_ns\":{d}}}", .{ f.size_bytes, f.mtime_ns });
    }
    try w.writeAll("]}");
    return ok(w.list.items);
}

fn toolDrives(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    _ = args;
    var dm = disks.DiskMapper.init(arena);
    const vols = try dm.listVolumes();

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"volumes\":[");
    for (vols.items, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writePathField(&w, "mount_point", v.mount_point);
        try w.writeAll(",");
        try writePathField(&w, "device", v.device_name);
        try w.writeAll(",");
        try writePathField(&w, "fs_type", v.fs_type);
        try w.writeAll(",");
        try writePathField(&w, "status", v.status_label);
        try w.print(",\"total_bytes\":{d},\"used_bytes\":{d},\"free_bytes\":{d},\"percent_used\":{d:.1},\"system_locked\":{s}}}",
            .{ v.total_bytes, v.used_bytes, v.free_bytes, v.percent_used, if (v.is_system_locked) "true" else "false" });
    }
    try w.writeAll("]}");
    return ok(w.list.items);
}

fn toolDedup(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const path = try requireString(args, "path");
    const min_size = @as(u64, @intCast(clampInt(argInt(args, "min_size"), 1024, 0, std.math.maxInt(i64))));

    var sc = scanner.Scanner.init(arena, .{});
    defer sc.deinit();
    const root = try sc.scan(path);
    if (sc.last_status != .complete) return fail("scan was incomplete; duplicate results withheld");

    var eng = dedup.DedupEngine.init(arena);
    eng.min_size_bytes = min_size;
    const clusters = try eng.findDuplicates(root);

    var total_wasted: u64 = 0;
    for (clusters.items) |cl| total_wasted += cl.total_wasted_bytes;

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"clusters\":[");
    for (clusters.items, 0..) |cl, ci| {
        if (ci > 0) try w.writeAll(",");
        try w.print("{{\"size_each\":{d},\"duplicate_candidate_bytes\":{d},\"estimated_recoverable_bytes\":null,\"shared_allocation\":\"unknown\",\"copies\":{d},\"files\":[", .{ cl.size_each, cl.total_wasted_bytes, cl.items.items.len });
        for (cl.items.items, 0..) |it, ii| {
            if (ii > 0) try w.writeAll(",");
            try w.writeAll("{");
            try writePathField(&w, "path", it.path);
            try w.print(",\"size_bytes\":{d},\"is_original\":{s}}}", .{ it.size_bytes, if (it.is_original) "true" else "false" });
        }
        try w.writeAll("]}");
    }
    try w.print("],\"cluster_count\":{d},\"duplicate_candidate_bytes\":{d},\"estimated_recoverable_bytes\":null}}", .{ clusters.items.len, total_wasted });
    return ok(w.list.items);
}

// --- Cleanup proposal/apply -------------------------------------------------
// clean_propose and clean_apply MUST derive an identical candidate set, or an
// agent could apply an id that means something else. Both therefore call
// `collectCandidates` — one implementation, no drift.

/// Deterministic total order: size descending, ties broken by the analyzer's
/// stable id. Without the id tiebreak, equal-size candidates could permute
/// between the propose call and the apply call.
fn bySizeDesc(_: void, a: analyzer.SmartCleanItem, b: analyzer.SmartCleanItem) bool {
    if (a.size_bytes != b.size_bytes) return a.size_bytes > b.size_bytes;
    return a.id < b.id;
}

fn collectCandidates(
    arena: std.mem.Allocator,
    root: *const types.DiskNode,
    limit: usize,
) !std.ArrayList(analyzer.SmartCleanItem) {
    var an = analyzer.Analyzer.init(arena);
    var items = try an.generateSmartCleanRecommendations(root);
    std.mem.sort(analyzer.SmartCleanItem, items.items, {}, bySizeDesc);
    if (items.items.len > limit) items.items.len = limit;
    return items;
}

/// Map a selection spec onto `items` by matching the *proposal id*. Matching by
/// array position would be a silent-retarget hazard if ordering ever changed.
fn maskFromSpec(
    arena: std.mem.Allocator,
    spec: []const u8,
    items: []const analyzer.SmartCleanItem,
) ![]bool {
    const mask = try arena.alloc(bool, items.len);
    @memset(mask, false);

    if (std.ascii.eqlIgnoreCase(spec, "all")) {
        @memset(mask, true);
        return mask;
    }
    if (std.ascii.eqlIgnoreCase(spec, "none")) return mask;
    if (std.ascii.eqlIgnoreCase(spec, "safe")) {
        for (items, 0..) |it, i| mask[i] = it.risk == .Safe_ZeroRisk;
        return mask;
    }

    var toks = std.mem.splitScalar(u8, spec, ',');
    while (toks.next()) |raw_tok| {
        const tok = std.mem.trim(u8, raw_tok, " \t");
        if (tok.len == 0) continue;
        if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, std.mem.trim(u8, tok[0..dash], " "), 10) catch return ToolError.InvalidArgument;
            const hi = std.fmt.parseInt(usize, std.mem.trim(u8, tok[dash + 1 ..], " "), 10) catch return ToolError.InvalidArgument;
            if (lo > hi) return ToolError.InvalidArgument;
            for (items, 0..) |it, i| {
                if (it.id >= lo and it.id <= hi) mask[i] = true;
            }
        } else {
            const id = std.fmt.parseInt(usize, tok, 10) catch return ToolError.InvalidArgument;
            for (items, 0..) |it, i| {
                if (it.id == id) mask[i] = true;
            }
        }
    }
    return mask;
}

fn toolCleanPropose(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const path = try requireString(args, "path");
    const limit = @as(usize, @intCast(clampInt(argInt(args, "limit"), 50, 1, 500)));

    var sc = scanner.Scanner.init(arena, .{});
    defer sc.deinit();
    const root = try sc.scan(path);
    if (sc.last_status != .complete) return fail("scan was incomplete; cleanup proposal withheld");
    const items = try collectCandidates(arena, root, limit);

    var total: u64 = 0;
    for (items.items) |it| total += it.size_bytes;

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"candidates\":[");
    for (items.items, 0..) |it, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},", .{it.id});
        try writePathField(&w, "title", it.title);
        try w.writeAll(",");
        try writePathField(&w, "path", it.path);
        try w.writeAll(",");
        try writePathField(&w, "description", it.description);
        try w.writeAll(",");
        try writePathField(&w, "risk", riskLabel(it.risk));
        try w.print(",\"size_bytes\":{d},\"item_count\":{d},\"quick_win\":{s}}}", .{
            it.size_bytes, it.item_count, if (it.is_quick_win) "true" else "false",
        });
    }
    try w.print("],\"candidate_count\":{d},\"candidate_logical_bytes\":{d},\"estimated_recoverable_bytes\":null,\"limit\":{d},\"mutated\":false}}", .{ items.items.len, total, limit });
    return ok(w.list.items);
}

/// Append one `{...}` object to a JSON array buffer, inserting the separator
/// only when the array already has content.
fn arrPushComma(allocator: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    if (list.items.len > 0) try list.appendSlice(allocator, ",");
}

fn toolCleanApply(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    try requireWrite(args);
    const path = try requireString(args, "path");
    const spec = try requireString(args, "select");
    const limit = @as(usize, @intCast(clampInt(argInt(args, "limit"), 50, 1, 500)));
    const dry_run = argBoolOr(args, "dry_run", false);

    var sc = scanner.Scanner.init(arena, .{});
    defer sc.deinit();
    const root = try sc.scan(path);
    if (sc.last_status != .complete) return fail("scan was incomplete; cleanup withheld");
    const items = try collectCandidates(arena, root, limit);

    const mask = maskFromSpec(arena, spec, items.items) catch {
        return fail("{\"error\":\"invalid_select\",\"detail\":\"expected 3 | 3,7 | 3-7 | safe | all | none\"}");
    };

    var cl = try cleaner.Cleaner.init(arena);

    // The two arrays are built independently so separators can never desync.
    var applied: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    var refused: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    var applied_n: usize = 0;
    var refused_n: usize = 0;
    var freed: u64 = 0;

    for (items.items, 0..) |it, i| {
        if (!mask[i]) continue;

        // LOCKED candidates are never actionable, even when explicitly named.
        if (it.risk.isLocked()) {
            try arrPushComma(arena, &refused);
            var rw = json.JsonWriter{ .list = &refused, .allocator = arena };
            try rw.print("{{\"id\":{d},", .{it.id});
            try writePathField(&rw, "path", it.path);
            try rw.writeAll(",\"reason\":\"system_locked\"}");
            refused_n += 1;
            continue;
        }

        // Re-derive protection independently instead of trusting the proposal
        // list: the agent-facing layer must not be the weakest one.
        const protection = classifier.classifyProtection(it.path);
        if (protection.isProtected()) {
            try arrPushComma(arena, &refused);
            var rw = json.JsonWriter{ .list = &refused, .allocator = arena };
            try rw.print("{{\"id\":{d},", .{it.id});
            try writePathField(&rw, "path", it.path);
            try rw.writeAll(",\"reason\":\"protected\"}");
            refused_n += 1;
            continue;
        }

        if (dry_run) {
            try arrPushComma(arena, &applied);
            var aw = json.JsonWriter{ .list = &applied, .allocator = arena };
            try aw.print("{{\"id\":{d},", .{it.id});
            try writePathField(&aw, "path", it.path);
            try aw.print(",\"size_bytes\":{d},\"would_trash\":true,\"receipt\":null}}", .{it.size_bytes});
            applied_n += 1;
            freed += it.size_bytes;
            continue;
        }

        const op = cl.safeMoveToTrash(it.path, it.size_bytes, protection) catch |err| {
            try arrPushComma(arena, &refused);
            var rw = json.JsonWriter{ .list = &refused, .allocator = arena };
            try rw.print("{{\"id\":{d},", .{it.id});
            try writePathField(&rw, "path", it.path);
            try rw.writeAll(",\"reason\":");
            try json.writeJsonEscaped(@errorName(err), &rw);
            try rw.writeAll("}");
            refused_n += 1;
            continue;
        };

        try arrPushComma(arena, &applied);
        var aw = json.JsonWriter{ .list = &applied, .allocator = arena };
        try aw.print("{{\"id\":{d},", .{it.id});
        try writePathField(&aw, "path", op.original_path);
        try aw.writeAll(",");
        try writePathField(&aw, "trash_path", op.trash_path);
        try aw.writeAll(",");
        try writePathField(&aw, "receipt", op.receipt_id);
        try aw.print(",\"size_bytes\":{d},\"would_trash\":false}}", .{op.size_bytes});
        applied_n += 1;
        freed += op.size_bytes;
    }

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"applied\":[");
    try w.writeAll(applied.items);
    try w.writeAll("],\"refused\":[");
    try w.writeAll(refused.items);
    try w.print("],\"applied_count\":{d},\"refused_count\":{d},\"selected_logical_bytes\":{d},\"measured_freed_bytes\":null,\"dry_run\":{s},\"undo_hint\":\"undo accepts any returned receipt\"}}", .{
        applied_n, refused_n, freed, if (dry_run) "true" else "false",
    });
    return ok(w.list.items);
}

fn toolHistory(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const limit = @as(usize, @intCast(clampInt(argInt(args, "limit"), 20, 1, 200)));
    var cl = cleaner.Cleaner.init(arena) catch |err| return fail(@errorName(err));
    defer cl.deinit();

    var entries = cl.readJournalTail(arena, limit) catch |err| return fail(@errorName(err));
    defer {
        for (entries.items) |e| arena.free(e.line);
        entries.deinit(arena);
    }

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"operations\":[");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(e.line);
    }
    try w.print("],\"count\":{d}}}", .{entries.items.len});
    return ok(w.list.items);
}

fn toolUndo(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    try requireWrite(args);
    const receipt = try requireString(args, "receipt");

    var cl = cleaner.Cleaner.init(arena) catch |err| return fail(@errorName(err));
    defer cl.deinit();

    const op = cl.undoByReceipt(receipt) catch |err| return fail(@errorName(err));

    var w = beginJsonObject(arena, buf);
    try w.writeAll("{\"status\":\"restored\",\"receipt\":");
    try json.writeJsonEscaped(receipt, &w);
    try w.writeAll(",");
    try writePathField(&w, "restored_path", op.original_path);
    try w.print(",\"size_bytes\":{d}}}", .{op.size_bytes});
    return ok(w.list.items);
}

fn toolSnapshot(arena: std.mem.Allocator, args: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const action = argString(args, "action") orelse "diff";
    var engine = snapshot_mod.SnapshotEngine.init(arena);

    if (std.mem.eql(u8, action, "save")) {
        const path = try requireString(args, "path");
        const out_path = try requireString(args, "output_path");

        var sc = scanner.Scanner.init(arena, .{});
        defer sc.deinit();
        const root = sc.scan(path) catch |err| return fail(@errorName(err));

        engine.saveSnapshot(root, out_path) catch |err| return fail(@errorName(err));

        var w = beginJsonObject(arena, buf);
        try w.writeAll("{\"status\":\"saved\",\"snapshot_file\":");
        try json.writeJsonEscaped(out_path, &w);
        try w.writeAll("}");
        return ok(w.list.items);
    } else if (std.mem.eql(u8, action, "diff")) {
        const snap_a = try requireString(args, "snapshot_a");
        const snap_b = try requireString(args, "snapshot_b");

        var diffs = engine.compareSnapshots(snap_a, snap_b) catch |err| return fail(@errorName(err));
        defer diffs.deinit(arena);

        var w = beginJsonObject(arena, buf);
        try w.writeAll("{\"diffs\":[");
        for (diffs.items, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"path\":", .{});
            try json.writeJsonEscaped(d.path, &w);
            try w.print(",\"kind\":\"{s}\",\"old_size\":{d},\"new_size\":{d}}}", .{
                @tagName(d.status), d.old_size, d.new_size,
            });
        }
        try w.print("],\"count\":{d}}}", .{diffs.items.len});
        return ok(w.list.items);
    }

    return fail("action must be 'save' or 'diff'");
}

fn toolIndexStatus(arena: std.mem.Allocator, _: ?std.json.Value, buf: *std.ArrayList(u8)) !ToolOutcome {
    const cache_path = "/Users/joshua/Library/Caches/ZSpace/index.zsnap";
    var exists = false;
    var size_bytes: u64 = 0;

    var st: c.struct_stat = undefined;
    if (c.stat(cache_path, &st) == 0) {
        exists = true;
        size_bytes = @intCast(st.st_size);
    }

    var w = beginJsonObject(arena, buf);
    try w.print("{{\"cache_file\":\"{s}\",\"cached\":{s},\"cache_size_bytes\":{d},\"bounded_limit_bytes\":{d}}}", .{
        cache_path,
        if (exists) "true" else "false",
        size_bytes,
        64 * 1024 * 1024,
    });
    return ok(w.list.items);
}

// --- Tools List & Handshake -------------------------------------------------

const TOOLS_MANIFEST =
    \\[
    \\  {
    \\    "name": "scan",
    \\    "description": "Perform high-speed disk directory traversal and category analysis.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {"type": "string", "description": "Root filesystem path to scan"},
    \\        "depth": {"type": "integer", "description": "Maximum tree depth to report (default: 4)"},
    \\        "min_size": {"type": "integer", "description": "Size threshold in bytes"}
    \\      },
    \\      "required": ["path"]
    \\    }
    \\  },
    \\  {
    \\    "name": "drives",
    \\    "description": "Map all local drives, APFS containers, volume free space and SIP status.",
    \\    "inputSchema": {"type": "object", "properties": {}}
    \\  },
    \\  {
    \\    "name": "dedup",
    \\    "description": "Find duplicate files using 3-stage sparse and Blake3 streaming hash.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {"type": "string", "description": "Directory to search for duplicates"},
    \\        "min_size": {"type": "integer", "description": "Minimum file size to consider (default: 4096)"}
    \\      },
    \\      "required": ["path"]
    \\    }
    \\  },
    \\  {
    \\    "name": "clean_propose",
    \\    "description": "Analyze stale build artifacts and caches, returning safe-to-delete proposals.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {"type": "string", "description": "Target path to inspect"}
    \\      },
    \\      "required": ["path"]
    \\    }
    \\  },
    \\  {
    \\    "name": "clean_apply",
    \\    "description": "Move proposed cleanup candidates to macOS Trash with rollback receipts.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {"type": "string", "description": "Target path inspected by clean_propose"},
    \\        "select": {"type": "string", "description": "Selection spec: 'safe', 'all', or indices like '1,2'"},
    \\        "dry_run": {"type": "boolean", "description": "If true, simulate without moving files"},
    \\        "allow_write": {"type": "boolean", "description": "Explicit confirmation required to mutate files"}
    \\      },
    \\      "required": ["path", "allow_write"]
    \\    }
    \\  },
    \\  {
    \\    "name": "history",
    \\    "description": "Show recent operations journal with receipt IDs for rollback.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "limit": {"type": "integer", "description": "Number of recent operations (default: 20)"}
    \\      }
    \\    }
    \\  },
    \\  {
    \\    "name": "undo",
    \\    "description": "Restore a previously trashed file by its receipt ID.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "receipt": {"type": "string", "description": "Receipt ID from clean_apply or history"},
    \\        "allow_write": {"type": "boolean", "description": "Explicit confirmation required to restore"}
    \\      },
    \\      "required": ["receipt", "allow_write"]
    \\    }
    \\  },
    \\  {
    \\    "name": "snapshot",
    \\    "description": "Save a disk snapshot or compute differences between two snapshots.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "action": {"type": "string", "enum": ["save", "diff"]},
    \\        "path": {"type": "string", "description": "Path to scan when action='save'"},
    \\        "output_path": {"type": "string", "description": "Target snapshot file path"},
    \\        "snapshot_a": {"type": "string", "description": "Baseline snapshot for diff"},
    \\        "snapshot_b": {"type": "string", "description": "Comparison snapshot for diff"}
    \\      },
    \\      "required": ["action"]
    \\    }
    \\  },
    \\  {
    \\    "name": "index_status",
    \\    "description": "Inspect the status of the local ZSpace background index cache.",
    \\    "inputSchema": {"type": "object", "properties": {}}
    \\  }
    \\]
;

// --- Dispatcher & Main Stdio Server Loop -----------------------------------

pub fn runServer(allocator: std.mem.Allocator) !void {
    var reader = LineReader{ .allocator = allocator };
    defer reader.deinit();

    var out_buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer out_buf.deinit(allocator);

    logStderr("[zspace-mcp] server starting over stdio (JSON-RPC 2.0)", .{});

    while (try reader.next()) |line| {
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            sendError(allocator, &out_buf, null, PARSE_ERROR, "invalid JSON frame");
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            sendError(allocator, &out_buf, null, INVALID_REQUEST, "request must be an object");
            continue;
        }

        const id_val = root.object.get("id");
        const method_val = root.object.get("method") orelse {
            // Notifications have no method/id
            continue;
        };

        if (method_val != .string) {
            sendError(allocator, &out_buf, id_val, INVALID_REQUEST, "method must be a string");
            continue;
        }

        const method = method_val.string;
        const params = root.object.get("params");

        var arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var tool_buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer tool_buf.deinit(arena);

        if (std.mem.eql(u8, method, "initialize")) {
            const init_resp =
                \\{"protocolVersion": "2024-11-05", "serverInfo": {"name": "zspace", "version": "0.1.0"}, "capabilities": {"tools": {}}}
            ;
            sendResult(allocator, &out_buf, id_val, init_resp);
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            // Client ACK, no response
        } else if (std.mem.eql(u8, method, "ping")) {
            sendResult(allocator, &out_buf, id_val, "{}");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            var list_resp: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
            defer list_resp.deinit(arena);
            var lw = json.JsonWriter{ .list = &list_resp, .allocator = arena };
            try lw.writeAll(TOOLS_JSON);
            sendResult(allocator, &out_buf, id_val, list_resp.items);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const tool_name = argString(params, "name") orelse {
                sendError(allocator, &out_buf, id_val, INVALID_PARAMS, "tool name required");
                continue;
            };
            const arguments = if (params) |p| (if (p == .object) p.object.get("arguments") else null) else null;

            var outcome: ToolOutcome = undefined;
            if (std.mem.eql(u8, tool_name, "scan")) {
                outcome = toolScan(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "drives")) {
                outcome = toolDrives(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "dedup")) {
                outcome = toolDedup(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "clean_propose")) {
                outcome = toolCleanPropose(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "clean_apply")) {
                outcome = toolCleanApply(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "history")) {
                outcome = toolHistory(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "undo")) {
                outcome = toolUndo(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "snapshot")) {
                outcome = toolSnapshot(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else if (std.mem.eql(u8, tool_name, "index_status")) {
                outcome = toolIndexStatus(arena, arguments, &tool_buf) catch |err| fail(@errorName(err));
            } else {
                sendError(allocator, &out_buf, id_val, METHOD_NOT_FOUND, "unknown tool name");
                continue;
            }

            sendToolResult(allocator, &out_buf, id_val, outcome.text, outcome.is_error);
        } else {
            sendError(allocator, &out_buf, id_val, METHOD_NOT_FOUND, "method not found");
        }
    }
}
