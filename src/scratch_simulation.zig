const std = @import("std");
const assert = std.debug.assert;
const scratch = @import("scratch.zig");
const model = @import("scratch_testing.zig");

pub fn CampaignType(comptime Cluster: type) type {
    return struct {
        members: [3]Member = undefined,
        failures: u32 = 0,
        const Campaign = @This();
        const Member = struct {
            memory: model.Memory,
            store: scratch.Store,
            restart_after: u32 = 0,
        };

        pub fn init(self: *Campaign, allocator: std.mem.Allocator) !void {
            self.* = .{};
            var count: usize = 0;
            errdefer for (self.members[0..count]) |*member| {
                member.store.deinit(allocator);
                member.memory.deinit(allocator);
            };
            for (&self.members) |*member| {
                member.restart_after = 0;
                try member.memory.init(allocator);
                errdefer member.memory.deinit(allocator);
                try member.store.init(allocator, &member.memory.interface());
                count += 1;
            }
            assert(count == self.members.len);
            assert(self.failures == 0);
        }

        pub fn deinit(self: *Campaign, allocator: std.mem.Allocator) void {
            assert(self.members.len == 3);
            for (&self.members) |*member| {
                assert(member.store.cached == null);
                member.store.deinit(allocator);
                member.memory.deinit(allocator);
            }
        }

        pub fn before_tick(self: *Campaign, cluster: *Cluster) void {
            assert(cluster.replicas.len == self.members.len);
            for (&self.members, 0..) |*member, index| {
                if (member.restart_after != 0) {
                    assert(cluster.replica_health[index] == .down);
                    member.restart_after -= 1;
                    if (member.restart_after == 0) {
                        member.store.reset();
                        cluster.replica_restart(@intCast(index)) catch @panic("scratch restart");
                    }
                }
                if (cluster.replica_health[index] != .up) continue;
                const machine = &cluster.replicas[index].state_machine;
                machine.engine.scratch_store = &member.store;
                machine.options.scratch_fault = fault;
            }
        }

        pub fn after_tick(self: *Campaign, cluster: *Cluster) void {
            assert(cluster.replicas.len == self.members.len);
            for (&self.members, 0..) |*member, index| {
                if (cluster.replica_health[index] != .up or member.store.failure == null) continue;
                assert(cluster.replicas[index].state_machine.pager.write_count == 0);
                cluster.replica_crash(@intCast(index));
                member.restart_after = 10;
                self.failures += 1;
            }
        }

        fn fault(machine: *Cluster.StateMachine) void {
            assert(machine.engine.scratch_store.?.failure != null);
            assert(machine.pager.write_count == 0);
            // Defer the simulated process death until the storage callback stack has unwound.
            // In the native executable this same path exits the entire replica with status 74.
        }

        pub fn arm(self: *Campaign, cluster: *Cluster, options: struct {
            fault: model.Fault,
            after: u32,
        }) void {
            assert(options.fault != .none);
            var view: u32 = 0;
            for (cluster.replicas, cluster.replica_health) |*replica, health| {
                if (health == .up) view = @max(view, replica.view);
            }
            const primary = view % 3;
            assert(cluster.replica_health[primary] == .up);
            const memory = &self.members[primary].memory;
            memory.fault = options.fault;
            memory.after = options.after;
            memory.fired = false;
        }
    };
}
