const std = @import("std");
const assert = std.debug.assert;
const limits = @import("limits.zig");
const constants = limits;

pub const Plan = struct { manifest_nodes: u32, manifest_bytes: u64 };

// Execute the actual upstream initializer with an allocator that records and rejects the
// reservation. This detects narrowed intermediate arithmetic without needing the memory.
pub fn verify_pool(comptime Pool: type, capacity: *const Plan) !void {
    assert(capacity.manifest_nodes > 0);
    assert(capacity.manifest_bytes > 0);
    var reservation: Reservation = .{};
    var pool: Pool = undefined;
    const allocator: std.mem.Allocator = .{ .ptr = &reservation, .vtable = &Reservation.vtable };
    pool.init(allocator, capacity.manifest_nodes) catch |err| {
        if (err != error.OutOfMemory) return err;
        if (reservation.calls != 1 or reservation.bytes != capacity.manifest_bytes) {
            return error.ManifestReservationMismatch;
        }
        return;
    };
    unreachable; // The recording allocator never provides memory.
}

const Reservation = struct {
    calls: u32 = 0,
    bytes: u64 = 0,
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocate,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = release,
    };

    fn allocate(context: *anyopaque, bytes: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Reservation = @ptrCast(@alignCast(context));
        assert(self.calls == 0);
        assert(bytes > 0);
        self.calls += 1;
        self.bytes = bytes;
        return null;
    }

    fn release(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        unreachable; // No allocation succeeds, so there is nothing to release.
    }
};

// The manifest has both key and table arrays. Segmented arrays can be half full. Reserve
// enough nodes for either the entire tree or every physically possible two-block table,
// plus unfinished compactions and partially filled nodes at every level.
pub fn plan(storage_bytes: u64) !Plan {
    assert(constants.block_size == 128 * 1024);
    assert(constants.lsm_manifest_node_size == 16 * 1024);
    if (storage_bytes < limits.storage_size_min) {
        return error.StorageLimitTooSmall;
    }
    if (storage_bytes > limits.storage_size_max) return error.StorageLimitTooLarge;
    if (storage_bytes % constants.block_size != 0) return error.StorageLimitAlignment;
    const tables: u64 = @min(table_count_max, storage_bytes / (2 * constants.block_size) + 1024);
    // TreeTableInfo(u64) occupies 64 bytes; keys occupy 8 bytes. Each node is 16 KiB.
    const nodes: u64 = std.math.divCeil(u64, tables, 128) catch unreachable;
    const key_nodes: u64 = std.math.divCeil(u64, tables, 1024) catch unreachable;
    const total: u64 = @max(1024, nodes + key_nodes + 4 * constants.lsm_levels);
    assert(total <= std.math.maxInt(u32));
    assert(total * constants.lsm_manifest_node_size >= tables * (64 + 8));
    return .{
        .manifest_nodes = @intCast(total),
        .manifest_bytes = total * constants.lsm_manifest_node_size,
    };
}

pub const table_count_max: u64 = blk: {
    var count: u64 = 0;
    var level: u64 = 1;
    for (0..constants.lsm_levels) |_| {
        level *= constants.lsm_growth_factor;
        count += level;
    }
    break :blk count;
};

comptime {
    // Half-full tables at the bottom level alone can hold the entire SQLite address space.
    const last_level_tables = std.math.pow(u64, constants.lsm_growth_factor, constants.lsm_levels);
    const values_per_table = limits.chunks_changed_max * constants.lsm_compaction_ops;
    assert(last_level_tables * values_per_table / 2 * limits.chunk_size > limits.logical_size_max);
    assert(table_count_max < std.math.maxInt(u32));
    assert(limits.logical_size_max / limits.chunk_size + 2 < std.math.maxInt(u64));
}

test "capacity reservation scales through one PiB without allocating it" {
    const small = try plan(constants.storage_size_limit_default);
    const largest = try plan(limits.storage_size_max);
    try std.testing.expectEqual(@as(u32, 1024), small.manifest_nodes);
    try std.testing.expect(largest.manifest_nodes > small.manifest_nodes);
    try std.testing.expect(largest.manifest_bytes > 16 * 1024 * 1024 * 1024);
    try std.testing.expect(largest.manifest_bytes < 32 * 1024 * 1024 * 1024);
    try std.testing.expectError(error.StorageLimitTooSmall, plan(0));
    try std.testing.expectError(error.StorageLimitAlignment, plan(limits.storage_size_max - 1));
    try std.testing.expectError(error.StorageLimitTooLarge, plan(limits.storage_size_max + 1));
}
