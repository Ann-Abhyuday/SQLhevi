const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const scratch = @import("scratch.zig");

pub const Native = struct {
    ring: linux.IoUring,
    directory: linux.fd_t,
    files: [scratch.files_max]linux.fd_t = @splat(-1),

    pub fn init(self: *Native, directory: linux.fd_t) !void {
        assert(directory >= 0);
        self.* = .{ .ring = try linux.IoUring.init(8, 0), .directory = directory };
        errdefer self.ring.deinit();
        // Check support before joining VSR, rather than discovering it during a transaction.
        try open(self, 0);
        try close(self, 0);
        assert(self.files[0] == -1);
    }

    pub fn deinit(self: *Native) void {
        for (self.files) |fd| assert(fd == -1);
        assert(self.directory >= 0);
        self.ring.deinit();
        self.* = undefined;
    }

    pub fn interface(self: *Native) scratch.Backend {
        assert(self.directory >= 0);
        assert(self.ring.fd >= 0);
        return .{ .context = self, .open = open, .close = close, .read = read, .write = write };
    }

    fn open(context: *anyopaque, file: u32) !void {
        const self: *Native = @ptrCast(@alignCast(context));
        assert(file < self.files.len);
        assert(self.files[file] == -1);
        // No name ever enters the filesystem namespace. Closing or killing the process removes
        // the scratch inode, so a restart cannot mistake partial scratch for committed data.
        _ = try self.ring.openat(1, self.directory, ".", .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .DIRECT = true,
            .TMPFILE = true,
            .DIRECTORY = true,
        }, 0o600);
        self.files[file] = try self.complete();
    }

    fn close(context: *anyopaque, file: u32) !void {
        const self: *Native = @ptrCast(@alignCast(context));
        assert(file < self.files.len);
        assert(self.files[file] >= 0);
        _ = try self.ring.close(1, self.files[file]);
        const result = try self.complete();
        assert(result == 0);
        self.files[file] = -1;
    }

    fn read(context: *anyopaque, position: scratch.Position, bytes: []align(4096) u8) !void {
        const self: *Native = @ptrCast(@alignCast(context));
        assert(bytes.len == scratch.block_size);
        assert(position.offset % scratch.block_size == 0);
        assert(self.files[position.file] >= 0);
        _ = try self.ring.read(1, self.files[position.file], .{ .buffer = bytes }, position.offset);
        if (try self.complete() != bytes.len) return error.ScratchShortRead;
    }

    fn write(context: *anyopaque, position: scratch.Position, bytes: []align(4096) const u8) !void {
        const self: *Native = @ptrCast(@alignCast(context));
        assert(bytes.len == scratch.block_size);
        assert(position.offset % scratch.block_size == 0);
        assert(self.files[position.file] >= 0);
        _ = try self.ring.write(1, self.files[position.file], bytes, position.offset);
        if (try self.complete() != bytes.len) return error.ScratchShortWrite;
        // The separate fault-test executable supplies this compile-time hook. It does not
        // exist in the production root module and produces no production branch or API.
        if (@hasDecl(@import("root"), "scratch_write_hook")) {
            @import("root").scratch_write_hook(self, position, bytes);
        }
    }

    fn complete(self: *Native) !i32 {
        assert(self.ring.fd >= 0);
        const submitted = try self.ring.submit();
        assert(submitted == 1);
        const result = try self.ring.copy_cqe();
        assert(result.user_data == 1);
        if (result.res < 0) return error.ScratchSystemIO;
        return result.res;
    }
};
