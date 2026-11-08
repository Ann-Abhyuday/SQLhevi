const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const stdx = @import("stdx");
const limits = @import("limits.zig");
const IO = stdx.IO;
const Disk = @import("storage.zig").Disk;
const Storage = @import("storage.zig").Storage;
const MessageBus = vsr.message_bus.MessageBusType(IO);
const MessagePool = vsr.message_pool.MessagePool;
const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const Replica = vsr.ReplicaType(StateMachine, MessageBus, Storage, vsr.aof.AOFType(IO));
const Client = vsr.ClientType(StateMachine.Operation, MessageBus);
pub const tigerbeetle_config = @import("config.zig").cluster;
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len > 0);
    assert(limits.sql_size_max <= vsr.constants.message_body_size_max);
    if (args.len < 2) return usage();
    if (std.mem.eql(u8, args[1], "capacity")) {
        if (args.len != 3) return usage();
        const bytes = try std.fmt.parseInt(u64, args[2], 10);
        const capacity = try @import("capacity.zig").plan(bytes);
        try @import("capacity.zig").verify_pool(
            @FieldType(StateMachine.Forest, "node_pool"),
            &capacity,
        );
        std.debug.print("storage_limit={d} logical_sqlite_limit={d} " ++
            "manifest_nodes={d} manifest_node_bytes={d}\n" ++
            "Additional startup memory is required for maps, free sets, caches and SQLite.\n", .{
            bytes, limits.logical_size_max, capacity.manifest_nodes, capacity.manifest_bytes,
        });
        return;
    }
    if (std.mem.eql(u8, args[1], "version")) {
        std.debug.print("SQLhevi 0.1.0-dev; SQLite {s}; VSR; static; Linux io_uring; " ++
            "SQLite pool/hard limit={d} bytes; local temp spill\n", .{
            @import("sqlite.zig").c.sqlite3_libversion(), limits.sqlite_heap_limit,
        });
        return;
    }
    var io = try IO.init(2048, 0, init.io);
    defer io.deinit();
    var time_os: stdx.TimeOS = .{};
    const time = time_os.interface();
    var tracer = try vsr.trace.Tracer.init(init.gpa, time, .unknown, .{ .writer = null });
    defer tracer.deinit(init.gpa);
    if (std.mem.eql(u8, args[1], "format")) {
        if (args.len != 6) return usage();
        try format(init.gpa, &io, &tracer, args[2..]);
    } else if (std.mem.eql(u8, args[1], "start")) {
        if (args.len != 4 and args.len != 5) return usage();
        try start(init.gpa, &io, time, &tracer, args[2..]);
    } else if (std.mem.eql(u8, args[1], "sql")) {
        if (args.len != 5) return usage();
        try sql(init.gpa, &io, time, args[2..]);
    } else return usage();
}

fn usage() error{Usage} {
    std.debug.print("SQLhevi format <cluster> <replica> <replica-count> <path>\n" ++
        "SQLhevi start <addresses> <path> [storage-limit-bytes]\n" ++
        "SQLhevi sql <cluster> <addresses> <SQL>\n" ++
        "SQLhevi capacity <storage-limit-bytes>\n" ++
        "SQLhevi version\n", .{});
    return error.Usage;
}

fn format(
    allocator: std.mem.Allocator,
    io: *IO,
    tracer: *vsr.trace.Tracer,
    args: []const [:0]const u8,
) !void {
    assert(args.len == 4);
    const cluster = try std.fmt.parseInt(u128, args[0], 10);
    const replica = try std.fmt.parseInt(u8, args[1], 10);
    const count = try std.fmt.parseInt(u8, args[2], 10);
    if (count < 1 or count > vsr.constants.replicas_max) return error.ReplicaCount;
    if (replica >= count) return error.ReplicaIndex;
    var disk: Disk = undefined;
    try disk.open(io, tracer, args[3], .format);
    defer disk.close();
    try vsr.format(Storage, allocator, &disk.storage, .{
        .cluster = cluster,
        .replica = replica,
        .replica_count = count,
        .release = vsr.Release.minimum,
        .view = null,
    });
    assert(disk.storage.unflushed == 0);
    std.debug.print("formatted {s}: cluster={d} replica={d}/{d}\n", .{
        args[3], cluster, replica, count,
    });
}

fn start(
    allocator: std.mem.Allocator,
    io: *IO,
    time: stdx.Time,
    tracer: *vsr.trace.Tracer,
    args: []const [:0]const u8,
) !void {
    assert(args.len == 2 or args.len == 3);
    const storage_limit = if (args.len == 3)
        try std.fmt.parseInt(u64, args[2], 10)
    else
        vsr.constants.storage_size_limit_default;
    const capacity = try @import("capacity.zig").plan(storage_limit);
    var address_buffer: [vsr.constants.members_max]stdx.SocketAddress = undefined;
    const addresses = try vsr.parse_addresses(args[0], &address_buffer);
    assert(addresses.len > 0);
    if (addresses.len > vsr.constants.replicas_max) return error.ReplicaCount;
    var disk: Disk = undefined;
    try disk.open(io, tracer, args[1], .start);
    defer disk.close();
    var scratch_io: @import("scratch_io.zig").Native = undefined;
    try scratch_io.init(disk.storage.dir_fd);
    defer scratch_io.deinit();
    var scratch: @import("scratch.zig").Store = undefined;
    try scratch.init(allocator, &scratch_io.interface());
    defer scratch.deinit(allocator);
    var pool = try MessagePool.init(allocator, .{ .replica = .{
        .members_count = @intCast(addresses.len),
        .pipeline_requests_limit = 28,
        .message_bus = .tcp,
    } });
    defer pool.deinit(allocator);
    var replica: Replica = undefined;
    try replica.open(allocator, time, &disk.storage, &pool, .{
        .node_count = @intCast(addresses.len),
        .release = vsr.Release.minimum,
        .release_client_min = vsr.Release.minimum,
        .multiversion = .single_release(vsr.Release.minimum),
        .pipeline_requests_limit = 28,
        .storage_size_limit = storage_limit,
        .aof = null,
        .aof_recovery = false,
        .random_nonce = io.crypto_random_int(u128),
        .state_machine_options = .{
            .lsm_forest_node_count = capacity.manifest_nodes,
            .scratch_store = &scratch,
        },
        .grid_cache_blocks_count = 128,
        .message_bus_options = .{
            .configuration = addresses,
            .io = io,
            .trace = tracer,
            .time = time,
            .clients_limit = vsr.constants.clients_max,
        },
        .tracer = tracer,
    });
    defer replica.deinit(allocator);
    std.debug.print("SQLhevi replica={d} cluster={d} listening; io_uring storage\n", .{
        replica.replica, replica.cluster,
    });
    while (true) {
        replica.tick();
        try io.run_for_ns(vsr.constants.tick_ms * std.time.ns_per_ms);
    }
    unreachable; // The server event loop intentionally runs until the process is terminated.
}

const Completion = struct {
    done: bool = false,
    reply_size: u32 = 0,
    reply: [vsr.constants.message_body_size_max]u8 = undefined,
};

fn sql(allocator: std.mem.Allocator, io: *IO, time: stdx.Time, args: []const [:0]const u8) !void {
    assert(args.len == 3);
    if (args[2].len == 0 or args[2].len > limits.sql_size_max) return error.SQLSize;
    var address_buffer: [vsr.constants.members_max]stdx.SocketAddress = undefined;
    const addresses = try vsr.parse_addresses(args[1], &address_buffer);
    if (addresses.len > vsr.constants.replicas_max) return error.ReplicaCount;
    assert(addresses.len <= vsr.constants.replicas_max);
    var pool = try MessagePool.init(allocator, .client);
    defer pool.deinit(allocator);
    var client = try Client.init(allocator, time, &pool, .{
        .id = io.crypto_random_int(u128),
        .cluster = try std.fmt.parseInt(u128, args[0], 10),
        .replica_count = @intCast(addresses.len),
        .aof_recovery = false,
        .message_bus_options = .{
            .configuration = addresses,
            .io = io,
            .trace = null,
            .time = time,
            .clients_limit = null,
        },
    });
    defer client.deinit(allocator);
    var completion: Completion = .{};
    client.register(registered, @intFromPtr(&completion));
    try await_reply(io, &client, &completion);
    completion.done = false;
    client.request(replied, @intFromPtr(&completion), .sql, args[2]);
    try await_reply(io, &client, &completion);
    assert(completion.reply_size <= completion.reply.len);
    var stdout = std.Io.File.stdout().writerStreaming(io.io_std.?, &.{});
    try stdout.interface.writeAll(completion.reply[0..completion.reply_size]);
    if (std.mem.startsWith(u8, completion.reply[0..completion.reply_size], "ERR")) {
        return error.SQLRejected;
    }
}

fn await_reply(io: *IO, client: *Client, completion: *Completion) !void {
    assert(!completion.done);
    for (0..6000) |_| {
        client.tick();
        try io.run_for_ns(vsr.constants.tick_ms * std.time.ns_per_ms);
        if (completion.done) return;
    }
    assert(!completion.done);
    // Timeout is indeterminate: the request may have committed, so never retry with a new ID.
    return error.TimeoutIndeterminate;
}

fn registered(user_data: u128, _: *const vsr.RegisterResult) void {
    const completion: *Completion = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!completion.done);
    assert(completion.reply_size == 0);
    completion.done = true;
}

fn replied(
    user_data: u128,
    operation: vsr.Operation,
    _: u64,
    body: []align(vsr.constants.cache_line_size) const u8,
) void {
    const completion: *Completion = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!completion.done);
    assert(body.len <= completion.reply.len);
    assert(operation == StateMachine.Operation.sql.to_vsr());
    @memcpy(completion.reply[0..body.len], body);
    completion.reply_size = @intCast(body.len);
    completion.done = true;
}
