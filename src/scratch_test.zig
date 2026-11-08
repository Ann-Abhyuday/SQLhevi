const std = @import("std");
const scratch = @import("scratch.zig");
const model = @import("scratch_testing.zig");
const sqlite = @import("sqlite.zig");
const allocator = std.testing.allocator;

test "scratch holes, partial blocks, truncation, regrowth, and file reuse" {
    var memory: model.Memory = undefined;
    try memory.init(allocator);
    defer memory.deinit(allocator);
    var store: scratch.Store = undefined;
    try store.init(allocator, &memory.interface());
    defer store.deinit(allocator);
    const file = try store.open();
    const next = try store.open();
    defer store.close(next) catch unreachable;
    try store.write(.{ .file = file, .offset = scratch.block_size - 2 }, "abcd");
    try store.write(.{ .file = next, .offset = 0 }, "separate");
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(6, try store.read(.{
        .file = file,
        .offset = scratch.block_size - 4,
    }, &buffer));
    try std.testing.expectEqualSlices(u8, "\x00\x00abcd\x00\x00", &buffer);
    try store.resize(.{ .file = file, .offset = scratch.block_size - 1 });
    try store.resize(.{ .file = file, .offset = scratch.block_size + 8 });
    _ = try store.read(.{ .file = file, .offset = scratch.block_size - 2 }, &buffer);
    try std.testing.expectEqualSlices(u8, "a\x00\x00\x00\x00\x00\x00\x00", &buffer);
    try store.resize(.{ .file = file, .offset = 0 });
    try store.resize(.{ .file = file, .offset = 8 });
    _ = try store.read(.{ .file = file, .offset = 0 }, &buffer);
    try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0))), &buffer);
    try store.close(file);
    const reused = try store.open();
    try std.testing.expectEqual(file, reused);
    try std.testing.expectEqual(0, store.size(reused));
    try store.close(reused);
}

test "scratch trusted checksums reject post-write corruption, stale and misdirected blocks" {
    var memory: model.Memory = undefined;
    try memory.init(allocator);
    defer memory.deinit(allocator);
    var store: scratch.Store = undefined;
    try store.init(allocator, &memory.interface());
    defer store.deinit(allocator);
    const file = try store.open();
    defer store.close(file) catch unreachable;
    try store.write(.{ .file = file, .offset = 0 }, "first");
    try store.write(.{ .file = file, .offset = scratch.block_size }, "second");
    try store.flush();
    // Simulate a misdirected/stale disk read after the write was acknowledged and verified.
    for (memory.blocks) |*block| {
        if (block.file == file and block.offset == 0) block.bytes[0] ^= 1;
    }
    var output: [5]u8 = undefined;
    try std.testing.expectError(
        error.ScratchIO,
        store.read(.{ .file = file, .offset = 0 }, &output),
    );
    try std.testing.expectEqual(error.ScratchCorrupt, store.failure.?);
}

test "real SQLite spills joins, rolls back failed write batches, and recovers after local faults" {
    var memory: model.Memory = undefined;
    try memory.init(allocator);
    defer memory.deinit(allocator);
    var store: scratch.Store = undefined;
    try store.init(allocator, &memory.interface());
    defer store.deinit(allocator);
    var engine: sqlite.Engine = undefined;
    try engine.init(allocator);
    defer engine.deinit(allocator);
    engine.scratch_store = &store;
    var output: [4096]u8 = undefined;
    const options: sqlite.Engine.ExecuteOptions = .{ .op = 1, .timestamp = 1 };
    const base = try engine.execute(
        &.{},
        "CREATE TABLE guard(v); INSERT INTO guard VALUES(0);",
        options,
        &output,
    );
    const saved = try allocator.dupe(u8, base);
    defer allocator.free(saved);
    _ = try engine.execute(saved, model.query, options, &output);
    try std.testing.expectEqualStrings("16777216\n", output[0..engine.output_size]);
    try std.testing.expect(store.written_bytes > 16 * 1024 * 1024);
    try std.testing.expect(store.read_bytes > store.written_bytes);
    const faults = [_]model.Fault{
        .open, .read, .write, .close, .corrupt_read, .corrupt_write, .lost_write,
    };
    for (faults) |fault| {
        memory.fault = fault;
        memory.after = if (fault == .open or fault == .close or fault == .lost_write) 0 else 7;
        memory.fired = false;
        try std.testing.expectError(
            error.ScratchIO,
            write_attempt(&engine, saved, &output),
        );
        try std.testing.expect(memory.fired);
        try std.testing.expectEqual(0, engine.output_size);
        _ = try engine.execute(saved, "SELECT v FROM guard", options, &output);
        try std.testing.expectEqualStrings("0\n", output[0..engine.output_size]);
    }
    memory.fault = .none;
    const committed = try engine.execute(saved, model.write_query, options, &output);
    const final = try allocator.dupe(u8, committed);
    defer allocator.free(final);
    _ = try engine.execute(final, "SELECT v FROM guard", options, &output);
    try std.testing.expectEqualStrings("11\n", output[0..engine.output_size]);
    try std.testing.expect(sqlite.c.sqlite3_memory_used() <= sqlite.limits.sqlite_heap_limit);
}

fn write_attempt(engine: *sqlite.Engine, image: []const u8, output: []u8) !void {
    std.debug.assert(image.len > 0);
    std.debug.assert(engine.scratch_store != null);
    _ = try engine.execute(image, model.write_query, .{ .op = 1, .timestamp = 1 }, output);
}

test "SQLite external sorter uses anonymous scratch and returns the complete aggregate" {
    var memory: model.Memory = undefined;
    try memory.init(allocator);
    defer memory.deinit(allocator);
    var store: scratch.Store = undefined;
    try store.init(allocator, &memory.interface());
    defer store.deinit(allocator);
    var engine: sqlite.Engine = undefined;
    try engine.init(allocator);
    defer engine.deinit(allocator);
    engine.scratch_store = &store;
    var output: [128]u8 = undefined;
    const query = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4096) " ++
        "SELECT sum(length(p)) FROM (SELECT zeroblob(4096) AS p FROM n ORDER BY p, x DESC);";
    _ = try engine.execute(&.{}, query, .{ .op = 1, .timestamp = 1 }, &output);
    try std.testing.expectEqualStrings("16777216\n", output[0..engine.output_size]);
    try std.testing.expect(store.written_bytes > 0);
    try std.testing.expect(store.read_bytes >= store.written_bytes);
}

test "scratch limits reject deterministically without poisoning local storage" {
    var memory: model.Memory = undefined;
    try memory.init(allocator);
    defer memory.deinit(allocator);
    var store: scratch.Store = undefined;
    try store.init(allocator, &memory.interface());
    defer store.deinit(allocator);
    var files: [scratch.files_max]u32 = undefined;
    for (&files) |*file| file.* = try store.open();
    defer for (files) |file| store.close(file) catch unreachable;
    try std.testing.expectError(error.ScratchLimit, store.open());
    try std.testing.expectError(error.ScratchLimit, store.write(.{
        .file = files[0],
        .offset = @as(u64, scratch.blocks_max) * scratch.block_size,
    }, "outside"));
    try std.testing.expect(store.failure == null);
    try store.write(.{ .file = files[0], .offset = 0 }, "inside");
    var output: [6]u8 = undefined;
    _ = try store.read(.{ .file = files[0], .offset = 0 }, &output);
    try std.testing.expectEqualStrings("inside", &output);
}
