const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("engine").sqlite;
const limits = sqlite.limits;
const pager = sqlite.pager;
const memory = @import("engine").memory;
const workload = @import("bench_workload.zig");

// The actual production Engine/Pager, backed by a bounded RAM image instead of the LSM/VSR.
// This measures SQL execution, private connections and cache-miss replay, not durable I/O.
// It explicitly omits scratch; use the native cluster driver to measure production file spill.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.ExpectedOptionalQuick;
    assert(args.len >= 1);
    var adapter: Adapter = undefined;
    try adapter.init(init.gpa);
    defer adapter.deinit(init.gpa);
    assert(memory.live_bytes == 0);
    try workload.run(&adapter, args.len == 2);
    assert(memory.live_bytes == 0);
}

const Adapter = struct {
    name: []const u8 = std.fmt.comptimePrint("SQLhevi_engine_{d}_memory", .{
        limits.sqlite_heap_limit / (1024 * 1024),
    }),
    engine: sqlite.Engine,
    pages: pager.Pager,
    image: []u8,
    size: u64 = 0,
    op: u64 = 0,
    attempts: u64 = 0,
    output: [4096]u8 = undefined,

    fn init(self: *Adapter, allocator: std.mem.Allocator) !void {
        self.* = .{ .engine = undefined, .pages = undefined, .image = undefined };
        try self.engine.init(allocator);
        errdefer self.engine.deinit(allocator);
        try self.pages.init(allocator);
        errdefer self.pages.deinit(allocator);
        self.image = try allocator.alloc(u8, 8 * 1024 * 1024);
        @memset(self.image, 0);
        assert(self.image.len > limits.database_size_max);
        assert(self.pages.count == 0);
    }

    fn deinit(self: *Adapter, allocator: std.mem.Allocator) void {
        assert(pager.active == null);
        assert(self.size <= self.image.len);
        self.engine.deinit(allocator);
        self.pages.deinit(allocator);
        allocator.free(self.image);
    }

    pub fn query(self: *Adapter, sql: []const u8) ![]const u8 {
        assert(pager.active == null);
        assert(self.size <= self.image.len);
        self.op += 1;
        self.pages.reset();
        try self.pages.supply(&.{
            .timestamp = 1,
            .image_size = self.size,
            .bytes = @splat(0),
        }, true);
        defer assert(memory.live_bytes == 0);
        for (0..limits.read_chunks_max) |_| {
            self.attempts += 1;
            self.engine.execute_paged(&self.pages, sql, .{
                .op = self.op,
                .timestamp = 1234567890000000000,
            }, &self.output) catch |err| {
                if (self.pages.failure) |failure| return failure;
                const key = self.pages.missing orelse return err;
                try self.fetch(key);
                continue;
            };
            try self.pages.finish();
            assert(self.pages.size <= self.image.len);
            for (self.pages.writes[0..self.pages.write_count]) |*chunk| {
                if (chunk.timestamp == 1) continue;
                const offset = (chunk.timestamp - 2) * limits.chunk_size;
                const count = @min(limits.chunk_size, self.pages.size -| offset);
                @memcpy(self.image[offset..][0..count], chunk.bytes[0..count]);
            }
            self.size = self.pages.size;
            return self.output[0..self.engine.output_size];
        }
        return error.ReadSetLimit;
    }

    fn fetch(self: *Adapter, key: u64) !void {
        assert(key >= 2);
        assert(self.pages.get(key) == null);
        for (key..key + limits.page_size / limits.chunk_size + 2) |next| {
            if (self.pages.get(next) != null) continue;
            if (self.pages.count == limits.read_chunks_max) return error.ReadSetLimit;
            var chunk: pager.Chunk = .{
                .timestamp = next,
                .image_size = 0,
                .bytes = @splat(0),
            };
            const offset = (next - 2) * limits.chunk_size;
            const count = @min(limits.chunk_size, self.size -| offset);
            if (count > 0) @memcpy(chunk.bytes[0..count], self.image[offset..][0..count]);
            try self.pages.supply(&chunk, count > 0);
        }
    }

    pub fn reset_metrics(self: *Adapter) void {
        assert(memory.live_bytes == 0);
        assert(pager.active == null);
        memory.peak_bytes = 0;
        memory.failures = 0;
        self.attempts = 0;
    }

    pub fn metrics(self: *Adapter) workload.Metrics {
        assert(memory.live_bytes == 0);
        assert(memory.peak_bytes <= limits.sqlite_heap_size);
        return .{
            .peak = memory.peak_bytes,
            .failures = memory.failures,
            .attempts = self.attempts,
        };
    }
};
