const std = @import("std");
const types = @import("types.zig");
const apfs = @import("apfs.zig");
const classifier = @import("classifier.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("limits.h");
    @cInclude("string.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
});

pub const CleanerError = error{
    ProtectedPath,
    TrashFailed,
    ItemNotFound,
    PermissionDenied,
    PathTooLong,
    ApfsCloneFailed,
    JournalWriteFailed,
    UndoFailed,
    HashMismatch,
};

// C04: typed ObjC runtime bindings (no variadic objc_msgSend).
const ObjCId = ?*anyopaque;
const ObjCClass = ?*anyopaque;
const ObjCSel = ?*anyopaque;
extern "c" fn objc_getClass(n: [*:0]const u8) ObjCClass;
extern "c" fn sel_registerName(n: [*:0]const u8) ObjCSel;
extern "c" fn objc_msgSend(...) ObjCId;
// C04: per-selector typed msgSend aliases. Variadic objc_msgSend is UB on
// arm64 for methods taking/returning structs or BOOL (C01 lesson); cast the
// symbol to the exact signature per call site instead.
fn msgSendIdRetainArg(cls: ObjCClass, sel: ObjCSel, arg: [*:0]const u8) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel, [*:0]const u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, arg);
}
fn msgSendDefaultMgr(cls: ObjCClass, sel: ObjCSel) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel);
}
fn msgSendFileURL(cls: ObjCClass, sel: ObjCSel, s: ObjCId, is_dir: u8) ObjCId {
    const F = *const fn (ObjCClass, ObjCSel, ObjCId, u8) callconv(.c) ObjCId;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, s, is_dir);
}
fn msgSendTrash(mgr: ObjCId, sel: ObjCSel, url: ObjCId, res: *ObjCId, err: *ObjCId) u8 {
    const F = *const fn (ObjCId, ObjCSel, ObjCId, *ObjCId, *ObjCId) callconv(.c) u8;
    return @as(F, @ptrCast(&objc_msgSend))(mgr, sel, url, res, err);
}
fn msgSendFSR(url: ObjCId, sel: ObjCSel) [*:0]const u8 {
    const F = *const fn (ObjCId, ObjCSel) callconv(.c) [*:0]const u8;
    return @as(F, @ptrCast(&objc_msgSend))(url, sel);
}
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(p: ?*anyopaque) void;
extern "c" fn __error() *c_int;
extern "c" fn arc4random_buf(buf: [*]u8, n: usize) void;
fn getErrno() c_int {
    return __error().*;
}

/// Read an entire file via libc open/read (codebase idiom: fixed null-term
/// path buffer, O_NONBLOCK open, errno via __error()). `max_bytes` guards
/// runaway reads (error.StreamTooLong). Caller owns the returned slice.
/// Used by readJournalTail (this file) and snapshot loadSnapshot (pub, Zig
/// forbids cross-file use of non-pub decls, hence pub).
pub fn readWholeFileLibc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var zb: [4096]u8 = undefined;
    if (path.len == 0 or path.len >= zb.len - 1) return CleanerError.PathTooLong;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&zb);
    const fd = c.open(z, c.O_RDONLY | c.O_NONBLOCK);
    if (fd < 0) {
        return switch (getErrno()) {
            c.ENOENT => error.FileNotFound,
            c.EACCES, c.EPERM => error.AccessDenied,
            c.EISDIR => error.IsDir,
            c.EMFILE, c.ENFILE => error.ProcessFdQuotaExceeded,
            else => error.Unexpected,
        };
    }
    defer _ = c.close(fd);

    var buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);

    // Read in 256KB chunks; stop at EOF (0). EAGAIN/EINTR are transient.
    var chunk: [256 * 1024]u8 = undefined;
    while (true) {
        if (buf.items.len + chunk.len > max_bytes) return error.StreamTooLong;
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = getErrno();
            if (e == c.EAGAIN or e == c.EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break; // EOF
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(allocator);
}

fn haveObjC() bool {
    return objc_getClass("NSFileManager") != null and sel_registerName("defaultManager") != null;
}

fn computeBlake3IfRegular(path: []const u8) [32]u8 {
    const zero: [32]u8 = [_]u8{0} ** 32;
    var zb: [4096]u8 = undefined;
    if (path.len >= zb.len - 1) return zero;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&zb);
    var lst: c.struct_stat = undefined;
    if (c.lstat(z, &lst) != 0) return zero;
    const mode: c_uint = @intCast(lst.st_mode);
    if ((mode & 0o170000) != 0o100000) return zero;
    const fd = c.open(z, c.O_RDONLY | c.O_NONBLOCK);
    if (fd < 0) return zero;
    defer _ = c.close(fd);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buf: [128 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return zero;
        if (n == 0) break;
        hasher.update(buf[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn blake3Hex(digest: [32]u8, out: *[64]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

fn journalFilePath(allocator: std.mem.Allocator) ![]u8 {
    if (c.getenv("ZSPACE_JOURNAL_PATH")) |v| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        if (s.len > 0) return try allocator.dupe(u8, s);
    }
    const home_c = c.getenv("HOME");
    const home = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else "/Users/joshua";
    return try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "zSpace", "journal.jsonl" });
}

fn ensureParentDir(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    // mkdir -p via libc: walk components, mkdir each level (EEXIST ok).
    var buf: [4096]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len - 1) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1; // skip leading '/' so we never mkdir("")
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = c.mkdir(@as([*:0]const u8, @ptrCast(&buf)), 0o700);
            buf[i] = save;
        }
    }
}

fn appendLineToFile(path: []const u8, bytes: []const u8) !void {
    var pb: [4096]u8 = undefined;
    if (path.len >= pb.len - 1) return CleanerError.PathTooLong;
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const fd = c.open(@as([*:0]const u8, @ptrCast(&pb)), c.O_WRONLY | c.O_APPEND | c.O_CREAT, @as(c_uint, 0o600));
    if (fd < 0) return CleanerError.JournalWriteFailed;
    var close_needed = true;
    defer {
        if (close_needed) _ = c.close(fd);
    }
    if (c.flock(fd, c.LOCK_EX) != 0) return CleanerError.JournalWriteFailed;
    defer _ = c.flock(fd, c.LOCK_UN);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (getErrno() == c.EINTR) continue;
            return CleanerError.JournalWriteFailed;
        }
        if (n == 0) return CleanerError.JournalWriteFailed;
        offset += @intCast(n);
    }
    if (c.fsync(fd) != 0) return CleanerError.JournalWriteFailed;
    if (c.close(fd) != 0) {
        close_needed = false;
        return CleanerError.JournalWriteFailed;
    }
    close_needed = false;
}

fn jsonEscapeInto(list: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    try list.append(allocator, '"');
    for (raw) |b| {
        switch (b) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var eb: [6]u8 = undefined;
                const s = try std.fmt.bufPrint(&eb, "\\u{x:0>4}", .{b});
                try list.appendSlice(allocator, s);
            },
            else => try list.append(allocator, b),
        }
    }
    try list.append(allocator, '"');
}

pub const JournalTailEntry = struct {
    line: []const u8,
};

// --- Minimal JSONL journal reader -------------------------------------------
// The journal is a flat JSON object per line, written by `jsonEscapeInto` +
// `persistJournalLine`. Hydration reads it with a strict left-to-right scanner
// rather than substring search, so a `"key":` sequence occurring *inside* a
// value (e.g. a path literally containing `"dst":`) can never be misparsed.

/// Stack scratch for one parsed record. Owned by the caller so the returned
/// record's slices stay valid for the caller's scope (never returned by value
/// out of a frame that owns them).
pub const JournalScratch = struct {
    op: [16]u8 = undefined,
    receipt: [80]u8 = undefined,
    src: [4096]u8 = undefined,
    dst: [4096]u8 = undefined,
    blake3: [80]u8 = undefined,
    key: [32]u8 = undefined,
};

pub const JournalRecord = struct {
    op: []u8 = &.{},
    receipt: []u8 = &.{},
    src: []u8 = &.{},
    dst: []u8 = &.{},
    blake3: []u8 = &.{},
    size: u64 = 0,
    ts: i128 = 0,
};

fn skipJsonWs(line: []const u8, i: *usize) void {
    while (i.* < line.len and std.ascii.isWhitespace(line[i.*])) i.* += 1;
}

/// Decode a JSON string beginning at `line[i.*]` (the opening quote) into `out`.
/// Advances `i.*` past the closing quote. Returns null on malformed input or if
/// the decoded value does not fit `out` (strict — silently truncating a path
/// would be a correctness bug, not a convenience).
fn readJsonString(line: []const u8, i: *usize, out: []u8) ?[]u8 {
    if (i.* >= line.len or line[i.*] != '"') return null;
    i.* += 1;
    var n: usize = 0;
    while (i.* < line.len) {
        const ch = line[i.*];
        if (ch == '"') {
            i.* += 1;
            return out[0..n];
        }
        if (ch == '\\') {
            if (i.* + 1 >= line.len) return null;
            const esc = line[i.* + 1];
            if (esc == 'u') {
                if (i.* + 5 >= line.len) return null;
                const cp = std.fmt.parseInt(u21, line[i.* + 2 .. i.* + 6], 16) catch return null;
                // Our writer only emits \uXXXX for control bytes (<= 0x1F).
                if (cp > 0xFF) return null;
                if (n >= out.len) return null;
                out[n] = @intCast(cp);
                n += 1;
                i.* += 6;
                continue;
            }
            const decoded: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'b' => 0x08,
                'f' => 0x0C,
                else => return null,
            };
            if (n >= out.len) return null;
            out[n] = decoded;
            n += 1;
            i.* += 2;
            continue;
        }
        if (n >= out.len) return null;
        out[n] = ch;
        n += 1;
        i.* += 1;
    }
    return null; // unterminated
}

/// Parse one flat journal object into `scratch`-backed slices.
fn parseJournalLine(line: []const u8, scratch: *JournalScratch) ?JournalRecord {
    var rec = JournalRecord{};
    var i: usize = 0;
    skipJsonWs(line, &i);
    if (i >= line.len or line[i] != '{') return null;
    i += 1;
    while (true) {
        skipJsonWs(line, &i);
        if (i >= line.len) return null;
        if (line[i] == '}') return rec;
        if (line[i] == ',') {
            i += 1;
            continue;
        }
        if (line[i] != '"') return null;
        const key = readJsonString(line, &i, &scratch.key) orelse return null;
        skipJsonWs(line, &i);
        if (i >= line.len or line[i] != ':') return null;
        i += 1;
        skipJsonWs(line, &i);
        if (i >= line.len) return null;

        if (line[i] == '"') {
            const slot: []u8 = if (std.mem.eql(u8, key, "op"))
                &scratch.op
            else if (std.mem.eql(u8, key, "receipt"))
                &scratch.receipt
            else if (std.mem.eql(u8, key, "src"))
                &scratch.src
            else if (std.mem.eql(u8, key, "dst"))
                &scratch.dst
            else if (std.mem.eql(u8, key, "blake3"))
                &scratch.blake3
            else
                &.{};
            if (slot.len == 0) {
                // Unknown string field: consume its value, then ignore it.
                var sink: [4096]u8 = undefined;
                _ = readJsonString(line, &i, &sink) orelse return null;
                continue;
            }
            const val = readJsonString(line, &i, slot) orelse return null;
            if (std.mem.eql(u8, key, "op")) rec.op = val else if (std.mem.eql(u8, key, "receipt")) rec.receipt = val else if (std.mem.eql(u8, key, "src")) rec.src = val else if (std.mem.eql(u8, key, "dst")) rec.dst = val else rec.blake3 = val;
        } else {
            const start = i;
            while (i < line.len and line[i] != ',' and line[i] != '}') i += 1;
            const num = std.mem.trim(u8, line[start..i], " \t\r\n");
            if (std.mem.eql(u8, key, "size")) rec.size = std.fmt.parseInt(u64, num, 10) catch 0 else if (std.mem.eql(u8, key, "ts")) rec.ts = std.fmt.parseInt(i128, num, 10) catch 0;
        }
    }
}

/// Decode 64 lowercase hex chars into a 32-byte digest. Returns zeros if the
/// slice is not exactly 64 valid hex chars (e.g. the `"0"` placeholder dirs use).
fn hexToDigest(hex: []const u8) [32]u8 {
    var out = [_]u8{0} ** 32;
    if (hex.len != 64) return out;
    for (0..32) |k| {
        const hi = std.fmt.charToDigit(hex[k * 2], 16) catch return [_]u8{0} ** 32;
        const lo = std.fmt.charToDigit(hex[k * 2 + 1], 16) catch return [_]u8{0} ** 32;
        out[k] = (hi << 4) | lo;
    }
    return out;
}


pub const Cleaner = struct {
    allocator: std.mem.Allocator,
    trash_dir_path: []const u8,
    journal: std.ArrayList(types.CleanOperation),

    pub fn init(allocator: std.mem.Allocator) !Cleaner {
        // C04 tests redirect via ZSPACE_TRASH_DIR / ZSPACE_JOURNAL_PATH so
        // `zig build test` never touches the real ~/.Trash or journal.
        var cl = blk: {
            if (c.getenv("ZSPACE_TRASH_DIR")) |v| {
                const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
                if (s.len > 0) break :blk Cleaner{
                    .allocator = allocator,
                    .trash_dir_path = try allocator.dupe(u8, s),
                    .journal = .{ .items = &.{}, .capacity = 0 },
                };
            }
            const home_c = c.getenv("HOME");
            const home = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else "/Users/joshua";
            break :blk Cleaner{
                .allocator = allocator,
                .trash_dir_path = try std.fs.path.join(allocator, &.{ home, ".Trash" }),
                .journal = .{ .items = &.{}, .capacity = 0 },
            };
        };
        // Restore the undo window from the on-disk journal so `undo <receipt>`
        // and `U` keep working after the process exits (the file is the source
        // of truth; memory is only a cache). Best-effort: never fatal.
        cl.hydrateJournalFromDisk(10_000);
        return cl;
    }

    pub fn deinit(self: *Cleaner) void {
        for (self.journal.items) |op| {
            self.allocator.free(op.original_path);
            self.allocator.free(op.trash_path);
            if (op.receipt_id.len > 0) self.allocator.free(op.receipt_id);
        }
        self.journal.deinit(self.allocator);
        self.allocator.free(self.trash_dir_path);
    }

    fn makeNSString(bytes: []const u8) ObjCId {
        const cls = objc_getClass("NSString") orelse return null;
        const sel = sel_registerName("stringWithUTF8String:") orelse return null;
        var buf: [4096]u8 = undefined;
        if (bytes.len >= buf.len) return null;
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;
        return msgSendIdRetainArg(cls, sel, @ptrCast(&buf));
    }

    fn makeFileURL(path: []const u8, is_dir: bool) ObjCId {
        const cls = objc_getClass("NSURL") orelse return null;
        const sel = sel_registerName("fileURLWithPath:isDirectory:") orelse return null;
        const ns = makeNSString(path) orelse return null;
        return msgSendFileURL(cls, sel, ns, if (is_dir) @as(u8, 1) else @as(u8, 0));
    }

    fn nsTrashToBuf(src_url: ObjCId, out: []u8) ?usize {
        const mcls = objc_getClass("NSFileManager") orelse return null;
        const sdef = sel_registerName("defaultManager") orelse return null;
        const mgr = msgSendDefaultMgr(mcls, sdef) orelse return null;
        const st = sel_registerName("trashItemAtURL:resultingItemURL:error:") orelse return null;
        var res: ObjCId = null;
        var err: ObjCId = null;
        if (msgSendTrash(mgr, st, src_url, &res, &err) == 0) return null;
        if (res == null) return null;
        const sfr = sel_registerName("fileSystemRepresentation") orelse return null;
        const span = std.mem.span(msgSendFSR(res, sfr));
        if (span.len == 0 or span.len >= out.len) return null;
        @memcpy(out[0..span.len], span);
        out[span.len] = 0;
        return span.len;
    }

    fn copyRecursive(src: []const u8, dst: []const u8) !void {
        var sz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        if (src.len >= sz.len - 1 or dst.len >= dz.len - 1) return CleanerError.PathTooLong;
        @memcpy(sz[0..src.len], src);
        sz[src.len] = 0;
        @memcpy(dz[0..dst.len], dst);
        dz[dst.len] = 0;
        const sc: [*:0]const u8 = @ptrCast(&sz);
        const dc: [*:0]const u8 = @ptrCast(&dz);
        var st: c.struct_stat = undefined;
        if (c.lstat(sc, &st) != 0) return CleanerError.ItemNotFound;
        const ft = @as(c_uint, @intCast(st.st_mode)) & 0o170000;
        if (ft == 0o120000) {
            var tg: [4096]u8 = undefined;
            const n = c.readlink(sc, &tg, tg.len - 1);
            if (n < 0) return CleanerError.TrashFailed;
            tg[@intCast(n)] = 0;
            _ = c.unlink(dc);
            if (c.symlink(@as([*:0]const u8, @ptrCast(&tg)), dc) != 0) return CleanerError.TrashFailed;
            return;
        }
        if (ft == 0o040000) {
            if (c.mkdir(dc, 0o755) != 0 and getErrno() != c.EEXIST) return CleanerError.TrashFailed;
            const dir = c.opendir(sc) orelse return CleanerError.TrashFailed;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                var sb: [4096]u8 = undefined;
                var db: [4096]u8 = undefined;
                const ss = try std.fmt.bufPrint(&sb, "{s}/{s}", .{ src, nm });
                const ds = try std.fmt.bufPrint(&db, "{s}/{s}", .{ dst, nm });
                try copyRecursive(ss, ds);
            }
            return;
        }
        if (ft == 0o100000) {
            const infd = c.open(sc, c.O_RDONLY | c.O_NONBLOCK);
            if (infd < 0) return CleanerError.TrashFailed;
            defer _ = c.close(infd);
            const outfd = c.open(dc, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_NONBLOCK, @as(c_uint, 0o644));
            if (outfd < 0) return CleanerError.TrashFailed;
            defer _ = c.close(outfd);
            var buf: [128 * 1024]u8 = undefined;
            while (true) {
                const n = c.read(infd, &buf, buf.len);
                if (n < 0) return CleanerError.TrashFailed;
                if (n == 0) break;
                var off: usize = 0;
                const got: usize = @intCast(n);
                while (off < got) {
                    const w = c.write(outfd, buf[off..got].ptr, got - off);
                    if (w <= 0) return CleanerError.TrashFailed;
                    off += @intCast(w);
                }
            }
            return;
        }
        return CleanerError.TrashFailed;
    }

    fn removeRecursive(path: []const u8) void {
        var zb: [4096]u8 = undefined;
        if (path.len >= zb.len - 1) return;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&zb);
        var lst: c.struct_stat = undefined;
        if (c.lstat(z, &lst) != 0) return;
        if ((@as(c_uint, @intCast(lst.st_mode)) & 0o170000) == 0o040000) {
            const dir = c.opendir(z) orelse return;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                var cb: [4096]u8 = undefined;
                const sl = std.fmt.bufPrint(&cb, "{s}/{s}", .{ path, nm }) catch continue;
                removeRecursive(sl);
            }
            _ = c.rmdir(z);
        } else {
            _ = c.unlink(z);
        }
    }

    pub fn safeMoveToTrash(self: *Cleaner, target_path: []const u8, size_bytes: u64, protection: types.ProtectionClass) !types.CleanOperation {
        // The caller's classification is advisory. Re-evaluate at the write
        // boundary so a forged `.None` cannot bypass the central policy.
        if (protection.isProtected() or classifier.classifyProtection(target_path).isProtected()) return CleanerError.ProtectedPath;
        var tz: [4096]u8 = undefined;
        if (target_path.len >= tz.len - 1) return CleanerError.PathTooLong;
        @memcpy(tz[0..target_path.len], target_path);
        tz[target_path.len] = 0;
        var lst0: c.struct_stat = undefined;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&tz)), &lst0) != 0) return CleanerError.ItemNotFound;
        if (classifier.classifyProtection(target_path).isProtected()) return CleanerError.ProtectedPath;
        const is_dir0 = (@as(c_uint, @intCast(lst0.st_mode)) & 0o170000) == 0o040000;
        const digest = computeBlake3IfRegular(target_path);
        const now = types.getRealtimeNs();

        // Receipt identity is independent from the content digest. Write the
        // intent durably before asking macOS to move anything.
        var random_receipt: [16]u8 = undefined;
        arc4random_buf(&random_receipt, random_receipt.len);
        var receipt_hex: [32]u8 = undefined;
        const hex = "0123456789abcdef";
        for (random_receipt, 0..) |b, i| {
            receipt_hex[i * 2] = hex[b >> 4];
            receipt_hex[i * 2 + 1] = hex[b & 0x0f];
        }
        const rid = try self.allocator.dupe(u8, &receipt_hex);
        errdefer self.allocator.free(rid);
        try self.persistTrashIntent(rid, target_path, &lst0, size_bytes, now);

        var method: types.TrashMethod = .nsfilemanager;
        var owned_trash: ?[]u8 = null;
        if (comptime @import("builtin").os.tag == .macos) {
            // Confirm the same filesystem object still occupies the path
            // immediately before passing it to NSFileManager.
            var current: c.struct_stat = undefined;
            if (c.lstat(@as([*:0]const u8, @ptrCast(&tz)), &current) != 0 or
                current.st_dev != lst0.st_dev or current.st_ino != lst0.st_ino or
                current.st_mode != lst0.st_mode)
            {
                return CleanerError.ItemNotFound;
            }
            if (classifier.classifyProtection(target_path).isProtected()) return CleanerError.ProtectedPath;
            if (haveObjC()) {
                const pool = objc_autoreleasePoolPush();
                const url = makeFileURL(target_path, is_dir0);
                if (url != null) {
                    var ob: [4096]u8 = undefined;
                    if (nsTrashToBuf(url, &ob)) |n| {
                        owned_trash = try self.allocator.dupe(u8, ob[0..n]);
                        method = .nsfilemanager;
                    }
                }
                objc_autoreleasePoolPop(pool);
            }
        }
        // Never silently replace a failed native Trash operation with a
        // rename, copy/unlink, or permanent deletion.
        if (owned_trash == null) return CleanerError.TrashFailed;
        const tpath = owned_trash orelse return CleanerError.TrashFailed;
        errdefer self.allocator.free(tpath);
        const op = types.CleanOperation{
            .original_path = try self.allocator.dupe(u8, target_path),
            .trash_path = tpath,
            .size_bytes = size_bytes,
            .timestamp_ns = now,
            .verified_hash = std.hash.Wyhash.hash(0, &digest),
            .blake3 = digest,
            .receipt_id = rid,
            .method = method,
        };
        try self.journal.append(self.allocator, op);
        try self.persistJournalLine(&self.journal.items[self.journal.items.len - 1]);
        return self.journal.items[self.journal.items.len - 1];
    }

    fn persistTrashIntent(self: *Cleaner, receipt: []const u8, path: []const u8, st: *const c.struct_stat, size: u64, ts: i128) !void {
        const jp = try journalFilePath(self.allocator);
        defer self.allocator.free(jp);
        ensureParentDir(jp);
        var line: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer line.deinit(self.allocator);
        try line.appendSlice(self.allocator, "{\"schema_version\":1,\"op\":\"trash_intent\",\"phase\":\"intent\",\"receipt\":");
        try jsonEscapeInto(&line, self.allocator, receipt);
        try line.appendSlice(self.allocator, ",\"src\":");
        try jsonEscapeInto(&line, self.allocator, path);
        var nb: [256]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&nb, ",\"dev\":{d},\"ino\":{d},\"size\":{d},\"ts\":{d}}}\n", .{
            @as(u64, @intCast(st.st_dev)), @as(u64, @intCast(st.st_ino)), size, ts,
        });
        try line.appendSlice(self.allocator, suffix);
        try appendLineToFile(jp, line.items);
    }

    pub fn persistJournalLine(self: *Cleaner, op: *const types.CleanOperation) !void {
        const jp = try journalFilePath(self.allocator);
        defer self.allocator.free(jp);
        ensureParentDir(jp);
        var line: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer line.deinit(self.allocator);
        var hexb: [64]u8 = undefined;
        const hx = blake3Hex(op.blake3, &hexb);
        try line.appendSlice(self.allocator, "{\"schema_version\":1,\"op\":\"trash\",\"phase\":\"outcome\",\"outcome\":\"succeeded\",\"receipt\":");
        try jsonEscapeInto(&line, self.allocator, op.receipt_id);
        try line.appendSlice(self.allocator, ",\"src\":");
        try jsonEscapeInto(&line, self.allocator, op.original_path);
        try line.appendSlice(self.allocator, ",\"dst\":");
        try jsonEscapeInto(&line, self.allocator, op.trash_path);
        try line.appendSlice(self.allocator, ",\"blake3\":");
        try jsonEscapeInto(&line, self.allocator, hx);
        var nb: [128]u8 = undefined;
        const t1 = try std.fmt.bufPrint(&nb, ",\"size\":{d},\"ts\":{d},\"method\":", .{ op.size_bytes, op.timestamp_ns });
        try line.appendSlice(self.allocator, t1);
        try jsonEscapeInto(&line, self.allocator, op.method.label());
        const t2 = try std.fmt.bufPrint(&nb, ",\"verified_hash\":{d}}}", .{op.verified_hash});
        try line.appendSlice(self.allocator, t2);
        try line.append(self.allocator, '\n');
        try appendLineToFile(jp, line.items);
    }

    pub fn undoByReceipt(self: *Cleaner, receipt_id: []const u8) !types.CleanOperation {
        const op = self.findByReceipt(receipt_id) orelse return CleanerError.ItemNotFound;
        try self.restoreOperation(op);
        try self.persistUndoLine(op);
        return op.*;
    }

    pub fn findByReceipt(self: *Cleaner, receipt_id: []const u8) ?*const types.CleanOperation {
        for (self.journal.items) |*op| {
            if (std.mem.eql(u8, op.receipt_id, receipt_id)) return op;
        }
        return null;
    }

    /// Repopulate `self.journal` from the on-disk JSONL journal so `undo` and
    /// `U` work across process restarts. The journal file is the source of
    /// truth; in-process memory is only a cache.
    ///
    /// Records whose receipt also appears on an `"op":"undo"` line are skipped
    /// (already restored). Bounded: reads at most ~64MB and keeps at most
    /// `max_records` most-recent trash operations. Best-effort by design —
    /// hydration failure must never prevent the Cleaner from being usable.
    pub fn hydrateJournalFromDisk(self: *Cleaner, max_records: usize) void {
        const jp = journalFilePath(self.allocator) catch return;
        defer self.allocator.free(jp);

        const data = readWholeFileLibc(self.allocator, jp, 1 << 26) catch return;
        defer self.allocator.free(data);

        var undone: std.ArrayList([]u8) = .{ .items = &.{}, .capacity = 0 };
        defer {
            for (undone.items) |r| self.allocator.free(r);
            undone.deinit(self.allocator);
        }

        // Pass 1: receipts that have already been restored.
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var scratch = JournalScratch{};
            const rec = parseJournalLine(line, &scratch) orelse continue;
            if (!std.mem.eql(u8, rec.op, "undo")) continue;
            if (rec.receipt.len == 0) continue;
            const dup = self.allocator.dupe(u8, rec.receipt) catch continue;
            undone.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                continue;
            };
        }

        // Pass 2: trash records not yet undone, capped to the newest
        // `max_records` entries (the rest are beyond any practical undo window).
        var it2 = std.mem.splitScalar(u8, data, '\n');
        while (it2.next()) |line| {
            if (line.len == 0) continue;
            var scratch = JournalScratch{};
            const rec = parseJournalLine(line, &scratch) orelse continue;
            if (!std.mem.eql(u8, rec.op, "trash")) continue;
            if (rec.receipt.len == 0 or rec.src.len == 0 or rec.dst.len == 0) continue;

            var already = false;
            for (undone.items) |r| {
                if (std.mem.eql(u8, r, rec.receipt)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            for (self.journal.items) |existing| {
                if (std.mem.eql(u8, existing.receipt_id, rec.receipt)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;

            const orig = self.allocator.dupe(u8, rec.src) catch continue;
            const tpath = self.allocator.dupe(u8, rec.dst) catch {
                self.allocator.free(orig);
                continue;
            };
            const rid = self.allocator.dupe(u8, rec.receipt) catch {
                self.allocator.free(orig);
                self.allocator.free(tpath);
                continue;
            };
            const digest = hexToDigest(rec.blake3);
            self.journal.append(self.allocator, .{
                .original_path = orig,
                .trash_path = tpath,
                .size_bytes = rec.size,
                .timestamp_ns = rec.ts,
                .verified_hash = std.hash.Wyhash.hash(0, &digest),
                .blake3 = digest,
                .receipt_id = rid,
                .method = .nsfilemanager,
            }) catch {
                self.allocator.free(orig);
                self.allocator.free(tpath);
                self.allocator.free(rid);
                continue;
            };
        }

        // Keep only the newest `max_records` entries (journal is append-only,
        // so order of insertion here is oldest→newest).
        if (self.journal.items.len > max_records) {
            const drop = self.journal.items.len - max_records;
            for (self.journal.items[0..drop]) |op| {
                self.allocator.free(op.original_path);
                self.allocator.free(op.trash_path);
                if (op.receipt_id.len > 0) self.allocator.free(op.receipt_id);
            }
            std.mem.copyForwards(types.CleanOperation, self.journal.items[0 .. self.journal.items.len - drop], self.journal.items[drop..]);
            self.journal.items.len -= drop;
        }
    }

    /// Read the last `max_lines` entries of the on-disk JSONL journal
    /// (oldest→newest order preserved within the returned tail). Returns lines
    /// verbatim including the trailing JSON; caller frees each `.line` and the
    /// list with the passed allocator.
    pub fn readJournalTail(
        self: *Cleaner,
        allocator: std.mem.Allocator,
        max_lines: usize,
    ) !std.ArrayList(JournalTailEntry) {
        _ = self;
        var out_list: std.ArrayList(JournalTailEntry) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (out_list.items) |e| allocator.free(e.line);
            out_list.deinit(allocator);
        }
        const jp = try journalFilePath(allocator);
        defer allocator.free(jp);

        const data = readWholeFileLibc(allocator, jp, 1 << 28) catch |e| switch (e) {
            error.FileNotFound => return out_list,
            else => return e,
        };
        defer allocator.free(data);

        if (max_lines == 0) return out_list;
        // Ring-buffer the tail: keep last max_lines non-empty lines.
        var ring = try allocator.alloc([]const u8, max_lines);
        defer allocator.free(ring);
        var ring_len: usize = 0;
        var head: usize = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (ring_len < max_lines) {
                ring[ring_len] = line;
                ring_len += 1;
            } else {
                ring[head] = line;
                head = (head + 1) % max_lines;
            }
        }
        // Emit oldest→newest: when wrapped, start at head (oldest kept).
        if (ring_len < max_lines) {
            for (ring[0..ring_len]) |line| {
                try out_list.append(allocator, .{ .line = try allocator.dupe(u8, line) });
            }
        } else {
            for (0..max_lines) |k| {
                const line = ring[(head + k) % max_lines];
                try out_list.append(allocator, .{ .line = try allocator.dupe(u8, line) });
            }
        }
        return out_list;
    }

    fn persistUndoLine(self: *Cleaner, op: *const types.CleanOperation) !void {
        const jp = try journalFilePath(self.allocator);
        defer self.allocator.free(jp);
        ensureParentDir(jp);
        var line: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        defer line.deinit(self.allocator);
        var hexb: [64]u8 = undefined;
        const hx = blake3Hex(op.blake3, &hexb);
        try line.appendSlice(self.allocator, "{\"op\":\"undo\",\"receipt\":");
        try jsonEscapeInto(&line, self.allocator, op.receipt_id);
        try line.appendSlice(self.allocator, ",\"src\":");
        try jsonEscapeInto(&line, self.allocator, op.trash_path);
        try line.appendSlice(self.allocator, ",\"dst\":");
        try jsonEscapeInto(&line, self.allocator, op.original_path);
        try line.appendSlice(self.allocator, ",\"blake3\":");
        try jsonEscapeInto(&line, self.allocator, hx);
        var nb: [128]u8 = undefined;
        const t = try std.fmt.bufPrint(&nb, ",\"size\":{d},\"ts\":{d}}}", .{ op.size_bytes, types.getRealtimeNs() });
        try line.appendSlice(self.allocator, t);
        try line.append(self.allocator, '\n');
        try appendLineToFile(jp, line.items);
    }

    fn restoreOperation(self: *Cleaner, op: *const types.CleanOperation) !void {
        _ = self;
        var sz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        if (op.trash_path.len >= sz.len - 1 or op.original_path.len >= dz.len - 1) return CleanerError.PathTooLong;
        @memcpy(sz[0..op.trash_path.len], op.trash_path);
        sz[op.trash_path.len] = 0;
        @memcpy(dz[0..op.original_path.len], op.original_path);
        dz[op.original_path.len] = 0;
        var dsts: c.struct_stat = undefined;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&dz)), &dsts) == 0) return CleanerError.UndoFailed;
        if (c.rename(@as([*:0]const u8, @ptrCast(&sz)), @as([*:0]const u8, @ptrCast(&dz))) != 0) {
            return CleanerError.TrashFailed;
        }
        var allz = true;
        for (op.blake3) |b| {
            if (b != 0) {
                allz = false;
                break;
            }
        }
        if (!allz) {
            const rd = computeBlake3IfRegular(op.original_path);
            if (!std.mem.eql(u8, &rd, &op.blake3)) return CleanerError.HashMismatch;
        }
    }

    pub fn consolidateApfsClone(self: *Cleaner, original_path: []const u8, duplicate_path: []const u8, size_bytes: u64) !u64 {
        _ = self;
        const res = apfs.ApfsEngine.cloneDeduplicate(original_path, duplicate_path, size_bytes);
        if (!res.success) {
            return CleanerError.ApfsCloneFailed;
        }
        return res.bytes_freed;
    }

    pub fn rollbackOperation(self: *Cleaner, op: *const types.CleanOperation) !void {
        return self.restoreOperation(op);
    }
};

// --- Journal reader tests ---------------------------------------------------
// These lock the parser contract: our writer's escaping must round-trip, and a
// `"key":` sequence inside a *value* must never be misread as a field.

test "parseJournalLine: plain trash record" {
    var scratch = JournalScratch{};
    const line = "{\"op\":\"trash\",\"receipt\":\"a1b2c3d4e5f60718\",\"src\":\"/tmp/x.bin\",\"dst\":\"/Users/u/.Trash/x.bin\",\"blake3\":\"00\",\"size\":4096,\"ts\":1234567890,\"method\":\"nsfilemanager\"}";
    const rec = parseJournalLine(line, &scratch) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("trash", rec.op);
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718", rec.receipt);
    try std.testing.expectEqualStrings("/tmp/x.bin", rec.src);
    try std.testing.expectEqualStrings("/Users/u/.Trash/x.bin", rec.dst);
    try std.testing.expectEqualStrings("00", rec.blake3);
    try std.testing.expectEqual(@as(u64, 4096), rec.size);
    try std.testing.expectEqual(@as(i128, 1234567890), rec.ts);
}

test "parseJournalLine: escaped values round-trip" {
    var scratch = JournalScratch{};
    // A path containing a quote, a backslash, a newline and a tab.
    const line = "{\"op\":\"trash\",\"receipt\":\"ff\",\"src\":\"/a\\\"b\\\\c\\nd\\te\",\"dst\":\"/t\",\"size\":1,\"ts\":2}";
    const rec = parseJournalLine(line, &scratch) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("/a\"b\\c\nd\te", rec.src);
}

test "parseJournalLine: key-like text inside a value is not a field" {
    var scratch = JournalScratch{};
    // `src` literally contains the text  "dst":"/evil" . A substring search for
    // `"dst":` would return the wrong value; the sequential scanner must not.
    const line = "{\"op\":\"trash\",\"receipt\":\"aa\",\"src\":\"/x/\\\"dst\\\":\\\"/evil\\\"\",\"dst\":\"/real/trash\",\"size\":7,\"ts\":9}";
    const rec = parseJournalLine(line, &scratch) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("/x/\"dst\":\"/evil\"", rec.src);
    try std.testing.expectEqualStrings("/real/trash", rec.dst);
}

test "parseJournalLine: rejects malformed input" {
    var scratch = JournalScratch{};
    try std.testing.expect(parseJournalLine("not json", &scratch) == null);
    try std.testing.expect(parseJournalLine("{\"op\":\"trash\"", &scratch) == null);
    try std.testing.expect(parseJournalLine("", &scratch) == null);
}

test "hexToDigest: valid, wrong length, invalid chars" {
    const zero32 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectEqual([_]u8{0} ** 32, hexToDigest(zero32));

    const ff32 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectEqual([_]u8{0xFF} ** 32, hexToDigest(ff32));

    // Contract: any deviation yields all-zeros rather than a partial digest.
    try std.testing.expectEqual([_]u8{0} ** 32, hexToDigest("0"));
    try std.testing.expectEqual([_]u8{0} ** 32, hexToDigest(""));
    try std.testing.expectEqual([_]u8{0} ** 32, hexToDigest("zz00000000000000000000000000000000000000000000000000000000000000"));
}

// Simulates process restart: a journal written by a *previous* process must be
// readable by a *new* Cleaner, and receipts already undone must not be
// re-offered. This is the regression gate for "undo silently fails after
// restart", which was the pre-fix behaviour (in-memory-only journal).
test "hydrateJournalFromDisk: undo survives restart, undone receipts excluded" {
    const allocator = std.testing.allocator;
    const tio = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(tio, "h/.Trash");
    var path_buf: [4096]u8 = undefined;
    const abs_len = try tmp.dir.realPath(tio, &path_buf);
    const abs = path_buf[0..abs_len];

    const journal_path = try std.fmt.allocPrint(allocator, "{s}/h/journal.jsonl", .{abs});
    defer allocator.free(journal_path);
    const trash_dir = try std.fmt.allocPrint(allocator, "{s}/h/.Trash", .{abs});
    defer allocator.free(trash_dir);

    // Two trash ops; the second has already been undone in a prior session.
    const digest_a = "ab" ** 32;
    const body = try std.fmt.allocPrint(allocator,
        \\{{"op":"trash","receipt":"1111111111111111","src":"/tmp/keepme.bin","dst":"/t/keepme.bin","blake3":"{s}","size":2048,"ts":100}}
        \\{{"op":"trash","receipt":"2222222222222222","src":"/tmp/gone.bin","dst":"/t/gone.bin","blake3":"00","size":99,"ts":200}}
        \\{{"op":"undo","receipt":"2222222222222222","src":"/t/gone.bin","dst":"/tmp/gone.bin","blake3":"00","size":99,"ts":300}}
        \\
    , .{digest_a});
    defer allocator.free(body);
    try tmp.dir.writeFile(tio, .{ .sub_path = "h/journal.jsonl", .data = body });

    // Point the Cleaner at the hermetic journal/trash paths.
    var jz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    try std.testing.expect(journal_path.len < jz.len and trash_dir.len < tz.len);
    @memcpy(jz[0..journal_path.len], journal_path);
    jz[journal_path.len] = 0;
    @memcpy(tz[0..trash_dir.len], trash_dir);
    tz[trash_dir.len] = 0;
    _ = c.setenv("ZSPACE_JOURNAL_PATH", @as([*:0]const u8, @ptrCast(&jz)), 1);
    defer _ = c.unsetenv("ZSPACE_JOURNAL_PATH");
    _ = c.setenv("ZSPACE_TRASH_DIR", @as([*:0]const u8, @ptrCast(&tz)), 1);
    defer _ = c.unsetenv("ZSPACE_TRASH_DIR");

    var cl = try Cleaner.init(allocator);
    defer cl.deinit();

    // Fresh process sees the prior session's still-undoable op.
    const found = cl.findByReceipt("1111111111111111") orelse return error.HydrationMissing;
    try std.testing.expectEqualStrings("/tmp/keepme.bin", found.original_path);
    try std.testing.expectEqualStrings("/t/keepme.bin", found.trash_path);
    try std.testing.expectEqual(@as(u64, 2048), found.size_bytes);
    try std.testing.expectEqualStrings(digest_a, &hexFmt(found.blake3));

    // The already-undone receipt must NOT be offered again.
    try std.testing.expect(cl.findByReceipt("2222222222222222") == null);
}

fn hexFmt(digest: [32]u8) [64]u8 {
    var buf: [64]u8 = undefined;
    _ = blake3Hex(digest, &buf);
    return buf;
}
