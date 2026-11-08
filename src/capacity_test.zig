const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");
const limits = sqlite.limits;
const Chunk = sqlite.pager.Chunk;
const Source = @import("sparse_fixture.zig").Source;

// A valid sparse freelist describes the whole address space arithmetically. Only the seed
// schema and committed changes occupy memory; no 281 TB file or whole-image allocation exists.
const Sparse = struct {
    engine: sqlite.Engine,
    pages: sqlite.pager.Pager,
    source: Source = .{},
    changes: []Chunk,
    change_count: u32 = 0,
    output: [4096]u8 = undefined,
    highest_written: u64 = 0,

    fn init(self: *Sparse) !void {
        self.* = .{ .engine = undefined, .pages = undefined, .changes = undefined };
        try self.engine.init(std.testing.allocator);
        errdefer self.engine.deinit(std.testing.allocator);
        try self.pages.init(std.testing.allocator);
        errdefer self.pages.deinit(std.testing.allocator);
        self.changes = try std.testing.allocator.alloc(Chunk, 2048);
        errdefer std.testing.allocator.free(self.changes);
        try self.source.init(&self.engine);
        assert(self.change_count == 0);
        assert(self.pages.count == 0);
    }

    fn deinit(self: *Sparse) void {
        assert(sqlite.pager.active == null);
        assert(self.change_count <= self.changes.len);
        self.engine.deinit(std.testing.allocator);
        self.pages.deinit(std.testing.allocator);
        std.testing.allocator.free(self.changes);
    }

    fn execute(self: *Sparse, sql: []const u8) ![]const u8 {
        assert(sql.len > 0);
        assert(sqlite.pager.active == null);
        self.pages.reset();
        try self.pages.supply(&.{
            .timestamp = 1,
            .image_size = limits.logical_size_max,
            .bytes = @splat(0),
        }, true);
        for (0..limits.read_chunks_max) |_| {
            self.engine.execute_paged(
                &self.pages,
                sql,
                .{ .op = 2, .timestamp = 2 },
                &self.output,
            ) catch |err|
                {
                    if (self.pages.failure) |failure| return failure;
                    const key = self.pages.missing orelse return err;
                    try self.fetch(key);
                    continue;
                };
            try self.pages.finish();
            assert(self.pages.size == limits.logical_size_max);
            for (self.pages.writes[0..self.pages.write_count]) |*chunk| self.commit(chunk);
            return self.output[0..self.engine.output_size];
        }
        return error.ReadSetLimit;
    }

    fn commit(self: *Sparse, chunk: *const Chunk) void {
        assert(chunk.timestamp >= 2);
        assert(self.change_count < self.changes.len);
        const offset = (chunk.timestamp - 2) * limits.chunk_size;
        self.highest_written = @max(self.highest_written, offset);
        for (self.changes[0..self.change_count]) |*previous| {
            if (previous.timestamp == chunk.timestamp) {
                previous.* = chunk.*;
                return;
            }
        }
        self.changes[self.change_count] = chunk.*;
        self.change_count += 1;
    }

    fn fetch(self: *Sparse, key: u64) !void {
        assert(key >= 2);
        assert(self.pages.get(key) == null);
        for (key..key + limits.page_size / limits.chunk_size + 2) |next| {
            if (self.pages.get(next) != null) continue;
            var chunk: Chunk = .{ .timestamp = next, .image_size = 0, .bytes = @splat(0) };
            for (self.changes[0..self.change_count]) |*previous| {
                if (previous.timestamp == next) {
                    chunk = previous.*;
                    break;
                }
            } else {
                self.source.fill(&chunk);
            }
            try self.pages.supply(&chunk, true);
        }
    }
};

test "unmodified SQLite creates and reads a table on its maximum page" {
    var sparse: Sparse = undefined;
    try sparse.init();
    defer sparse.deinit();
    const result = try sparse.execute("CREATE TABLE tail(id INTEGER PRIMARY KEY, value);" ++
        "INSERT INTO tail VALUES(7, 'highest');" ++
        "SELECT rootpage FROM sqlite_schema WHERE name='tail';" ++
        "SELECT id,value FROM tail;");
    try std.testing.expectEqualStrings("4294967294\n7\tt:68696768657374\n", result);
    try std.testing.expect(sparse.highest_written >= limits.logical_size_max - limits.chunk_size);
    try std.testing.expect(sparse.pages.size == 281474976579584);
    try std.testing.expect(sparse.change_count < 300);
    try std.testing.expectEqualStrings("7\n", try sparse.execute("SELECT id FROM tail"));
    const updated = try sparse.execute("UPDATE tail SET id=8; SELECT id FROM tail");
    try std.testing.expectEqualStrings("8\n", updated);
    var bytes: [1]u8 = .{1};
    try std.testing.expectEqual(
        sqlite.c.SQLITE_FULL,
        sparse.pages.write(&bytes, limits.logical_size_max),
    );
    try std.testing.expectEqual(
        sqlite.c.SQLITE_FULL,
        sparse.pages.write(&bytes, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        sqlite.c.SQLITE_IOERR_READ,
        sparse.pages.read(&bytes, std.math.maxInt(u64)),
    );
}

test "SQLite rejects allocating beyond its maximum page without committing changes" {
    var sparse: Sparse = undefined;
    try sparse.init();
    defer sparse.deinit();
    // This header-only exhaustion fixture is deliberately not a fully populated database.
    // It isolates SQLite's max-page allocator guard, without pretending to test all its pages.
    @memset(sparse.source.seed[32..40], 0);
    try std.testing.expectError(error.DatabaseFull, sparse.execute("CREATE TABLE overflow(v)"));
    try std.testing.expectEqual(@as(u32, 0), sparse.change_count);
}
