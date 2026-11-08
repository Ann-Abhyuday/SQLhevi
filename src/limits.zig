// The small whole-image bound is used by SQLite reference tests, not the paged storage path.
// SQL values also use this bound; the production file address space is logical_size_max.
pub const chunk_size: u32 = 496;
pub const chunk_count_max: u32 = 2048;
pub const database_size_max: u32 = chunk_size * chunk_count_max;
pub const chunks_changed_max: u32 = 8192;
pub const sql_size_max: u32 = 64 * 1024;
pub const statements_max: u32 = 1024;
pub const columns_max: u32 = 2000;
pub const rows_max: u32 = 65536;
pub const progress_calls_max: u32 = 100000;
// One compile-time value controls both memsys5's backing pool and SQLite's hard heap limit.
pub const sqlite_heap_limit: u32 = @import("build_options").sqlite_memory_limit;
pub const sqlite_heap_size: u32 = sqlite_heap_limit;
pub const read_chunks_max: u32 = 65536;
pub const page_size: u32 = 65536;
pub const page_count_max: u64 = 4294967294;
pub const logical_size_max: u64 = page_size * page_count_max;
pub const storage_size_max: u64 = 1024 * 1024 * 1024 * 1024 * 1024;
pub const storage_size_limit_default: u64 = 16 * 1024 * 1024 * 1024;
pub const storage_size_min: u64 = 1024 * 1024 * 1024;
pub const block_size: u32 = 128 * 1024;
pub const lsm_levels: u32 = 9;
pub const lsm_growth_factor: u32 = 8;
pub const lsm_compaction_ops: u32 = 4;
pub const lsm_manifest_node_size: u32 = 16 * 1024;

comptime {
    const assert = @import("std").debug.assert;
    assert(logical_size_max == 281474976579584);
    assert(logical_size_max < storage_size_max / 3);
    assert(chunks_changed_max * chunk_size > page_size * 32);
    assert(read_chunks_max > chunks_changed_max);
    assert(sqlite_heap_limit >= 4 * 1024 * 1024);
    assert(sqlite_heap_limit <= @import("std").math.maxInt(c_int));
}
