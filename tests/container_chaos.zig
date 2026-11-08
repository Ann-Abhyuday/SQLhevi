const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const guest = @import("guest.zig");
const runtime = @import("container_runtime.zig");
const Connection = @import("container_client.zig").Connection;
const Model = @import("container_model.zig").Model;
pub const tigerbeetle_config = @import("engine").cluster;
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    // This driver owns namespaces, cgroups, PID-1 reaping, and a disposable guest disk.
    if (std.os.linux.getpid() != 1) return error.RunAsGuestInit;
    defer {
        // Preserve harness logs and OCI bundles on the disposable guest disk.
        _ = std.os.linux.sync();
        guest.poweroff();
    }
    run(&init) catch |err| {
        std.debug.print("CONTAINER CHAOS FAIL: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("CONTAINER CHAOS ALL PASS: seeds=7,42,777\n", .{});
}

fn run(init: *const std.process.Init) !void {
    try guest.setup();
    try runtime.setup();
    const quorums = vsr.quorums(6);
    assert(quorums.replication == 3);
    assert(quorums.view_change == 4);
    std.debug.print("CHAOS six replicas: replication quorum={d}, view-change quorum={d}\n", .{
        quorums.replication, quorums.view_change,
    });
    for ([_]u64{ 7, 42, 777 }) |seed| try campaign(init, seed);
}

fn campaign(init: *const std.process.Init, seed: u64) !void {
    assert(seed <= 1000000);
    var directory_buffer: [128]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, "/data/seed-{d}", .{seed});
    var cluster: runtime.Cluster = .{ .process = init, .directory = directory };
    try cluster.init();
    defer cluster.cleanup();
    std.debug.print("CHAOS seed={d} begin\n", .{seed});
    for (0..6) |index| try cluster.start(index);
    var connection: Connection = undefined;
    try connection.init(init);
    defer connection.deinit(init.gpa);
    var model: Model = .{ .seed = seed };
    try model.setup(&connection);
    for (0..64) |_| try model.write(&connection);
    var prng = std.Random.DefaultPrng.init(seed);
    var chaos: Chaos = .{
        .cluster = &cluster,
        .connection = &connection,
        .model = &model,
        .random = prng.random(),
    };
    try chaos.random_restarts();
    try chaos.lagging_replica();
    try chaos.quorum_outage();
    try chaos.complete_restart();
    try chaos.rotate_survivors();
    try model.verify(&connection);
    for (cluster.kills) |kills| assert(kills > 0);
    assert(model.acknowledged == 488);
    std.debug.print("CONTAINER CHAOS PASS seed={d} acknowledged={d} verified={d} " ++
        "atomic_rejections={d} kills={any} starts={any} pending_at_kill={d} " ++
        "queries={d} max_wait_ticks={d} final_view={d}\n", .{
        seed,
        model.acknowledged,
        model.verified,
        model.rejected,
        cluster.kills,
        cluster.starts,
        chaos.pending_at_kill,
        connection.queries,
        connection.wait_max,
        connection.client.view,
    });
}

const Chaos = struct {
    cluster: *runtime.Cluster,
    connection: *Connection,
    model: *Model,
    random: std.Random,
    pending_at_kill: u32 = 0,

    fn random_restarts(self: *Chaos) !void {
        assert(self.cluster.count() == 6);
        for (0..16) |round| {
            var order = [_]usize{ 0, 1, 2, 3, 4, 5 };
            self.random.shuffle(usize, &order);
            // Half the rounds deliberately include the last observed primary.
            if (round % 2 == 0) {
                const leader = self.connection.client.view % 6;
                for (0..6) |index| {
                    if (order[index] == leader) std.mem.swap(usize, &order[0], &order[index]);
                }
            }
            try self.model.submit(self.connection);
            try self.connection.pump(self.random.intRangeAtMost(u32, 1, 3));
            if (!self.connection.done) self.pending_at_kill += 1;
            try self.cluster.stop(order[0]);
            try self.connection.pump(self.random.intRangeAtMost(u32, 1, 10));
            try self.cluster.stop(order[1]);
            try self.model.accept(self.connection);
            for (0..15) |_| try self.model.write(self.connection);
            try self.model.verify(self.connection);
            if (round % 4 == 0) try self.model.reject_atomic(self.connection);
            const first = self.random.intRangeAtMost(usize, 0, 1);
            try self.cluster.start(order[first]);
            try self.connection.pump(self.random.intRangeAtMost(u32, 1, 20));
            try self.cluster.start(order[1 - first]);
            std.debug.print("CHAOS round={d} completed with two replicas unavailable\n", .{round});
        }
        assert(self.cluster.count() == 6);
    }

    fn lagging_replica(self: *Chaos) !void {
        assert(self.cluster.count() == 6);
        const index = self.random.uintLessThan(usize, 6);
        try self.cluster.stop(index);
        // More writes than the 128-slot VSR journal: exercise recovery beyond a short outage.
        for (0..160) |_| try self.model.write(self.connection);
        try self.model.verify(self.connection);
        try self.cluster.start(index);
        try self.connection.pump(200);
        assert(self.model.acknowledged == 480);
        std.debug.print("CHAOS long outage recovered node={d} after 160 writes\n", .{index});
    }

    fn quorum_outage(self: *Chaos) !void {
        assert(self.cluster.count() == 6);
        var order = [_]usize{ 0, 1, 2, 3, 4, 5 };
        self.random.shuffle(usize, &order);
        for (order[0..4]) |index| try self.cluster.stop(index);
        try self.model.submit(self.connection);
        try self.connection.pump(300);
        if (self.connection.done) return error.WriteAcknowledgedWithoutQuorum;
        assert(self.cluster.count() == 2);
        std.debug.print("CHAOS quorum unavailable: two live, no acknowledgement " ++
            "for 300 ticks\n", .{});
        for (order[0..2]) |index| try self.cluster.start(index);
        // The original request stays in the original session throughout the outage.
        try self.model.accept(self.connection);
        try self.model.verify(self.connection);
        for (order[2..4]) |index| try self.cluster.start(index);
    }

    fn complete_restart(self: *Chaos) !void {
        assert(self.cluster.count() == 6);
        try self.model.verify(self.connection);
        var order = [_]usize{ 0, 1, 2, 3, 4, 5 };
        self.random.shuffle(usize, &order);
        for (order) |index| try self.cluster.stop(index);
        assert(self.cluster.count() == 0);
        try self.model.submit(self.connection);
        try self.connection.pump(100);
        if (self.connection.done) return error.WriteAcknowledgedWithoutReplicas;
        self.random.shuffle(usize, &order);
        for (order) |index| try self.cluster.start(index);
        try self.model.accept(self.connection);
        try self.model.verify(self.connection);
        std.debug.print("CHAOS all six SIGKILL/restart: acknowledged rows preserved\n", .{});
    }

    fn rotate_survivors(self: *Chaos) !void {
        assert(self.cluster.count() == 6);
        for (0..6) |index| {
            const next = (index + 1) % 6;
            try self.cluster.stop(index);
            try self.cluster.stop(next);
            try self.model.verify(self.connection);
            try self.model.write(self.connection);
            try self.cluster.start(next);
            try self.cluster.start(index);
        }
        assert(self.cluster.count() == 6);
    }
};
