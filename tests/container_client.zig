const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const stdx = @import("stdx");
const Operation = @import("engine").Operation;
const IO = stdx.IO;
const MessagePool = vsr.message_pool.MessagePool;
const Client = vsr.ClientType(Operation, vsr.message_bus.MessageBusType(IO));
pub const addresses = "127.0.0.1:3601,127.0.0.1:3602,127.0.0.1:3603," ++
    "127.0.0.1:3604,127.0.0.1:3605,127.0.0.1:3606";

// Initialize in place: the upstream message bus retains pointers to IO, time, and pool.
pub const Connection = struct {
    io: IO,
    time: stdx.TimeOS = .{},
    pool: MessagePool,
    client: Client,
    done: bool = false,
    reply_size: usize = 0,
    reply: [vsr.constants.message_body_size_max]u8 = undefined,
    queries: u32 = 0,
    ticks: u64 = 0,
    wait_max: u32 = 0,

    pub fn init(self: *Connection, process: *const std.process.Init) !void {
        self.* = .{ .io = undefined, .pool = undefined, .client = undefined };
        self.io = try IO.init(2048, 0, process.io);
        errdefer self.io.deinit();
        self.pool = try MessagePool.init(process.gpa, .client);
        errdefer self.pool.deinit(process.gpa);
        var buffer: [vsr.constants.members_max]stdx.SocketAddress = undefined;
        const configuration = try vsr.parse_addresses(addresses, &buffer);
        assert(configuration.len == 6);
        assert(vsr.constants.replicas_max >= configuration.len);
        self.client = try Client.init(process.gpa, self.time.interface(), &self.pool, .{
            .id = self.io.crypto_random_int(u128),
            .cluster = 0,
            .replica_count = 6,
            .aof_recovery = false,
            .message_bus_options = .{
                .configuration = configuration,
                .io = &self.io,
                .trace = null,
                .time = self.time.interface(),
                .clients_limit = null,
            },
        });
        errdefer self.client.deinit(process.gpa);
        self.client.register(registered, @intFromPtr(self));
        try self.await_reply();
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        assert(self.reply_size <= self.reply.len);
        self.client.deinit(allocator);
        self.pool.deinit(allocator);
        self.io.deinit();
    }

    pub fn submit(self: *Connection, sql: []const u8) void {
        assert(self.done);
        assert(sql.len > 0);
        assert(sql.len <= 65536);
        self.done = false;
        self.reply_size = 0;
        self.queries += 1;
        self.client.request(replied, @intFromPtr(self), .sql, sql);
    }

    pub fn pump(self: *Connection, ticks: u32) !void {
        assert(ticks > 0);
        assert(ticks <= 20000);
        for (0..ticks) |_| {
            self.client.tick();
            try self.io.run_for_ns(vsr.constants.tick_ms * std.time.ns_per_ms);
            self.ticks += 1;
        }
    }

    pub fn await_reply(self: *Connection) !void {
        for (0..20000) |tick| {
            if (self.done) {
                self.wait_max = @max(self.wait_max, @as(u32, @intCast(tick)));
                assert(self.reply_size <= self.reply.len);
                return;
            }
            try self.pump(1);
        }
        assert(!self.done);
        return error.TimeoutIndeterminate;
    }

    pub fn result(self: *Connection) ![]const u8 {
        try self.await_reply();
        assert(self.done);
        const bytes = self.reply[0..self.reply_size];
        if (!std.mem.startsWith(u8, bytes, "OK\n\n")) {
            std.debug.print("CHAOS SQL rejected: {s}\n", .{bytes});
            return error.SQLRejected;
        }
        assert(bytes.len >= 4);
        return bytes[4..];
    }

    pub fn query(self: *Connection, sql: []const u8) ![]const u8 {
        assert(self.done);
        assert(sql.len > 0);
        self.submit(sql);
        return self.result();
    }
};

fn registered(user_data: u128, _: *const vsr.RegisterResult) void {
    const self: *Connection = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!self.done);
    assert(self.reply_size == 0);
    self.done = true;
}

fn replied(
    user_data: u128,
    operation: vsr.Operation,
    _: u64,
    body: []align(vsr.constants.cache_line_size) const u8,
) void {
    const self: *Connection = @ptrFromInt(@as(usize, @intCast(user_data)));
    assert(!self.done);
    assert(operation == Operation.sql.to_vsr());
    assert(body.len <= self.reply.len);
    @memcpy(self.reply[0..body.len], body);
    self.reply_size = body.len;
    self.done = true;
}
