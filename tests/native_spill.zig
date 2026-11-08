const std = @import("std");
const assert = std.debug.assert;
const guest = @import("guest.zig");
const fixture = @import("fixture");
const addresses = "127.0.0.1:3701,127.0.0.1:3702,127.0.0.1:3703";
const Paths = struct { server: []const u8, directory: []const u8 };

pub fn main(init: std.process.Init) !void {
    const in_guest = std.os.linux.getpid() == 1;
    if (in_guest) {
        defer guest.poweroff();
        guest.setup() catch |err| {
            std.debug.print("SPILL NATIVE FAIL setup: {s}\n", .{@errorName(err)});
            return;
        };
        run(&init, &.{ .server = "/SQLhevi-fault-test", .directory = "/data" }) catch |err| {
            std.debug.print("SPILL NATIVE FAIL: {s}\n", .{@errorName(err)});
            return;
        };
    } else {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        if (args.len != 3) return error.ExpectedTestServerAndEmptyDirectory;
        try run(&init, &.{ .server = args[1], .directory = args[2] });
    }
}

fn run(init: *const std.process.Init, paths: *const Paths) !void {
    assert(paths.server.len > 0);
    assert(paths.directory.len > 0);
    var buffers: [3][4096]u8 = undefined;
    var names: [3][]const u8 = undefined;
    for (0..3) |index| {
        names[index] = try std.fmt.bufPrint(&buffers[index], "{s}/{d}.SQLhevi", .{
            paths.directory, index,
        });
        var id_buffer: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{index});
        try command(init, &.{ paths.server, "format", "0", id, "3", names[index] }, "");
    }
    var replicas: [3]std.process.Child = undefined;
    var count: u32 = 0;
    defer for (replicas[0..count]) |*replica| replica.kill(init.io);
    for (0..3) |index| {
        replicas[index] = try start(init, paths.server, names[index], "none");
        count += 1;
    }
    try sql(init, paths.server, "CREATE TABLE guard(v); INSERT INTO guard VALUES(0);", "OK\n\n");
    for ([_][]const u8{ "kill_read", "corrupt_write", "kill_write" }, 0..) |fault, index| {
        replicas[0].kill(init.io);
        replicas[0] = try start(init, paths.server, names[0], fault);
        try sql(
            init,
            paths.server,
            if (index == 0) fixture.query else fixture.write_query,
            "OK\n\n16777216\n",
        );
        const term = try replicas[0].wait(init.io);
        if (std.mem.startsWith(u8, fault, "kill")) {
            if (term != .signal or term.signal != std.os.linux.SIG.KILL) return error.ExpectedKill;
        } else if (term != .exited or term.exited != 74) return error.ExpectedLocalFaultExit;
        replicas[0] = try start(init, paths.server, names[0], "none");
        try sql(init, paths.server, "SELECT v FROM guard", switch (index) {
            0 => "OK\n\n0\n",
            1 => "OK\n\n11\n",
            2 => "OK\n\n22\n",
            else => unreachable,
        });
    }
    // A materialized join substantially larger than the optional 64 MiB test build's heap.
    const large = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL " ++
        "SELECT x+1 FROM n WHERE x<16384), " ++
        "m AS MATERIALIZED (SELECT x, zeroblob(8192) AS p FROM n) " ++
        "SELECT sum(length(a.p)) FROM m a JOIN m b ON a.x=b.x;";
    try sql(init, paths.server, large, "OK\n\n134217728\n");
    for (&replicas) |*replica| replica.kill(init.io);
    for (0..3) |index| replicas[index] = try start(init, paths.server, names[index], "none");
    try sql(init, paths.server, "SELECT v FROM guard", "OK\n\n22\n");
    std.debug.print("SPILL NATIVE PASS: read kill, write corruption/kill, replay, " ++
        "128 MiB join, full restart, atomic result=22\n", .{});
}

fn start(
    init: *const std.process.Init,
    executable: []const u8,
    path: []const u8,
    fault: []const u8,
) !std.process.Child {
    assert(executable.len > 0);
    assert(path.len > 0);
    var environment = std.process.Environ.Map.init(init.gpa);
    defer environment.deinit();
    try environment.put("SQLHEVI_TEST_SCRATCH_FAULT", fault);
    return std.process.spawn(init.io, .{
        .argv = &.{ executable, "start", addresses, path, "1073741824" },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn sql(
    init: *const std.process.Init,
    executable: []const u8,
    query: []const u8,
    expected: []const u8,
) !void {
    assert(query.len > 0);
    assert(expected.len > 0);
    try command(init, &.{ executable, "sql", "0", addresses, query }, expected);
}

fn command(init: *const std.process.Init, args: []const []const u8, expected: []const u8) !void {
    assert(args.len > 1);
    assert(args.len <= 6);
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = args,
        .stdout_limit = .limited(16384),
        .stderr_limit = .limited(65536),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or
        !std.mem.eql(u8, expected, result.stdout))
    {
        std.debug.print("spill command failed {s}: {s}\n{s}\n", .{
            args[1], result.stdout, result.stderr,
        });
        return error.SpillNativeCommand;
    }
}
