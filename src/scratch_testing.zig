const std = @import("std");
const assert = std.debug.assert;
const scratch = @import("scratch.zig");
const block_count = 512;
const Block = struct {
    file: u32 = scratch.files_max,
    offset: u64 = 0,
    bytes: [scratch.block_size]u8 = undefined,
};
pub const Fault = enum { none, open, read, write, close, corrupt_read, corrupt_write, lost_write };

// A deterministic scratch device used alongside TigerBeetle's durable-storage simulator.
// Faults affect only this device. They must never become replicated SQL error results.
pub const Memory = struct {
    blocks: []Block,
    files: [scratch.files_max]bool = @splat(false),
    fault: Fault = .none,
    after: u32 = 0,
    fired: bool = false,

    pub fn init(self: *Memory, allocator: std.mem.Allocator) !void {
        const blocks = try allocator.alloc(Block, block_count);
        for (blocks) |*block| block.* = .{};
        self.* = .{ .blocks = blocks };
        assert(blocks.len == block_count);
        assert(!self.fired);
    }

    pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
        for (self.files) |opened| assert(!opened);
        assert(self.blocks.len == block_count);
        allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn interface(self: *Memory) scratch.Backend {
        assert(self.blocks.len == block_count);
        return .{ .context = self, .open = open, .close = close, .read = read, .write = write };
    }

    fn inject(self: *Memory, faults: []const Fault) bool {
        assert(faults.len > 0);
        assert(faults.len <= 3);
        if (self.fired or self.fault == .none) return false;
        if (std.mem.indexOfScalar(Fault, faults, self.fault) == null) return false;
        if (self.after > 0) {
            self.after -= 1;
            return false;
        }
        self.fired = true;
        return true;
    }

    fn open(context: *anyopaque, file: u32) !void {
        const self: *Memory = @ptrCast(@alignCast(context));
        assert(file < scratch.files_max);
        assert(!self.files[file]);
        if (self.inject(&.{.open})) return error.InjectedOpen;
        self.files[file] = true;
    }

    fn close(context: *anyopaque, file: u32) !void {
        const self: *Memory = @ptrCast(@alignCast(context));
        assert(file < scratch.files_max);
        assert(self.files[file]);
        self.files[file] = false;
        for (self.blocks) |*block| {
            if (block.file == file) block.file = scratch.files_max;
        }
        if (self.inject(&.{.close})) return error.InjectedClose;
    }

    fn read(context: *anyopaque, position: scratch.Position, bytes: []align(4096) u8) !void {
        const self: *Memory = @ptrCast(@alignCast(context));
        assert(self.files[position.file]);
        assert(bytes.len == scratch.block_size);
        const inject_fault = self.inject(&.{ .read, .corrupt_read });
        if (inject_fault and self.fault == .read) return error.InjectedRead;
        for (self.blocks) |*block| {
            if (block.file != position.file or block.offset != position.offset) continue;
            @memcpy(bytes, &block.bytes);
            if (inject_fault) bytes[bytes.len / 2] ^= 1;
            return;
        }
        return error.InjectedShortRead;
    }

    fn write(context: *anyopaque, position: scratch.Position, bytes: []align(4096) const u8) !void {
        const self: *Memory = @ptrCast(@alignCast(context));
        assert(self.files[position.file]);
        assert(bytes.len == scratch.block_size);
        const inject_fault = self.inject(&.{ .write, .corrupt_write, .lost_write });
        if (inject_fault and self.fault == .write) return error.InjectedWrite;
        if (inject_fault and self.fault == .lost_write) return;
        var available: ?*Block = null;
        for (self.blocks) |*block| {
            if (block.file == position.file and block.offset == position.offset) {
                available = block;
                break;
            }
            if (block.file == scratch.files_max) available = block;
        }
        const block = available orelse return error.InjectedNoSpace;
        block.file = position.file;
        block.offset = position.offset;
        @memcpy(&block.bytes, bytes);
        if (inject_fault) block.bytes[0] ^= 1;
    }
};

pub const query = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2048), " ++
    "m AS MATERIALIZED (SELECT x, zeroblob(8192) AS p FROM n) " ++
    "SELECT sum(length(a.p)) FROM m AS a JOIN m AS b ON a.x=b.x;";
pub const write_query = "UPDATE guard SET v=v+1;" ++ query ++ "UPDATE guard SET v=v+10;";
