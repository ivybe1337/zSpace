const std = @import("std");
const types = @import("types.zig");
const cleaner = @import("cleaner.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});

pub const SNAP_MAGIC = "# ZSNP3";
const LEGACY_MAGIC = "# ZSNP2";
const MAX_SNAPSHOT_BYTES: usize = 1 << 31;

pub const DigestState = enum { verified, unreadable, not_hashed };

pub const SnapshotEntry = struct {
    path: []const u8,
    size_bytes: u64,
    allocated_bytes: u64 = 0,
    is_dir: bool,
    kind: types.FileKind = .unknown,
    mtime_ns: i128 = 0,
    digest_state: DigestState = .not_hashed,
    blake3hex: []const u8 = "",
};

pub const DiffEntry = struct {
    path: []const u8,
    old_size: u64,
    new_size: u64,
    diff_bytes: i64,
    status: enum { added, removed, grew, shrunk, changed, unknown, unchanged },
};

pub const SnapshotEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SnapshotEngine {
        return .{ .allocator = allocator };
    }

    pub fn saveSnapshot(self: *SnapshotEngine, root: *const types.DiskNode, dest_file_path: []const u8) !void {
        var temp_path: [4096]u8 = undefined;
        const template = try std.fmt.bufPrint(&temp_path, "{s}.tmp.XXXXXX", .{dest_file_path});
        if (template.len >= temp_path.len - 1) return error.PathTooLong;
        temp_path[template.len] = 0;
        const fd = c.mkstemp(@ptrCast(&temp_path));
        if (fd < 0) return error.FileCreateFailed;
        const f = c.fdopen(fd, "wb");
        if (f == null) {
            _ = c.close(fd);
            _ = c.unlink(@ptrCast(&temp_path));
            return error.FileCreateFailed;
        }

        var published = false;
        defer {
            if (!published) _ = c.unlink(@ptrCast(&temp_path));
        }
        var file_open = true;
        defer {
            if (file_open) _ = c.fclose(f);
        }

        var hasher = std.crypto.hash.Blake3.init(.{});
        var count: u64 = 0;
        var root_escaped: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer root_escaped.deinit(self.allocator);
        try percentEncode(self.allocator, &root_escaped, root.path);

        try writeTracked(f, &hasher, SNAP_MAGIC ++ "\nversion=3\n");
        try writeFormatTracked(f, &hasher, "timestamp={d}\nroot={s}\ntotal_bytes={d}\ntotal_files={d}\ntotal_dirs={d}\ncomplete=true\n---\n", .{
            types.getRealtimeNs(), root_escaped.items, root.size_bytes, root.file_count, root.dir_count,
        });
        try writeNodeRecursive(self.allocator, root, f, &hasher, &count);
        try writeFormatTracked(f, &hasher, "entries={d}\n", .{count});
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        var hex: [64]u8 = undefined;
        const hex_slice = digestHex(digest, &hex);
        try writeFormatUntracked(f, "checksum={s}\n", .{hex_slice});

        if (c.fflush(f) != 0 or c.fsync(c.fileno(f)) != 0) return error.SnapshotWriteFailed;
        if (c.fclose(f) != 0) return error.SnapshotWriteFailed;
        file_open = false;

        var dest_z: [4096]u8 = undefined;
        if (dest_file_path.len >= dest_z.len - 1) return error.PathTooLong;
        @memcpy(dest_z[0..dest_file_path.len], dest_file_path);
        dest_z[dest_file_path.len] = 0;
        if (c.rename(@ptrCast(&temp_path), @ptrCast(&dest_z)) != 0) return error.SnapshotPublishFailed;
        published = true;

        // Make the rename durable when the containing directory can be opened.
        var parent_z: [4096]u8 = undefined;
        const parent = std.fs.path.dirname(dest_file_path) orelse ".";
        if (parent.len < parent_z.len - 1) {
            @memcpy(parent_z[0..parent.len], parent);
            parent_z[parent.len] = 0;
            const dirfd = c.open(@ptrCast(&parent_z), c.O_RDONLY);
            if (dirfd >= 0) {
                _ = c.fsync(dirfd);
                _ = c.close(dirfd);
            }
        }
    }

    fn writeNodeRecursive(allocator: std.mem.Allocator, node: *const types.DiskNode, f: ?*c.FILE, hasher: *std.crypto.hash.Blake3, count: *u64) !void {
        var hash_buf: [64]u8 = undefined;
        var hash: []const u8 = "";
        var digest_state: []const u8 = "not_hashed";
        if (node.kind == .file) {
            hash = hashFileBlake3Hex(node.path, &hash_buf) catch blk: {
                digest_state = "unreadable";
                break :blk "";
            };
            if (hash.len > 0) digest_state = "verified";
        }
        var escaped: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer escaped.deinit(allocator);
        try percentEncode(allocator, &escaped, node.path);
        try writeFormatTracked(f, hasher, "{d}|{s}|{d}|{d}|{s}|{s}|{s}\n", .{
            node.size_bytes,
            @tagName(node.kind),
            node.mtime_ns,
            node.allocated_bytes,
            digest_state,
            hash,
            escaped.items,
        });
        count.* += 1;
        if (node.kind == .directory) {
            for (node.children.items) |child| try writeNodeRecursive(allocator, child, f, hasher, count);
        }
    }

    fn hashFileBlake3Hex(path: []const u8, out_hex: *[64]u8) ![]const u8 {
        var zb: [4096]u8 = undefined;
        if (path.len >= zb.len - 1) return error.PathTooLong;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const fd = c.open(@ptrCast(&zb), c.O_RDONLY | c.O_NONBLOCK | c.O_NOFOLLOW);
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or (@as(c_uint, @intCast(st.st_mode)) & 0o170000) != 0o100000) return error.NotRegularFile;
        var hasher = std.crypto.hash.Blake3.init(.{});
        var buf: [128 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            hasher.update(buf[0..@intCast(n)]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digestHex(digest, out_hex);
    }

    pub const SnapshotData = struct {
        entries: std.StringHashMap(SnapshotEntry),
        root: []const u8 = "",
        timestamp_ns: u64 = 0,
        version: u8 = 3,
        complete: bool = false,
    };

    pub fn loadSnapshot(self: *SnapshotEngine, path: []const u8) !SnapshotData {
        const data = try cleaner.readWholeFileLibc(self.allocator, path, MAX_SNAPSHOT_BYTES);
        defer self.allocator.free(data);
        if (std.mem.startsWith(u8, data, SNAP_MAGIC ++ "\n")) return self.loadV3(data);
        if (std.mem.startsWith(u8, data, LEGACY_MAGIC ++ "\n")) return self.loadV2(data);
        return error.InvalidSnapshot;
    }

    fn loadV3(self: *SnapshotEngine, data: []const u8) !SnapshotData {
        const checksum_at = std.mem.lastIndexOf(u8, data, "checksum=") orelse return error.InvalidSnapshot;
        if (checksum_at == 0 or data[checksum_at - 1] != '\n') return error.InvalidSnapshot;
        const checksum_line_end = std.mem.indexOfScalarPos(u8, data, checksum_at, '\n') orelse return error.InvalidSnapshot;
        if (checksum_line_end + 1 != data.len) return error.InvalidSnapshot;
        const checksum_text = data[checksum_at + 9 .. checksum_line_end];
        if (checksum_text.len != 64) return error.InvalidSnapshot;
        var expected: [32]u8 = undefined;
        if (!parseDigest(checksum_text, &expected)) return error.InvalidSnapshot;
        var actual: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data[0..checksum_at], &actual, .{});
        if (!std.mem.eql(u8, &expected, &actual)) return error.InvalidSnapshot;

        var result = std.StringHashMap(SnapshotEntry).init(self.allocator);
        errdefer freeEntries(self.allocator, &result);
        var root: []const u8 = "";
        var timestamp: u64 = 0;
        var complete = false;
        var expected_entries: ?u64 = null;
        var entries_started = false;
        var observed_entries: u64 = 0;
        var it = std.mem.splitScalar(u8, data[0..checksum_at], '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "root=")) {
                if (root.len != 0) return error.InvalidSnapshot;
                root = try percentDecode(self.allocator, line[5..]);
            } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                timestamp = std.fmt.parseInt(u64, line[10..], 10) catch return error.InvalidSnapshot;
            } else if (std.mem.eql(u8, line, "complete=true")) {
                complete = true;
            } else if (std.mem.eql(u8, line, "---")) {
                entries_started = true;
            } else if (std.mem.startsWith(u8, line, "entries=")) {
                expected_entries = std.fmt.parseInt(u64, line[8..], 10) catch return error.InvalidSnapshot;
                break;
            } else if (entries_started and line.len > 0) {
                var cols = std.mem.splitScalar(u8, line, '|');
                const size_s = cols.next() orelse return error.InvalidSnapshot;
                const kind_s = cols.next() orelse return error.InvalidSnapshot;
                const mtime_s = cols.next() orelse return error.InvalidSnapshot;
                const alloc_s = cols.next() orelse return error.InvalidSnapshot;
                const digest_state_s = cols.next() orelse return error.InvalidSnapshot;
                const hash_s = cols.next() orelse return error.InvalidSnapshot;
                const path_s = cols.next() orelse return error.InvalidSnapshot;
                if (cols.next() != null) return error.InvalidSnapshot;
                const size = std.fmt.parseInt(u64, size_s, 10) catch return error.InvalidSnapshot;
                const kind = std.meta.stringToEnum(types.FileKind, kind_s) orelse return error.InvalidSnapshot;
                const mtime = std.fmt.parseInt(i128, mtime_s, 10) catch return error.InvalidSnapshot;
                const allocated = std.fmt.parseInt(u64, alloc_s, 10) catch return error.InvalidSnapshot;
                const state = std.meta.stringToEnum(DigestState, digest_state_s) orelse return error.InvalidSnapshot;
                if ((state == .verified and hash_s.len != 64) or (state != .verified and hash_s.len != 0)) return error.InvalidSnapshot;
                const item_path = try percentDecode(self.allocator, path_s);
                errdefer self.allocator.free(item_path);
                const hash_copy = if (state == .verified) try self.allocator.dupe(u8, hash_s) else "";
                errdefer if (state == .verified) self.allocator.free(hash_copy);
                const entry: SnapshotEntry = .{
                    .path = item_path,
                    .size_bytes = size,
                    .allocated_bytes = allocated,
                    .is_dir = kind == .directory,
                    .kind = kind,
                    .mtime_ns = mtime,
                    .digest_state = state,
                    .blake3hex = hash_copy,
                };
                const inserted = try result.getOrPut(item_path);
                if (inserted.found_existing) return error.InvalidSnapshot;
                inserted.value_ptr.* = entry;
                observed_entries += 1;
            }
        }
        if (!entries_started or !complete or expected_entries == null or expected_entries.? != observed_entries or root.len == 0) return error.InvalidSnapshot;
        return .{ .entries = result, .root = root, .timestamp_ns = timestamp, .version = 3, .complete = true };
    }

    fn loadV2(self: *SnapshotEngine, data: []const u8) !SnapshotData {
        var result = std.StringHashMap(SnapshotEntry).init(self.allocator);
        errdefer freeEntries(self.allocator, &result);
        var root: []const u8 = "";
        var timestamp: u64 = 0;
        var in_body = false;
        var it = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, it.next() orelse "", LEGACY_MAGIC)) return error.InvalidSnapshot;
        while (it.next()) |line| {
            if (!in_body) {
                if (std.mem.eql(u8, line, "---")) {
                    in_body = true;
                    continue;
                }
                if (std.mem.startsWith(u8, line, "root=")) {
                    if (root.len != 0) return error.InvalidSnapshot;
                    root = try self.allocator.dupe(u8, line[5..]);
                } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                    timestamp = std.fmt.parseInt(u64, line[10..], 10) catch return error.InvalidSnapshot;
                }
                continue;
            }
            if (line.len == 0) continue;
            var cols: [5][]const u8 = undefined;
            var n: usize = 0;
            var ci = std.mem.splitScalar(u8, line, '|');
            while (ci.next()) |col| {
                if (n < cols.len) cols[n] = col;
                n += 1;
            }
            if (n < 3 or n > 5) return error.InvalidSnapshot;
            const size = std.fmt.parseInt(u64, cols[0], 10) catch return error.InvalidSnapshot;
            const is_dir = std.mem.eql(u8, cols[1], "1");
            const mtime: i128 = if (n >= 5) std.fmt.parseInt(i128, cols[2], 10) catch return error.InvalidSnapshot else 0;
            const old_hash = if (n >= 5) cols[3] else "0";
            const path_text = if (n >= 5) cols[4] else cols[2];
            const item_path = try self.allocator.dupe(u8, path_text);
            const verified = old_hash.len == 64;
            const hash_copy = if (verified) try self.allocator.dupe(u8, old_hash) else "";
            errdefer {
                self.allocator.free(item_path);
                if (verified) self.allocator.free(hash_copy);
            }
            const kind: types.FileKind = if (is_dir) .directory else .file;
            const inserted = try result.getOrPut(item_path);
            if (inserted.found_existing) return error.InvalidSnapshot;
            inserted.value_ptr.* = .{ .path = item_path, .size_bytes = size, .is_dir = is_dir, .kind = kind, .mtime_ns = mtime, .digest_state = if (verified) .verified else .unreadable, .blake3hex = hash_copy };
        }
        if (!in_body or root.len == 0 or result.count() == 0) return error.InvalidSnapshot;
        return .{ .entries = result, .root = root, .timestamp_ns = timestamp, .version = 2, .complete = false };
    }

    pub fn freeSnapshot(self: *SnapshotEngine, snap: *SnapshotData) void {
        freeEntries(self.allocator, &snap.entries);
        if (snap.root.len > 0) self.allocator.free(snap.root);
    }

    pub fn compareSnapshots(self: *SnapshotEngine, old_snapshot_path: []const u8, new_snapshot_path: []const u8) !std.ArrayList(DiffEntry) {
        var old_snap = try self.loadSnapshot(old_snapshot_path);
        defer self.freeSnapshot(&old_snap);
        var new_snap = try self.loadSnapshot(new_snapshot_path);
        defer self.freeSnapshot(&new_snap);
        var out_list: std.ArrayList(DiffEntry) = .{ .items = &.{}, .capacity = 0 };
        errdefer out_list.deinit(self.allocator);
        var new_it = new_snap.entries.iterator();
        while (new_it.next()) |kv| {
            const path = kv.key_ptr.*;
            const ne = kv.value_ptr.*;
            if (old_snap.entries.get(path)) |oe| {
                if (oe.size_bytes != ne.size_bytes) {
                    const diff = @as(i128, ne.size_bytes) - @as(i128, oe.size_bytes);
                    try out_list.append(self.allocator, .{ .path = try self.allocator.dupe(u8, path), .old_size = oe.size_bytes, .new_size = ne.size_bytes, .diff_bytes = std.math.cast(i64, diff) orelse return error.SizeDeltaOverflow, .status = if (diff > 0) .grew else .shrunk });
                } else if (oe.digest_state == .verified and ne.digest_state == .verified) {
                    try out_list.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, path),
                        .old_size = oe.size_bytes,
                        .new_size = ne.size_bytes,
                        .diff_bytes = 0,
                        .status = if (std.mem.eql(u8, oe.blake3hex, ne.blake3hex)) .unchanged else .changed,
                    });
                } else {
                    try out_list.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, path),
                        .old_size = oe.size_bytes,
                        .new_size = ne.size_bytes,
                        .diff_bytes = 0,
                        .status = .unknown,
                    });
                }
            } else {
                try out_list.append(self.allocator, .{ .path = try self.allocator.dupe(u8, path), .old_size = 0, .new_size = ne.size_bytes, .diff_bytes = std.math.cast(i64, ne.size_bytes) orelse return error.SizeDeltaOverflow, .status = .added });
            }
        }
        var old_it = old_snap.entries.iterator();
        while (old_it.next()) |kv| {
            const path = kv.key_ptr.*;
            if (new_snap.entries.contains(path)) continue;
            const negative = -@as(i128, kv.value_ptr.size_bytes);
            try out_list.append(self.allocator, .{ .path = try self.allocator.dupe(u8, path), .old_size = kv.value_ptr.size_bytes, .new_size = 0, .diff_bytes = std.math.cast(i64, negative) orelse return error.SizeDeltaOverflow, .status = .removed });
        }
        return out_list;
    }
};

fn writeTracked(f: ?*c.FILE, hasher: *std.crypto.hash.Blake3, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.SnapshotWriteFailed;
    hasher.update(bytes);
}

fn writeFormatTracked(f: ?*c.FILE, hasher: *std.crypto.hash.Blake3, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(bytes);
    try writeTracked(f, hasher, bytes);
}

fn writeFormatUntracked(f: ?*c.FILE, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&buf, fmt, args);
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.SnapshotWriteFailed;
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |b| {
        if (b == '%' or b == '|' or b == '\n' or b == '\r' or b < 0x20) {
            try out.appendSlice(allocator, &.{ '%', hex[b >> 4], hex[b & 0x0f] });
        } else try out.append(allocator, b);
    }
}

fn percentDecode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '%') {
            try out.append(allocator, bytes[i]);
            continue;
        }
        if (i + 2 >= bytes.len) return error.InvalidSnapshot;
        const hi = hexNibble(bytes[i + 1]) orelse return error.InvalidSnapshot;
        const lo = hexNibble(bytes[i + 2]) orelse return error.InvalidSnapshot;
        try out.append(allocator, (hi << 4) | lo);
        i += 2;
    }
    return try out.toOwnedSlice(allocator);
}

fn digestHex(digest: [32]u8, out: *[64]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..];
}

fn parseDigest(text: []const u8, out: *[32]u8) bool {
    if (text.len != 64) return false;
    for (0..32) |i| {
        const hi = hexNibble(text[i * 2]) orelse return false;
        const lo = hexNibble(text[i * 2 + 1]) orelse return false;
        out[i] = (hi << 4) | lo;
    }
    return true;
}

fn hexNibble(b: u8) ?u8 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => null,
    };
}

fn freeEntries(allocator: std.mem.Allocator, map: *std.StringHashMap(SnapshotEntry)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.digest_state == .verified) allocator.free(entry.value_ptr.blake3hex);
    }
    map.deinit();
}
