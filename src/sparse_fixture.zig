const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");
const limits = sqlite.limits;
const Chunk = sqlite.pager.Chunk;
const page_last: u32 = @intCast(limits.page_count_max);
const lock_page: u32 = 0x40000000 / limits.page_size + 1;
const leaves_max: u32 = limits.page_size / 4 - 8;

// Test-only virtual base image. The native executable never includes this type.
pub const Source = struct {
    seed: [2 * limits.page_size]u8 = undefined,

    pub fn init(self: *Source, engine: *sqlite.Engine) !void {
        var output: [1]u8 = undefined;
        const image = try engine.execute(
            &.{},
            "CREATE TABLE anchor(id INTEGER PRIMARY KEY)",
            .{ .op = 1, .timestamp = 1 },
            &output,
        );
        assert(image.len == self.seed.len);
        @memcpy(&self.seed, image);
        put(&self.seed, .{ .offset = 28, .value = page_last });
        put(&self.seed, .{ .offset = 32, .value = page_last });
        put(&self.seed, .{ .offset = 36, .value = page_last - 3 });
        assert(std.mem.readInt(u16, self.seed[16..18], .big) == 1);
    }

    pub fn fill(self: *const Source, chunk: *Chunk) void {
        assert(chunk.timestamp > 0);
        assert(chunk.image_size == 0);
        if (chunk.timestamp == 1) {
            chunk.image_size = limits.logical_size_max;
            return;
        }
        const offset = (chunk.timestamp - 2) * limits.chunk_size;
        for (&chunk.bytes, 0..) |*byte, index| byte.* = self.original(offset + index);
    }

    pub fn original(self: *const Source, offset: u64) u8 {
        assert(self.seed.len == 2 * limits.page_size);
        assert(page_last > lock_page);
        if (offset < self.seed.len) return self.seed[@intCast(offset)];
        if (offset >= limits.logical_size_max) return 0;
        const page: u32 = @intCast(offset / limits.page_size + 1);
        const within: u32 = @intCast(offset % limits.page_size);
        var word: u32 = 0;
        if (page == page_last) {
            if (within < 4) word = page_last - 1;
        } else if (page != lock_page) {
            const rank = page_last - 1 - page - @intFromBool(page < lock_page);
            if (rank % (leaves_max + 1) == 0) {
                const remaining = page_last - 4 - rank;
                const leaves = @min(leaves_max, remaining - 1);
                if (within < 4 and remaining > leaves + 1) word = free_page(rank + leaves + 1);
                if (within >= 4 and within < 8) word = leaves;
                if (within >= 8 and within / 4 - 2 < leaves) {
                    word = free_page(rank + within / 4 - 1);
                }
            }
        }
        const shift: u5 = @intCast((3 - within % 4) * 8);
        return @truncate(word >> shift);
    }
};

fn free_page(rank: u32) u32 {
    assert(rank < page_last - 4);
    const page = page_last - 1 - rank;
    const result = page - @intFromBool(page <= lock_page);
    assert(result >= 3);
    assert(result != lock_page);
    return result;
}

fn put(bytes: []u8, options: struct { offset: u32, value: u32 }) void {
    assert(options.offset % 4 == 0);
    assert(options.offset + 4 <= bytes.len);
    std.mem.writeInt(u32, bytes[options.offset..][0..4], options.value, .big);
}

test "sparse freelist spans the address space without using the pending-byte page" {
    const total = page_last - 4;
    try std.testing.expectEqual(page_last - 1, free_page(0));
    try std.testing.expectEqual(3, free_page(total - 1));
    const before = page_last - 1 - lock_page - 1;
    try std.testing.expectEqual(lock_page + 1, free_page(before));
    try std.testing.expectEqual(lock_page - 1, free_page(before + 1));
}
