const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const vsr = @import("vsr");
const stdx = @import("stdx");
const IO = stdx.IO;
pub const Storage = vsr.storage.StorageType(IO);

// Keep the original TigerBeetle data path. A small, dedicated ring also handles file lifecycle
// operations, for which upstream Storage.init uses blocking filesystem syscalls.
pub const Disk = struct {
    storage: Storage,
    ring: linux.IoUring,

    pub fn open(
        disk: *Disk,
        io: *IO,
        tracer: *vsr.trace.Tracer,
        path: []const u8,
        purpose: enum { format, start },
    ) !void {
        if (path.len == 0 or path.len > 4095) return error.PathSize;
        var ring = try linux.IoUring.init(8, 0);
        errdefer ring.deinit();
        var directory_buffer: [4096]u8 = undefined;
        var filename_buffer: [4096]u8 = undefined;
        const directory = try std.fmt.bufPrintZ(&directory_buffer, "{s}", .{
            std.fs.path.dirname(path) orelse ".",
        });
        const filename = try std.fmt.bufPrintZ(&filename_buffer, "{s}", .{
            std.fs.path.basename(path),
        });
        _ = try ring.openat(1, linux.AT.FDCWD, directory, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        const dir_fd = try complete(&ring);
        errdefer close_file(&ring, dir_fd);
        _ = try ring.openat(1, dir_fd, filename, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .DIRECT = true,
            .DSYNC = true,
            .NOFOLLOW = true,
            .CREAT = purpose == .format,
            .EXCL = purpose == .format,
        }, 0o600);
        const fd = try complete(&ring);
        errdefer close_file(&ring, fd);
        // Linux exposes advisory locks as flock/fcntl, not io_uring operations. This is a
        // process-ownership check; all file contents and metadata I/O below uses the ring.
        try stdx.posix.flock(fd, stdx.posix.LOCK.EX | stdx.posix.LOCK.NB);
        try prepare_file(&ring, .{ .fd = fd, .dir_fd = dir_fd, .create = purpose == .format });
        assert(fd >= 0);
        assert(dir_fd >= 0);
        disk.* = .{
            .ring = ring,
            .storage = .{
                .io = io,
                .tracer = tracer,
                .fd = fd,
                .dir_fd = dir_fd,
                .purpose = if (purpose == .format)
                    .{ .format = .{ .superblock_zone_size = vsr.superblock.superblock_zone_size } }
                else
                    .open,
            },
        };
    }

    pub fn close(disk: *Disk) void {
        assert(disk.storage.unflushed == 0);
        assert(disk.storage.fd >= 0);
        close_file(&disk.ring, disk.storage.fd);
        close_file(&disk.ring, disk.storage.dir_fd);
        disk.ring.deinit();
        disk.* = undefined;
    }
};

fn prepare_file(ring: *linux.IoUring, options: struct {
    fd: linux.fd_t,
    dir_fd: linux.fd_t,
    create: bool,
}) !void {
    assert(options.fd >= 0);
    assert(options.dir_fd >= 0);
    if (options.create) {
        _ = try ring.fallocate(1, options.fd, 0, 0, vsr.superblock.data_file_size_min);
        _ = try complete(ring);
    }
    // Flush before reading to avoid validating a previous process's dirty page-cache contents.
    _ = try ring.fsync(1, options.fd, 0);
    _ = try complete(ring);
    _ = try ring.fsync(1, options.dir_fd, 0);
    _ = try complete(ring);
    var stat: linux.Statx = undefined;
    _ = try ring.statx(
        1,
        options.fd,
        "",
        linux.AT.EMPTY_PATH,
        .{ .TYPE = true, .SIZE = true },
        &stat,
    );
    _ = try complete(ring);
    if ((stat.mode & linux.S.IFMT) != linux.S.IFREG) return error.RegularFileRequired;
    if (stat.size < vsr.superblock.data_file_size_min) return error.FileTooSmall;
    if (stat.size > vsr.constants.storage_size_limit_max) return error.FileTooLarge;
}

fn complete(ring: *linux.IoUring) !i32 {
    assert(ring.fd >= 0);
    const submitted = try ring.submit();
    assert(submitted == 1);
    const result = try ring.copy_cqe();
    assert(result.user_data == 1);
    if (result.res < 0) {
        std.log.err("storage io_uring completion errno={d}", .{-result.res});
        return error.StorageIO;
    }
    return result.res;
}

fn close_file(ring: *linux.IoUring, fd: linux.fd_t) void {
    assert(fd >= 0);
    _ = ring.close(1, fd) catch @panic("queue close");
    const result = complete(ring) catch @panic("complete close");
    assert(result == 0);
}
