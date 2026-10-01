const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("sys/attr.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

extern "c" fn clonefile(from: [*c]const u8, to: [*c]const u8, flags: c_int) c_int;
extern "c" fn __error() *c_int;
fn errnoValue() c_int {
    return __error().*;
}

fn readFull(fd: c_int, buffer: []u8) usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const rc = c.read(fd, buffer[total..].ptr, buffer.len - total);
        if (rc < 0) {
            if (errnoValue() == c.EINTR) continue;
            break;
        }
        if (rc == 0) break;
        total += @intCast(rc);
    }
    return total;
}

pub const ApfsCloneResult = struct {
    bytes_freed: u64,
    success: bool,
    error_msg: ?[]const u8 = null,
};

pub const ApfsEngine = struct {
    pub const CLONE_NOFOLLOW: c_int = 0x0001;
    pub const CLONE_NOOWNERCOPY: c_int = 0x0002;

    pub fn isApfsVolume(path: []const u8) bool {
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len - 1) return false;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var stat_buf: c.struct_statfs = undefined;
        if (c.statfs(@as([*:0]const u8, @ptrCast(&path_z)), &stat_buf) != 0) {
            return false;
        }

        const fstype = std.mem.span(@as([*:0]const u8, @ptrCast(&stat_buf.f_fstypename)));
        return std.mem.eql(u8, fstype, "apfs");
    }

    pub fn cloneDeduplicate(source_path: []const u8, duplicate_path: []const u8, size_bytes: u64) ApfsCloneResult {
        var src_z: [4096]u8 = undefined;
        var dup_z: [4096]u8 = undefined;
        var tmp_z: [4096]u8 = undefined;

        if (std.mem.eql(u8, source_path, duplicate_path)) {
            return .{ .bytes_freed = 0, .success = true, .error_msg = null };
        }

        if (source_path.len >= src_z.len - 1 or duplicate_path.len >= dup_z.len - 1) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Path exceeds buffer limits" };
        }

        @memcpy(src_z[0..source_path.len], source_path);
        src_z[source_path.len] = 0;

        @memcpy(dup_z[0..duplicate_path.len], duplicate_path);
        dup_z[duplicate_path.len] = 0;
        const fd_src = c.open(@as([*:0]const u8, @ptrCast(&src_z)), c.O_RDONLY);
        if (fd_src < 0) return .{ .bytes_freed = 0, .success = false, .error_msg = "Failed to open source file" };
        defer _ = c.close(fd_src);

        const fd_dup = c.open(@as([*:0]const u8, @ptrCast(&dup_z)), c.O_RDONLY);
        if (fd_dup < 0) return .{ .bytes_freed = 0, .success = false, .error_msg = "Failed to open duplicate file" };
        defer _ = c.close(fd_dup);

        var stat_src: c.struct_stat = undefined;
        var stat_dup: c.struct_stat = undefined;
        if (c.fstat(fd_src, &stat_src) != 0 or c.fstat(fd_dup, &stat_dup) != 0) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Failed to stat source or duplicate" };
        }

        var lstat_src: c.struct_stat = undefined;
        var lstat_dup: c.struct_stat = undefined;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&src_z)), &lstat_src) != 0 or c.lstat(@as([*:0]const u8, @ptrCast(&dup_z)), &lstat_dup) != 0) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Failed to lstat source or duplicate" };
        }
        if (lstat_src.st_ino != stat_src.st_ino or lstat_dup.st_ino != stat_dup.st_ino) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "File path points to a changed inode or symlink" };
        }

        // Safety Rail 0: Only regular files can be cloned (reject symlinks, directories, special files)
        if ((@as(c_uint, @intCast(stat_src.st_mode)) & 0o170000) != 0o100000 or
            (@as(c_uint, @intCast(stat_dup.st_mode)) & 0o170000) != 0o100000)
        {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Only regular files can be cloned" };
        }

        // Safety Rail 1: Same device check (clonefile requires same APFS volume)
        if (stat_src.st_dev != stat_dup.st_dev) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Cross-device clone attempted; files must reside on same APFS volume" };
        }

        // Safety Rail 2: Don't clone if already pointing to same inode
        if (stat_src.st_ino == stat_dup.st_ino) {
            return .{ .bytes_freed = 0, .success = true, .error_msg = null };
        }

        // Safety Rail 3: File sizes must match
        if (stat_src.st_size != stat_dup.st_size) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "File sizes changed or mismatch" };
        }

        // Safety Rail 4: Byte-for-byte content verification before replacement
        {
            var buf_src: [64 * 1024]u8 = undefined;
            var buf_dup: [64 * 1024]u8 = undefined;
            var total_read: u64 = 0;
            const file_size: u64 = @intCast(stat_src.st_size);
            while (total_read < file_size) {
                const remaining = file_size - total_read;
                const to_read = @min(buf_src.len, @as(usize, @intCast(remaining)));
                const n_src = readFull(fd_src, buf_src[0..to_read]);
                const n_dup = readFull(fd_dup, buf_dup[0..to_read]);
                if (n_src != to_read or n_dup != to_read) {
                    return .{ .bytes_freed = 0, .success = false, .error_msg = "I/O error during content verification" };
                }
                if (!std.mem.eql(u8, buf_src[0..to_read], buf_dup[0..to_read])) {
                    return .{ .bytes_freed = 0, .success = false, .error_msg = "Content mismatch: duplicate was modified since scan" };
                }
                total_read += to_read;
            }
        }

        const now = types.getRealtimeNs();
        _ = std.fmt.bufPrint(&tmp_z, "{s}.zclone_{d}", .{ duplicate_path, now }) catch {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Temporary buffer allocation failed" };
        };

        if (clonefile(&src_z, &tmp_z, CLONE_NOFOLLOW) != 0) {
            return .{ .bytes_freed = 0, .success = false, .error_msg = "clonefile syscall failed (non-APFS or cross-device)" };
        }

        // Safety Rail 5: Re-verify duplicate descriptor and path before atomic rename to prevent TOCTOU overwrite
        var post_stat: c.struct_stat = undefined;
        var post_lstat: c.struct_stat = undefined;
        if (c.fstat(fd_dup, &post_stat) != 0 or c.lstat(@as([*:0]const u8, @ptrCast(&dup_z)), &post_lstat) != 0) {
            _ = c.unlink(&tmp_z);
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Failed to re-stat duplicate before replacement" };
        }

        if (post_stat.st_mtimespec.tv_sec != stat_dup.st_mtimespec.tv_sec or
            post_stat.st_mtimespec.tv_nsec != stat_dup.st_mtimespec.tv_nsec or
            post_stat.st_size != stat_dup.st_size or
            post_stat.st_ino != stat_dup.st_ino or
            post_lstat.st_ino != stat_dup.st_ino or
            post_lstat.st_mtimespec.tv_sec != stat_dup.st_mtimespec.tv_sec or
            post_lstat.st_mtimespec.tv_nsec != stat_dup.st_mtimespec.tv_nsec)
        {
            _ = c.unlink(&tmp_z);
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Duplicate was modified during clone verification" };
        }

        if (c.rename(&tmp_z, &dup_z) != 0) {
            _ = c.unlink(&tmp_z);
            return .{ .bytes_freed = 0, .success = false, .error_msg = "Atomic replacement failed" };
        }

        return .{
            .bytes_freed = size_bytes,
            .success = true,
            .error_msg = null,
        };
    }
};
