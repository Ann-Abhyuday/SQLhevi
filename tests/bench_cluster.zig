const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const stdx = @import("stdx");
const workload = @import("bench_workload.zig");
const guest = @import("guest.zig");
const Operation = @import("engine").Operation;
const IO = stdx.IO;
const MessagePool = vsr.message_pool.MessagePool;
const Client = vsr.ClientType(Operation, vsr.message_bus.MessageBusType(IO));
const addresses_text = "127.0.0.1:3601,127.0.0.1:3602,127.0.0.1:3603";
pub const tigerbeetle_config = @import("engine").cluster;
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    if (std.os.linux.getpid() == 1) {
        defer guest.poweroff();
        guest.setup() catch |err| {
            std.debug.print("BENCH FAIL setup: {s}\n", .{@errorName(err)});
            return;
        };
        run(&init, &.{
            .server = "/SQLhevi",
            .plain = "/SQLhevi-bench-sqlite",
            .directory = "/data",
        }) catch |err| {
            std.debug.print("BENCH FAIL cluster: {s}\n", .{@errorName(err)});
        };
    } else {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        if (args.len != 4) return error.ExpectedServerBaselineAndEmptyDirectory;
        assert(args[1].len > 0);
        assert(args[3].len > 0);
        try run(&init, &.{ .server = args[1], .plain = args[2], .directory = args[3] });
    }
}

const Paths = struct { server: []const u8, plain: []const u8, directory: []const u8 };

fn run(init: *const std.process.Init, paths: *const Paths) !void {
    assert(paths.server.len > 0);
    assert(paths.directory.len > 0);
    // Run the ordinary durable SQLite baselines on this same disk, before starting replicas.
    var buffer: [4096]u8 = undefined;
    for ([_][]const u8{ "memory", "file" }) |temp| {
        const path = try std.fmt.bufPrint(&buffer, "{s}/sqlite-{s}.db", .{ paths.directory, temp });
        try command(init, &.{ paths.plain, "system", path, temp, "wal_full", "quick" });
    }
    var filenames: [3][4096]u8 = undefined;
    var names: [3][]const u8 = undefined;
    for (0..3) |index| {
        names[index] = try std.fmt.bufPrint(&filenames[index], "{s}/{d}.SQLhevi", .{
            paths.directory, index,
        });
        var id_buffer: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{index});
        try command(init, &.{ paths.server, "format", "0", id, "3", names[index] });
    }
    var replicas: [3]std.process.Child = undefined;
    var count: u32 = 0;
    defer for (replicas[0..count]) |*replica| replica.kill(init.io);
    for (0..3) |index| {
        replicas[index] = try std.process.spawn(init.io, .{
            .argv = &.{ paths.server, "start", addresses_text, names[index], "1073741824" },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        count += 1;
    }
    try client_run(init);
    for (&replicas) |*replica| try process_memory(init, replica.id.?);
    std.debug.print("CLUSTER BENCH PASS: persistent session; io_uring; three replicas\n", .{});
}

fn process_memory(init: *const std.process.Init, pid: std.process.Child.Id) !void {
    _ = init;
    assert(pid > 0);
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/status", .{pid});
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.ProcessStatusOpen;
    const fd: i32 = @intCast(opened);
    defer assert(linux.errno(linux.close(fd)) == .SUCCESS);
    var buffer: [16384]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS) return error.ProcessStatusRead;
    assert(count > 0);
    assert(count < buffer.len);
    const status = buffer[0..count];
    var lines = std.mem.splitScalar(u8, status, '\n');
    for (0..256) |_| {
        const line = lines.next() orelse break;
        if (std.mem.startsWith(u8, line, "VmRSS:") or
            std.mem.startsWith(u8, line, "VmHWM:"))
        {
            std.debug.print("REPLICA_MEMORY pid={d} {s}\n", .{ pid, line });
        }
    }
}

fn command(init: *const std.process.Init, args: []const []const u8) !void {
    assert(args.len > 1);
    assert(args.len <= 6);
    var child = try std.process.spawn(init.io, .{
        .argv = args,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) return error.BenchmarkChildFailed;
}

fn client_run(init: *const std.process.Init) !void {
    var io = try IO.init(2048, 0, init.io);
    defer io.deinit();
    var time_os: stdx.TimeOS = .{};
    var address_buffer: [vsr.constants.members_max]stdx.SocketAddress = undefined;
    const addresses = try vsr.parse_addresses(addresses_text, &address_buffer);
    assert(addresses.len == 3);
    var pool = try MessagePool.init(init.gpa, .client);
    defer pool.deinit(init.gpa);
    var client = try Client.init(init.gpa, time_os.interface(), &pool, .{
        .id = io.crypto_random_int(u128),
        .cluster = 0,
        .replica_count = 3,
        .aof_recovery = false,
        .message_bus_options = .{
            .configuration = addresses,
            .io = &io,
            .trace = null,
            .time = time_os.interface(),
            .clients_limit = null,
        },
    });
    defer client.deinit(init.gpa);
    var adapter: Adapter = .{ .io = &io, .client = &client };
    client.register(registered, @intFromPtr(&adapter));
    try adapter.await_reply();
    assert(adapter.done);
    try workload.run(&adapter, true);
}

const Adapter = struct {
    name: []const u8 = std.fmt.comptimePrint("SQLhevi_cluster_{d}_spill", .{
        @import("engine").sqlite.limits.sqlite_heap_limit / (1024 * 1024),
    }),
    io: *IO,
    client: *Client,
    done: bool = false,
    reply_size: u32 = 0,
    reply: [vsr.constants.message_body_size_max]u8 = undefined,

    pub fn query(self: *Adapter, sql: []const u8) ![]const u8 {
        assert(self.done);
        assert(sql.len <= 65536);
        self.done = false;
        self.client.request(replied, @intFromPtr(self), .sql, sql);
        try self.await_reply();
        const reply = self.reply[0..self.reply_size];
        if (std.mem.eql(u8, reply, "ERR SQLiteMemory\n")) return error.SQLiteMemory;
        if (!std.mem.startsWith(u8, reply, "OK\n\n")) {
            std.debug.print("unexpected reply: {s}\n", .{reply});
            return error.SQLRejected;
        }
        return reply[4..];
    }

    fn await_reply(self: *Adapter) !void {
        assert(!self.done);
        for (0..60000) |_| {
            self.client.tick();
            try self.io.run_for_ns(vsr.constants.tick_ms * std.time.ns_per_ms);
            if (self.done) return;
        }
        assert(!self.done);
        return error.TimeoutIndeterminate;
    }

    pub fn reset_metrics(self: *Adapter) void {
        assert(self.done);
        assert(self.reply_size <= self.reply.len);
    }

    pub fn metrics(self: *Adapter) workload.Metrics {
        assert(self.done);
        assert(self.reply_size <= self.reply.len);
        // Client-side metrics cannot report server heap use; zero means unavailable here.
        return .{};
    }
};

fn registered(user_data: u128, _: *const vsr.RegisterResult) void {
    const adapter: *Adapter = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!adapter.done);
    assert(adapter.reply_size == 0);
    adapter.done = true;
}

fn replied(
    user_data: u128,
    operation: vsr.Operation,
    _: u64,
    body: []align(vsr.constants.cache_line_size) const u8,
) void {
    const adapter: *Adapter = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!adapter.done);
    assert(operation == Operation.sql.to_vsr());
    assert(body.len <= adapter.reply.len);
    @memcpy(adapter.reply[0..body.len], body);
    adapter.reply_size = @intCast(body.len);
    adapter.done = true;
}
