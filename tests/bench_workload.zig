const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Metrics = struct {
    peak: u64 = 0,
    failures: u64 = 0,
    attempts: u64 = 0,
    spill_bytes: u64 = 0,
};
const Samples = struct {
    times: [256]u64 = undefined,
    count: u32 = 0,
    ok: u32 = 0,
    oom: u32 = 0,
    total: u64 = 0,
};

pub fn now() u64 {
    var time: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.MONOTONIC, &time)) == .SUCCESS);
    assert(time.sec >= 0);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

pub fn run(adapter: anytype, quick: bool) !void {
    assert(adapter.name.len > 0);
    try prepare(adapter);
    std.debug.print("COLUMNS,backend,case,n,ok,oom,total_ns,p50_ns,p95_ns," ++
        "sqlite_peak_bytes,allocation_failures,execution_attempts,temp_spill_bytes\n", .{});
    try ordinary(adapter, if (quick) 16 else 128);
    try pressure(adapter, if (quick) 2 else 3);
    try measure(adapter, &.{
        .name = "post_pressure_read",
        .sql = "SELECT length(payload) FROM bench WHERE id=2048;",
        .expected = "256\n",
        .count = if (quick) 16 else 128,
    });
    try measure(adapter, &.{
        .name = "post_pressure_write",
        .sql = "UPDATE bench SET v=v+1 WHERE id=2048;",
        .expected = "",
        .count = if (quick) 8 else 64,
    });
    try expect(adapter, "SELECT count(*),sum(length(payload)) FROM bench;", "4096\t1048576\n");
    try expect(adapter, "UPDATE guard SET v=12345; SELECT v FROM guard;", "12345\n");
    var usage: linux.rusage = undefined;
    assert(linux.errno(linux.getrusage(0, &usage)) == .SUCCESS);
    std.debug.print("BENCH PASS {s} maxrss_kib={d}\n", .{ adapter.name, usage.maxrss });
}

fn prepare(adapter: anytype) !void {
    assert(adapter.name.len > 0);
    try expect(adapter, "CREATE TABLE bench(id INTEGER PRIMARY KEY,v INTEGER,payload BLOB);" ++
        "CREATE TABLE guard(v INTEGER); INSERT INTO guard VALUES(0);", "");
    var sql_buffer: [512]u8 = undefined;
    for (0..16) |batch| {
        const sql = try std.fmt.bufPrint(
            &sql_buffer,
            "WITH RECURSIVE ids(x) AS (VALUES({d}) UNION ALL SELECT x+1 FROM ids WHERE x<{d}) " ++
                "INSERT INTO bench SELECT x,0,zeroblob(256) FROM ids;",
            .{ batch * 256 + 1, (batch + 1) * 256 },
        );
        try expect(adapter, sql, "");
    }
    try expect(adapter, "SELECT count(*) FROM bench;", "4096\n");
    assert(sql_buffer.len > 256);
}

fn ordinary(adapter: anytype, repetitions: u32) !void {
    assert(repetitions <= 128);
    assert(repetitions >= 16);
    const read = "SELECT length(payload) FROM bench WHERE id=2048;";
    try measure(adapter, &.{
        .name = "point_read",
        .sql = read,
        .expected = "256\n",
        .count = repetitions,
    });
    try measure(adapter, &.{
        .name = "point_write",
        .sql = "UPDATE bench SET v=v+1 WHERE id=2048;",
        .expected = "",
        .count = repetitions / 2,
    });
    try measure(adapter, &.{
        .name = "batch_write_256",
        .sql = "UPDATE bench SET v=v+1 WHERE id<=256;",
        .expected = "",
        .count = repetitions / 8,
    });
    try measure(adapter, &.{
        .name = "scan_4096",
        .sql = "SELECT sum(length(payload)) FROM bench;",
        .expected = "1048576\n",
        .count = repetitions / 8,
    });
    const joins = "SELECT sum(length(h.payload)) FROM bench a " ++
        "JOIN bench b ON b.id=a.id JOIN bench c ON c.id=b.id " ++
        "JOIN bench d ON d.id=c.id JOIN bench e ON e.id=d.id " ++
        "JOIN bench f ON f.id=e.id JOIN bench g ON g.id=f.id " ++
        "JOIN bench h ON h.id=g.id;";
    try measure(adapter, &.{
        .name = "eight_way_join",
        .sql = joins,
        .expected = "1048576\n",
        .count = repetitions / 8,
    });
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{d}\n", .{
        repetitions / 2 + repetitions / 8 * 256,
    });
    try expect(adapter, "SELECT sum(v) FROM bench;", expected);
}

const Case = struct { name: []const u8, sql: []const u8, expected: []const u8, count: u32 };

fn measure(adapter: anytype, case: *const Case) !void {
    assert(case.count > 0);
    assert(case.count <= 256);
    adapter.reset_metrics();
    var samples: Samples = .{};
    for (0..case.count) |_| {
        const start = now();
        try expect(adapter, case.sql, case.expected);
        record(&samples, now() - start, false);
    }
    report(adapter, case.name, &samples);
}

fn pressure(adapter: anytype, repetitions: u32) !void {
    assert(repetitions >= 2);
    assert(repetitions <= 3);
    var sql_buffer: [1024]u8 = undefined;
    var name_buffer: [64]u8 = undefined;
    var expected_buffer: [64]u8 = undefined;
    var guard: u32 = 0;
    for ([_]u32{ 32, 64, 128, 160, 192, 256, 512, 768, 1024 }) |width| {
        const sql = try std.fmt.bufPrint(
            &sql_buffer,
            "UPDATE guard SET v=v+1; WITH j AS MATERIALIZED " ++
                "(SELECT a.id AS aid,b.id AS bid,zeroblob(1024) AS payload " ++
                "FROM bench a CROSS JOIN bench b WHERE a.id<=128 AND b.id<={d}) " ++
                "SELECT sum(length(payload)) FROM j;",
            .{width},
        );
        const expected = try std.fmt.bufPrint(&expected_buffer, "{d}\n", .{width * 128 * 1024});
        const name = try std.fmt.bufPrint(&name_buffer, "materialized_join_{d}MiB", .{width / 8});
        adapter.reset_metrics();
        var samples: Samples = .{};
        for (0..repetitions) |_| {
            const start = now();
            const failed = memory_result(adapter, sql, expected) catch |err| return err;
            record(&samples, now() - start, failed);
            if (!failed) guard += 1;
            var guard_buffer: [32]u8 = undefined;
            const guard_expected = try std.fmt.bufPrint(&guard_buffer, "{d}\n", .{guard});
            try expect(adapter, "SELECT v FROM guard;", guard_expected);
            try expect(adapter, "SELECT length(payload) FROM bench WHERE id=2048;", "256\n");
        }
        report(adapter, name, &samples);
    }
}

fn memory_result(adapter: anytype, sql: []const u8, expected: []const u8) !bool {
    assert(sql.len > 0);
    assert(expected.len > 0);
    expect(adapter, sql, expected) catch |err| {
        if (err == error.SQLiteMemory) return true;
        return err;
    };
    return false;
}

pub fn expect(adapter: anytype, sql: []const u8, expected: []const u8) !void {
    assert(sql.len > 0);
    assert(sql.len < 65536);
    const actual = try adapter.query(sql);
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("MISMATCH sql={s} expected={s} actual={s}\n", .{ sql, expected, actual });
        return error.ResultMismatch;
    }
}

fn record(samples: *Samples, elapsed: u64, oom: bool) void {
    assert(samples.count < samples.times.len);
    assert(elapsed > 0);
    samples.times[samples.count] = elapsed;
    samples.count += 1;
    samples.total += elapsed;
    if (oom) samples.oom += 1 else samples.ok += 1;
}

fn report(adapter: anytype, name: []const u8, samples: *Samples) void {
    assert(samples.count > 0);
    assert(samples.count == samples.ok + samples.oom);
    std.mem.sort(u64, samples.times[0..samples.count], {}, std.sort.asc(u64));
    const metrics = adapter.metrics();
    std.debug.print("RESULT,{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        adapter.name,
        name,
        samples.count,
        samples.ok,
        samples.oom,
        samples.total,
        samples.times[(samples.count - 1) / 2],
        samples.times[(samples.count * 95 - 1) / 100],
        metrics.peak,
        metrics.failures,
        metrics.attempts,
        metrics.spill_bytes,
    });
}
