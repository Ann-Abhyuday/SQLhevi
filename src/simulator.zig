const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const stdx = @import("stdx");
const StateMachineType = @import("state_machine.zig").StateMachineType;
const Cluster = vsr.testing.cluster.ClusterType(StateMachineType);
const Message = vsr.message_pool.MessagePool.Message;
const ratio = stdx.PRNG.ratio;
// The fault atlas enumerates physical blocks. Bound only the simulator's physical disk;
// the SQL address space and all on-disk/wire cluster constants match the native binary.
pub const tigerbeetle_config = blk: {
    var config = @import("config.zig").cluster;
    config.process.storage_size_limit_max = 768 * 1024 * 1024;
    config.process.storage_size_limit_default = 768 * 1024 * 1024;
    break :blk config;
};
pub const std_options: std.Options = .{ .log_level = .err };
pub var simulation_sparse = false;
const ScratchCampaign = @import("scratch_simulation.zig").CampaignType(Cluster);
var campaign: ?*ScratchCampaign = null;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seed = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 1;
    const requests = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 300;
    if (args.len > 4) return error.Arguments;
    const spill = args.len == 4 and std.mem.eql(u8, args[3], "spill");
    if (args.len == 4 and !spill) {
        if (!std.mem.eql(u8, args[3], "sparse")) return error.ExpectedSparseOrSpill;
        simulation_sparse = true;
    }
    var scratch: ScratchCampaign = undefined;
    try scratch.init(init.gpa);
    defer scratch.deinit(init.gpa);
    campaign = &scratch;
    defer campaign = null;
    if (requests < 120 or requests > 100000) return error.RequestCount;
    var run: Simulation = .{};
    const cluster = try create_cluster(init.gpa, seed, &run);
    defer cluster.deinit();
    cluster.context = &run;
    cluster.register(0);
    for (0..100000) |_| {
        tick(cluster, &run);
        if (cluster.clients[0].?.request_inflight == null) break;
    } else return error.RegistrationLiveness;
    const create = "CREATE TABLE ledger(id INTEGER PRIMARY KEY, " ++
        "value INTEGER NOT NULL, payload); CREATE INDEX ledger_value ON ledger(value);";
    try transact(cluster, &run, create);
    if (simulation_sparse) {
        try transact(cluster, &run, "SELECT rootpage FROM sqlite_schema WHERE name='ledger'");
        if (!std.mem.eql(u8, run.reply[0..run.reply_size], "OK\n\n4294967294\n")) {
            return error.MaximumPageFixture;
        }
    }
    try ledger(cluster, &run, .{ .seed = seed, .requests = requests });
    const expected_final = run.reply;
    const expected_final_size = run.reply_size;
    if (spill) try spill_faults(cluster, &run, &scratch);
    try converge(cluster, &run);
    if (!std.mem.eql(u8, expected_final[0..expected_final_size], run.reply[0..run.reply_size])) {
        return error.RecoveryModelMismatch;
    }
    try minority(cluster, &run);
    const digest = run.digest;
    assert(run.view_max > 0);
    assert(run.checkpoint_max > 0);
    const message = "PASS seed={d} requests={d} replies={d} ticks={d} digest={x} " ++
        "view={d} checkpoint={d} faulty_sectors_max={d}\n";
    std.debug.print(message, .{
        seed,         requests,           run.replies,            run.ticks, digest,
        run.view_max, run.checkpoint_max, run.faulty_sectors_max,
    });
}

fn ledger(cluster: *Cluster, run: *Simulation, options: struct { seed: u64, requests: u32 }) !void {
    const seed = options.seed;
    const requests = options.requests;
    assert(requests >= 120);
    assert(cluster.replicas.len == 3);
    for (cluster.storages) |*storage| storage.faulty = true;
    var buffer: [256]u8 = undefined;
    for (0..requests) |index| {
        if (index == 40) {
            // Lose the initial primary while packets and writes remain in flight.
            cluster.replica_crash(0);
        }
        if (index == 65) try cluster.replica_restart(0);
        const sql = try std.fmt.bufPrint(
            &buffer,
            "INSERT INTO ledger VALUES ({d}, {d}, zeroblob(4000));" ++
                "SELECT count(*), sum(value) FROM ledger;",
            .{ index + 1, index + 1 },
        );
        try transact(cluster, run, sql);
        const expected = try std.fmt.bufPrint(&buffer, "OK\n\n{d}\t{d}\n", .{
            index + 1, (index + 1) * (index + 2) / 2,
        });
        if (!std.mem.eql(u8, expected, run.reply[0..run.reply_size])) return error.SQLModelMismatch;
        if (index % 100 == 99) std.debug.print("progress seed={d} requests={d} ticks={d}\n", .{
            seed, index + 1, run.ticks,
        });
    }
}

fn spill_faults(cluster: *Cluster, run: *Simulation, scratch: *ScratchCampaign) !void {
    const model = @import("scratch_testing.zig");
    assert(cluster.replicas.len == 3);
    assert(scratch.failures == 0);
    try transact(cluster, run, "CREATE TABLE guard(v); INSERT INTO guard VALUES(0)");
    const faults = [_]model.Fault{
        .open, .read, .write, .close, .corrupt_read, .corrupt_write, .lost_write,
    };
    var updates: u32 = 0;
    for (faults, 0..) |fault_kind, index| {
        scratch.arm(cluster, .{
            .fault = fault_kind,
            .after = if (fault_kind == .open or fault_kind == .close or fault_kind == .lost_write)
                0
            else
                @intCast(index * 3),
        });
        const before = scratch.failures;
        try transact(cluster, run, if (index % 2 == 0) model.write_query else model.query);
        if (index % 2 == 0) updates += 11;
        for (0..200000) |_| {
            tick(cluster, run);
            if (scratch.failures == before + 1) break;
        } else return error.ScratchFaultNotReached;
        // Ensure the recovered member has replayed the request before injecting the next fault.
        for (0..200000) |_| {
            tick(cluster, run);
            if (cluster.replica_health[0] != .up or cluster.replica_health[1] != .up or
                cluster.replica_health[2] != .up) continue;
            const committed = cluster.replicas[0].commit_min;
            if (cluster.replicas[1].commit_min == committed and
                cluster.replicas[2].commit_min == committed) break;
        } else return error.ScratchReplayLiveness;
        try transact(cluster, run, "SELECT v FROM guard");
        var expected: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "OK\n\n{d}\n", .{updates});
        if (!std.mem.eql(u8, text, run.reply[0..run.reply_size])) return error.ScratchAtomicity;
    }
    for (&scratch.members) |*member| {
        assert(member.store.written_bytes > 0);
        assert(member.store.read_bytes > 0);
    }
    try converge(cluster, run);
    try transact(cluster, run, "SELECT v FROM guard");
    if (!std.mem.eql(u8, "OK\n\n44\n", run.reply[0..run.reply_size])) return error.ScratchRecovery;
    std.debug.print("SPILL PASS faults={d}; local files, replica death, replay, atomic writes\n", .{
        scratch.failures,
    });
}

const Simulation = struct {
    replies: u32 = 0,
    ticks: u64 = 0,
    reply_size: u32 = 0,
    reply: [vsr.constants.message_body_size_max]u8 = undefined,
    view_max: u32 = 0,
    checkpoint_max: u64 = 0,
    faulty_sectors_max: u32 = 0,
    digest: u128 = 0,
};

fn create_cluster(allocator: std.mem.Allocator, seed: u64, _: *Simulation) !*Cluster {
    assert(vsr.constants.verify);
    assert(vsr.constants.replicas_max >= 3);
    const release = vsr.Release.minimum;
    const releases = &[_]vsr.testing.cluster.Release{.{
        .release = release,
        .release_client_min = release,
    }};
    return Cluster.init(allocator, .{
        .cluster = .{
            .cluster_id = 0,
            .replica_count = 3,
            .standby_count = 0,
            .client_count = 1,
            .storage_size_limit = 768 * 1024 * 1024,
            .reformats_max = 0,
            .seed = seed,
            .releases = releases,
            .client_release = release,
            .state_machine = .{},
        },
        .network = .{
            .node_count = 3,
            .client_count = 1,
            .seed = seed,
            .one_way_delay_mean = .ms(25),
            .one_way_delay_min = .ms(1),
            .packet_loss_probability = ratio(2, 100),
            .packet_replay_probability = ratio(2, 100),
            .partition_mode = .isolate_single,
            .partition_symmetry = .asymmetric,
            .partition_probability = ratio(1, 1000),
            .unpartition_probability = ratio(1, 50),
            .partition_stability = 20,
            .unpartition_stability = 100,
            .path_maximum_capacity = 20,
            .path_clog_duration_mean = .ms(100),
            .path_clog_probability = ratio(1, 1000),
        },
        .storage = .{
            .size = 768 * 1024 * 1024,
            .seed = seed,
            .read_latency_min = .ms(1),
            .read_latency_mean = .ms(10),
            .write_latency_min = .ms(1),
            .write_latency_mean = .ms(20),
            .read_fault_probability = ratio(1, 100),
            .write_fault_probability = ratio(1, 100),
            .write_misdirect_probability = ratio(1, 1000),
            .crash_fault_probability = ratio(1, 2),
        },
        .storage_fault_atlas = .{
            .faulty_superblock = true,
            .faulty_wal_headers = true,
            .faulty_wal_prepares = true,
            .faulty_client_replies = true,
            .faulty_grid = true,
        },
        .callbacks = .{ .on_client_reply = on_reply },
    });
}

fn transact(cluster: *Cluster, run: *Simulation, sql: []const u8) !void {
    assert(sql.len > 0);
    assert(sql.len <= @import("limits.zig").sql_size_max);
    const prior = run.replies;
    const message = cluster.clients[0].?.get_message();
    @memcpy(message.buffer[@sizeOf(vsr.Header)..][0..sql.len], sql);
    cluster.request(0, .sql, message, sql.len);
    for (0..200000) |_| {
        tick(cluster, run);
        if (run.replies > prior) break;
    } else return error.SimulationLiveness;
    if (!std.mem.startsWith(u8, run.reply[0..run.reply_size], "OK\n\n")) {
        std.debug.print("SQL failed: {s}: {s}\n", .{ sql, run.reply[0..run.reply_size] });
        return error.SQLFailure;
    }
}

fn on_reply(
    cluster: *Cluster,
    client: usize,
    request: *const Message.Request,
    reply: *const Message.Reply,
) void {
    assert(client == 0);
    if (reply.header.operation == .register) return;
    const run: *Simulation = @ptrCast(@alignCast(cluster.context.?));
    const body = reply.body_used();
    assert(body.len <= run.reply.len);
    @memcpy(run.reply[0..body.len], body);
    run.reply_size = @intCast(body.len);
    run.replies += 1;
    var hash = vsr.ChecksumStream.init();
    hash.add(std.mem.asBytes(&run.digest));
    hash.add(request.body_used());
    hash.add(body);
    run.digest = hash.checksum();
}

fn converge(cluster: *Cluster, run: *Simulation) !void {
    assert(cluster.replicas.len == 3);
    assert(run.replies > 0);
    var core: Cluster.Network.Core = .{};
    for (0..3) |index| core.set(index);
    cluster.network.transition_to_liveness_mode(core);
    for (cluster.storages) |*storage| storage.faulty = false;
    // Restart every replica from durable bytes; no SQLite connection/image survives.
    for (0..3) |index| cluster.replica_crash(@intCast(index));
    for (0..3) |index| try cluster.replica_restart(@intCast(index));
    try transact(cluster, run, "SELECT count(*), sum(value) FROM ledger;");
    const commit = cluster.clients[0].?.request_number;
    assert(commit > 0);
    for (0..200000) |_| {
        tick(cluster, run);
        const head = cluster.replicas[0].commit_min;
        if (head == cluster.replicas[1].commit_min and head == cluster.replicas[2].commit_min) {
            for (cluster.replicas[1..]) |*replica| {
                const first = &cluster.replicas[0].state_machine;
                const other = &replica.state_machine;
                if (first.pager.size != other.pager.size) return error.ReplicaImageMismatch;
                for (first.pager.entries[0..first.pager.count]) |*entry| {
                    const match = other.pager.get(entry.chunk.timestamp) orelse {
                        return error.ReplicaReadSetMismatch;
                    };
                    if (!stdx.equal_bytes(@TypeOf(entry.chunk), &entry.chunk, &match.chunk)) {
                        return error.ReplicaImageMismatch;
                    }
                }
            }
            return;
        }
    }
    return error.Convergence;
}

fn tick(cluster: *Cluster, run: *Simulation) void {
    assert(cluster.replicas.len == 3);
    assert(run.ticks < 100000000);
    if (campaign) |scratch| scratch.before_tick(cluster);
    cluster.tick();
    if (campaign) |scratch| scratch.after_tick(cluster);
    run.ticks += 1;
    var faults: u32 = 0;
    for (cluster.storages, cluster.replicas, cluster.replica_health) |*storage, *replica, health| {
        faults += @intCast(storage.faults.count());
        if (health == .up) {
            run.view_max = @max(run.view_max, replica.view);
            run.checkpoint_max = @max(run.checkpoint_max, replica.op_checkpoint());
        }
    }
    run.faulty_sectors_max = @max(run.faulty_sectors_max, faults);
}

fn minority(cluster: *Cluster, run: *Simulation) !void {
    assert(cluster.replicas.len == 3);
    const replies_before = run.replies;
    cluster.replica_crash(1);
    cluster.replica_crash(2);
    const sql = "INSERT INTO ledger VALUES (1000001, 7, null); SELECT count(*) FROM ledger";
    const message = cluster.clients[0].?.get_message();
    @memcpy(message.buffer[@sizeOf(vsr.Header)..][0..sql.len], sql);
    cluster.request(0, .sql, message, sql.len);
    for (0..1000) |_| tick(cluster, run);
    if (run.replies != replies_before) return error.MinorityAcknowledgedWrite;
    try cluster.replica_restart(1);
    try cluster.replica_restart(2);
    for (0..200000) |_| {
        tick(cluster, run);
        if (run.replies > replies_before) break;
    } else return error.MajorityRecovery;
    assert(run.replies == replies_before + 1);
    // The request was retried many times with the same session/request id. It must execute once.
    try transact(cluster, run, "SELECT count(*) FROM ledger WHERE id=1000001;");
    if (!std.mem.eql(u8, run.reply[0..run.reply_size], "OK\n\n1\n")) {
        return error.DuplicateExecution;
    }
}
