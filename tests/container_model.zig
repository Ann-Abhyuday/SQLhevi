const std = @import("std");
const assert = std.debug.assert;
const Connection = @import("container_client.zig").Connection;

pub const Model = struct {
    seed: u64,
    acknowledged: u32 = 0,
    sum: u64 = 0,
    verified: u32 = 0,
    rejected: u32 = 0,

    pub fn setup(self: *Model, connection: *Connection) !void {
        assert(self.acknowledged == 0);
        assert(self.sum == 0);
        const result = try connection.query(
            "CREATE TABLE ledger(id INTEGER PRIMARY KEY, v INTEGER NOT NULL);" ++
                "CREATE TABLE audit(id INTEGER PRIMARY KEY, v INTEGER NOT NULL);" ++
                "CREATE TABLE balances(id INTEGER PRIMARY KEY, amount INTEGER NOT NULL);" ++
                "INSERT INTO balances VALUES(0,0);",
        );
        if (result.len != 0) return error.SchemaResult;
    }

    pub fn submit(self: *const Model, connection: *Connection) !void {
        assert(self.acknowledged < 4096);
        assert(connection.done);
        var buffer: [1024]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buffer, "INSERT INTO ledger VALUES({d},{d});" ++
            "INSERT INTO audit VALUES({d},-{d});" ++
            "UPDATE balances SET amount=amount+{d} WHERE id=0;" ++
            "SELECT amount FROM balances WHERE id=0;", .{
            self.acknowledged,
            self.value(self.acknowledged),
            self.acknowledged,
            self.value(self.acknowledged),
            self.value(self.acknowledged),
        });
        connection.submit(sql);
    }

    pub fn accept(self: *Model, connection: *Connection) !void {
        assert(self.acknowledged < 4096);
        const response = try connection.result();
        const sum = self.sum + self.value(self.acknowledged);
        var buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "{d}\n", .{sum});
        if (!std.mem.eql(u8, response, expected)) return error.WriteResultMismatch;
        self.acknowledged += 1;
        self.sum = sum;
        assert(connection.done);
    }

    pub fn write(self: *Model, connection: *Connection) !void {
        assert(connection.done);
        assert(self.acknowledged < 4096);
        try self.submit(connection);
        try self.accept(connection);
    }

    pub fn verify(self: *Model, connection: *Connection) !void {
        assert(connection.done);
        assert(self.acknowledged > 0);
        const rows = try connection.query(
            "SELECT l.id,l.v,a.v FROM ledger l LEFT JOIN audit a ON l.id=a.id ORDER BY l.id;" ++
                "SELECT amount FROM balances WHERE id=0; SELECT count(*) FROM audit;",
        );
        var iterator = std.mem.splitScalar(u8, rows, '\n');
        var buffer: [128]u8 = undefined;
        for (0..self.acknowledged) |id| {
            const expected = try std.fmt.bufPrint(&buffer, "{d}\t{d}\t-{d}", .{
                id, self.value(@intCast(id)), self.value(@intCast(id)),
            });
            const row = iterator.next() orelse return error.MissingAcknowledgedWrite;
            if (!std.mem.eql(u8, row, expected)) return error.AcknowledgedRowMismatch;
        }
        const total = iterator.next() orelse return error.MissingBalance;
        if (!std.mem.eql(u8, total, try std.fmt.bufPrint(&buffer, "{d}", .{self.sum}))) {
            return error.AtomicBalanceMismatch;
        }
        const count = iterator.next() orelse return error.MissingAuditCount;
        const expected_count = try std.fmt.bufPrint(&buffer, "{d}", .{self.acknowledged});
        if (!std.mem.eql(u8, count, expected_count)) return error.AuditCountMismatch;
        if ((iterator.next() orelse return error.MissingTerminator).len != 0) {
            return error.ExtraWrite;
        }
        if (iterator.next() != null) return error.ExtraRows;
        self.verified += 1;
        std.debug.print("CHAOS verified rows={d} sum={d} view={d}\n", .{
            self.acknowledged, self.sum, connection.client.view,
        });
    }

    pub fn reject_atomic(self: *Model, connection: *Connection) !void {
        assert(self.acknowledged > 0);
        assert(connection.done);
        var buffer: [512]u8 = undefined;
        const template = "UPDATE balances SET amount=amount+999999;" ++
            "INSERT INTO ledger VALUES({d},999999); INSERT INTO ledger VALUES(0,0);";
        const sql = try std.fmt.bufPrint(&buffer, template, .{self.acknowledged});
        connection.submit(sql);
        try connection.await_reply();
        if (!std.mem.startsWith(u8, connection.reply[0..connection.reply_size], "ERR ")) {
            return error.ExpectedConstraintRejection;
        }
        self.rejected += 1;
        try self.verify(connection);
    }

    fn value(self: *const Model, id: u32) u64 {
        assert(id < 4096);
        assert(self.seed <= 1000000);
        return self.seed + 17 * @as(u64, id) + 1;
    }
};
