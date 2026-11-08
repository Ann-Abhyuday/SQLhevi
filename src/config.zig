const vsr = @import("vsr");
const limits = @import("limits.zig");

// Use the same wire/storage constants in the real executable and simulator.
// Small journals make tests exercise checkpointing and repair frequently.
pub const cluster = blk: {
    var config = vsr.configuration.configs.test_min;
    config.cluster.block_size = limits.block_size;
    config.cluster.journal_slot_count = 128;
    config.cluster.clients_max = 32;
    config.cluster.pipeline_prepare_queue_max = 4;
    config.cluster.view_change_headers_suffix_max = 5;
    config.cluster.message_size_max = 128 * 1024;
    config.cluster.lsm_compaction_ops = limits.lsm_compaction_ops;
    config.cluster.lsm_growth_factor = limits.lsm_growth_factor;
    config.cluster.lsm_levels = limits.lsm_levels;
    config.cluster.lsm_manifest_compact_extra_blocks = 5;
    config.process.storage_size_limit_default = limits.storage_size_limit_default;
    config.process.lsm_manifest_node_size = limits.lsm_manifest_node_size;
    config.process.storage_size_limit_max = @import("limits.zig").storage_size_max;
    config.process.direct_io = true;
    config.process.verify = true;
    break :blk config;
};
