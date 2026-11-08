const std = @import("std");
const assert = std.debug.assert;
const guest = @import("guest.zig");
const addresses = "127.0.0.1:3601,127.0.0.1:3602,127.0.0.1:3603";

pub fn main(init: std.process.Init) !void {
    const in_guest = std.os.linux.getpid() == 1;
    if (in_guest) {
        defer guest.poweroff();
        guest.setup() catch |err| {
            std.debug.print("NATIVE FAIL setup: {s}\n", .{@errorName(err)});
            return;
        };
        run(&init, "/SQLhevi", "/data") catch |err| {
            std.debug.print("NATIVE FAIL cluster: {s}\n", .{@errorName(err)});
            return;
        };
    } else {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        if (args.len != 3) return error.ExpectedExecutableAndEmptyDirectory;
        try run(&init, args[1], args[2]);
    }
}

fn run(init: *const std.process.Init, executable: []const u8, directory: []const u8) !void {
    assert(executable.len > 0);
    assert(directory.len > 0);
    var paths: [3][4096]u8 = undefined;
    var names: [3][]const u8 = undefined;
    for (0..3) |index| {
        names[index] = try std.fmt.bufPrint(&paths[index], "{s}/{d}.SQLhevi", .{
            directory, index,
        });
        var id: [4]u8 = undefined;
        const replica = try std.fmt.bufPrint(&id, "{d}", .{index});
        try command(init, &.{ executable, "format", "0", replica, "3", names[index] }, null);
    }
    var replicas: [3]std.process.Child = undefined;
    var count: u32 = 0;
    defer for (replicas[0..count]) |*replica| replica.kill(init.io);
    for (0..3) |index| {
        replicas[index] = try start(init.io, executable, names[index]);
        count += 1;
    }
    const create = "CREATE TABLE kv(k TEXT PRIMARY KEY, v INTEGER); INSERT INTO kv VALUES('a', 1);";
    try command(init, &.{ executable, "sql", "0", addresses, create }, "OK\n\n");
    try grow(init, executable);
    replicas[0].kill(init.io);
    std.debug.print("NATIVE: primary killed\n", .{});
    const update = "UPDATE kv SET v=v+1; SELECT v FROM kv;";
    try command(init, &.{ executable, "sql", "0", addresses, update }, "OK\n\n2\n");
    replicas[0] = try start(init.io, executable, names[0]);
    try std.Io.sleep(init.io, .fromSeconds(2), .awake);
    for (&replicas) |*replica| replica.kill(init.io);
    std.debug.print("NATIVE: all replicas killed; recovering durable SQL pages\n", .{});
    for (0..3) |index| replicas[index] = try start(init.io, executable, names[index]);
    const recover = "SELECT v FROM kv; INSERT INTO kv VALUES('b', 9); SELECT sum(v) FROM kv;";
    try command(init, &.{ executable, "sql", "0", addresses, recover }, "OK\n\n2\n11\n");
    const pages = "SELECT count(*), sum(length(payload)) FROM big;" ++
        "SELECT length(payload) FROM big WHERE id=303;";
    try command(init, &.{ executable, "sql", "0", addresses, pages }, "OK\n\n304\t1216000\n4000\n");
    std.debug.print("NATIVE PASS: static binary, ext4/io_uring, TCP, failover, restart\n", .{});
}

fn grow(init: *const std.process.Init, executable: []const u8) !void {
    assert(executable.len > 0);
    const create = "CREATE TABLE big(id INTEGER PRIMARY KEY, payload BLOB);";
    try command(init, &.{ executable, "sql", "0", addresses, create }, "OK\n\n");
    var buffer: [512]u8 = undefined;
    for (0..76) |batch| {
        const sql = try std.fmt.bufPrint(
            &buffer,
            "WITH RECURSIVE ids(x) AS (VALUES({d}) UNION ALL SELECT x+1 FROM ids WHERE x<{d}) " ++
                "INSERT INTO big SELECT x, zeroblob(4000) FROM ids;",
            .{ batch * 4, batch * 4 + 3 },
        );
        assert(sql.len < 3072);
        try command(init, &.{ executable, "sql", "0", addresses, sql }, "OK\n\n");
    }
    std.debug.print("NATIVE: 1,216,000 payload bytes written through the paged VFS\n", .{});
}

fn start(io: std.Io, executable: []const u8, path: []const u8) !std.process.Child {
    assert(executable.len > 0);
    assert(path.len > 0);
    return std.process.spawn(io, .{
        .argv = &.{ executable, "start", addresses, path },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn command(init: *const std.process.Init, args: []const []const u8, expected: ?[]const u8) !void {
    assert(args.len > 1);
    assert(args.len <= 6);
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = args,
        .stdout_limit = .limited(16384),
        .stderr_limit = .limited(65536),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(90), .clock = .awake } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}\n{s}\n", .{
            args[1], result.stdout, result.stderr,
        });
        return error.ChildFailed;
    }
    if (expected) |bytes| {
        if (!std.mem.eql(u8, bytes, result.stdout)) {
            std.debug.print("unexpected SQL result: {s}\n", .{result.stdout});
            return error.ResultMismatch;
        }
    }
}
