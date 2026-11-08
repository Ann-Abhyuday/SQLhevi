const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite.zig").c;

var methods: c.sqlite3_mem_methods = undefined;
var pool: []u8 = &.{};
pub var allocations: u64 = 0;
pub var failures: u64 = 0;
pub var live_bytes: u64 = 0;
pub var peak_bytes: u64 = 0;

// SQLite's documented allocator interface permits auditing without changing its C source.
// memsys5 performs dynamic suballocation within this pool. It is not stack-only allocation.
pub fn configure(memory: []align(16) u8) !void {
    assert(pool.len == 0);
    assert(memory.len <= std.math.maxInt(c_int));
    pool = memory;
    if (c.sqlite3_config(c.SQLITE_CONFIG_MEMSTATUS, @as(c_int, 1)) != c.SQLITE_OK) {
        return error.SQLiteMemoryAccounting;
    }
    const configured = c.sqlite3_config(
        c.SQLITE_CONFIG_HEAP,
        memory.ptr,
        @as(c_int, @intCast(memory.len)),
        @as(c_int, 64),
    );
    if (configured != c.SQLITE_OK) {
        return error.SQLiteHeapConfiguration;
    }
    if (c.sqlite3_config(c.SQLITE_CONFIG_GETMALLOC, &methods) != c.SQLITE_OK) {
        return error.SQLiteAllocatorConfiguration;
    }
    var audited = methods;
    audited.xMalloc = allocate;
    audited.xFree = release;
    audited.xRealloc = resize;
    audited.xSize = size;
    if (c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &audited) != c.SQLITE_OK) {
        return error.SQLiteAllocatorConfiguration;
    }
}

fn size(pointer: ?*anyopaque) callconv(.c) c_int {
    assert(pointer != null);
    const address = @intFromPtr(pointer.?);
    assert(address >= @intFromPtr(pool.ptr));
    assert(address < @intFromPtr(pool.ptr) + pool.len);
    const bytes = methods.xSize.?(pointer);
    assert(bytes > 0);
    assert(@as(u64, @intCast(bytes)) <= @intFromPtr(pool.ptr) + pool.len - address);
    return bytes;
}

fn allocate(bytes: c_int) callconv(.c) ?*anyopaque {
    // memsys5's xRoundup returns zero for requests larger than 1 GiB. SQLite forwards
    // that sentinel to xMalloc/xRealloc; the underlying allocator rejects it safely.
    assert(bytes >= 0);
    assert(pool.len > 0);
    const pointer = methods.xMalloc.?(bytes);
    allocations += 1;
    if (pointer != null) {
        const actual: u32 = @intCast(size(pointer));
        assert(actual >= bytes);
        live_bytes += actual;
        peak_bytes = @max(peak_bytes, live_bytes);
        assert(live_bytes <= pool.len);
    } else failures += 1;
    return pointer;
}

fn release(pointer: ?*anyopaque) callconv(.c) void {
    assert(pointer != null);
    const bytes: u32 = @intCast(size(pointer));
    assert(live_bytes >= bytes);
    live_bytes -= bytes;
    methods.xFree.?(pointer);
}

fn resize(pointer: ?*anyopaque, bytes: c_int) callconv(.c) ?*anyopaque {
    assert(pointer != null);
    assert(bytes >= 0);
    const before: u32 = @intCast(size(pointer));
    const result = methods.xRealloc.?(pointer, bytes);
    allocations += 1;
    if (result != null) {
        const after: u32 = @intCast(size(result));
        assert(after >= bytes);
        assert(live_bytes >= before);
        live_bytes = live_bytes - before + after;
        peak_bytes = @max(peak_bytes, live_bytes);
        assert(live_bytes <= pool.len);
    } else failures += 1;
    return result;
}

test "SQLite dynamically allocates only inside its startup pool and fails closed" {
    try @import("sqlite.zig").initialize();
    const baseline = live_bytes;
    const pointer = c.sqlite3_malloc64(1000) orelse return error.SQLiteAllocation;
    try std.testing.expect(size(pointer) >= 1000);
    try std.testing.expectEqual(live_bytes, @as(u64, @intCast(c.sqlite3_memory_used())));
    const resized = c.sqlite3_realloc64(pointer, 2000) orelse return error.SQLiteAllocation;
    try std.testing.expect(size(resized) >= 2000);
    c.sqlite3_free(resized);
    try std.testing.expectEqual(baseline, live_bytes);
    try std.testing.expect(c.sqlite3_malloc64(pool.len) == null);
    try std.testing.expectEqual(@as(i64, @intCast(pool.len)), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expect(c.sqlite3_memory_used() <= pool.len);
    try std.testing.expect(allocations > 0);
    try std.testing.expect(peak_bytes <= pool.len);
    const recovered = c.sqlite3_malloc64(64) orelse return error.SQLiteAllocation;
    c.sqlite3_free(recovered);
    try std.testing.expectEqual(baseline, live_bytes);
}

test "SQLite hard heap limit rejects before invoking the fixed-pool allocator" {
    try @import("sqlite.zig").initialize();
    const limit = c.sqlite3_hard_heap_limit64(-1);
    const soft_limit = c.sqlite3_soft_heap_limit64(-1);
    defer {
        _ = c.sqlite3_hard_heap_limit64(limit);
        _ = c.sqlite3_soft_heap_limit64(soft_limit);
    }
    const baseline = c.sqlite3_memory_used();
    _ = c.sqlite3_hard_heap_limit64(baseline + 4096);
    const before = allocations;
    try std.testing.expect(c.sqlite3_malloc64(8192) == null);
    try std.testing.expectEqual(before, allocations);
    try std.testing.expectEqual(baseline, c.sqlite3_memory_used());
    const recovered = c.sqlite3_malloc64(64) orelse return error.SQLiteAllocation;
    c.sqlite3_free(recovered);
    try std.testing.expectEqual(baseline, c.sqlite3_memory_used());
}

test "memsys5 oversized allocation sentinel preserves an existing allocation" {
    try @import("sqlite.zig").initialize();
    const baseline = live_bytes;
    const pointer = c.sqlite3_malloc64(64) orelse return error.SQLiteAllocation;
    defer c.sqlite3_free(pointer);
    const bytes = @as([*]u8, @ptrCast(pointer))[0..64];
    @memset(bytes, 0xa5);
    try std.testing.expect(c.sqlite3_malloc64(1073741825) == null);
    try std.testing.expect(c.sqlite3_realloc64(pointer, 1073741825) == null);
    try std.testing.expectEqual(baseline + 64, live_bytes);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
