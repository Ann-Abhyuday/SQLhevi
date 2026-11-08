const std = @import("std");
const assert = std.debug.assert;
const workload = @import("bench_workload.zig");
const c = @import("bench_c.zig").c;
const spill = @import("bench_spill.zig");
var heap: [256 * 1024 * 1024]u8 align(16) = undefined;
var methods: c.sqlite3_mem_methods = undefined;
var allocation_failures: u64 = 0;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 and args.len != 6) return error.ExpectedAllocatorPathTempModeAndOptionalQuick;
    assert(args.len >= 5);
    const bytes: u32 = if (std.mem.eql(u8, args[1], "system"))
        0
    else
        try std.fmt.parseInt(u32, args[1], 10);
    if (bytes != 0 and bytes != 64 and bytes != 256) return error.PoolSize;
    try configure(bytes * 1024 * 1024);
    try spill.initialize();
    defer assert(c.sqlite3_shutdown() == c.SQLITE_OK);
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "sqlite_{s}_{s}_{s}", .{
        args[1], args[3], args[4],
    });
    var adapter: Adapter = .{ .name = name };
    // Keep file-backed temporary results on the same filesystem as the baseline database.
    var temp_path: [4096]u8 = undefined;
    if (!std.mem.eql(u8, args[2], ":memory:")) {
        const directory = std.fs.path.dirname(args[2]) orelse ".";
        c.sqlite3_temp_directory = (try std.fmt.bufPrintZ(&temp_path, "{s}", .{directory})).ptr;
    }
    try check(c.sqlite3_open(args[2].ptr, &adapter.database));
    defer assert(c.sqlite3_close(adapter.database) == c.SQLITE_OK);
    try adapter.exec("PRAGMA page_size=65536; PRAGMA cache_size=-2000;" ++
        "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;");
    if (std.mem.eql(u8, args[3], "memory")) {
        try adapter.exec("PRAGMA temp_store=MEMORY;");
    } else if (std.mem.eql(u8, args[3], "file")) {
        try adapter.exec("PRAGMA temp_store=FILE;");
    } else return error.TempMode;
    try adapter.exec(if (std.mem.eql(u8, args[2], ":memory:"))
        "PRAGMA journal_mode=MEMORY;"
    else
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=1000;");
    std.debug.print("SQLite {s}; source={s}; allocator={s}; path={s}; temp={s}\n", .{
        c.sqlite3_libversion(), c.sqlite3_sourceid(), args[1], args[2], args[3],
    });
    assert(adapter.database != null);
    try workload.run(&adapter, args.len == 6);
}

fn configure(bytes: u32) !void {
    assert(bytes <= heap.len);
    assert(@intFromPtr(&heap) % 16 == 0);
    if (bytes > 0) try check(c.sqlite3_config(
        c.SQLITE_CONFIG_HEAP,
        &heap,
        @as(c_int, @intCast(bytes)),
        @as(c_int, 64),
    ));
    try check(c.sqlite3_config(c.SQLITE_CONFIG_GETMALLOC, &methods));
    var audited = methods;
    audited.xMalloc = allocate;
    audited.xRealloc = resize;
    try check(c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &audited));
    try check(c.sqlite3_initialize());
}

fn allocate(bytes: c_int) callconv(.c) ?*anyopaque {
    assert(bytes > 0);
    assert(methods.xMalloc != null);
    const result = methods.xMalloc.?(bytes);
    if (result == null) allocation_failures += 1;
    return result;
}

fn resize(pointer: ?*anyopaque, bytes: c_int) callconv(.c) ?*anyopaque {
    assert(pointer != null);
    assert(bytes > 0);
    const result = methods.xRealloc.?(pointer, bytes);
    if (result == null) allocation_failures += 1;
    return result;
}

const Adapter = struct {
    name: []const u8,
    database: ?*c.sqlite3 = null,
    output: [4096]u8 = undefined,

    pub fn query(self: *Adapter, sql: []const u8) ![]const u8 {
        assert(self.database != null);
        assert(sql.len < 65536);
        try self.exec("BEGIN;");
        errdefer {
            if (c.sqlite3_get_autocommit(self.database) == 0) self.exec("ROLLBACK;") catch
                @panic("baseline rollback failed");
        }
        var writer: std.Io.Writer = .fixed(&self.output);
        var remaining = sql;
        for (0..1024) |_| {
            if (remaining.len == 0) break;
            var statement: ?*c.sqlite3_stmt = null;
            var tail: [*c]const u8 = null;
            try check(c.sqlite3_prepare_v3(
                self.database,
                remaining.ptr,
                @intCast(remaining.len),
                0,
                &statement,
                &tail,
            ));
            defer if (statement != null) {
                _ = c.sqlite3_finalize(statement);
            };
            const consumed = @intFromPtr(tail) - @intFromPtr(remaining.ptr);
            assert(consumed > 0);
            assert(consumed <= remaining.len);
            remaining = remaining[consumed..];
            if (statement) |ready| try rows(ready, &writer);
        } else return error.StatementsLimit;
        try self.exec("COMMIT;");
        return self.output[0..writer.end];
    }

    fn exec(self: *Adapter, sql: [:0]const u8) !void {
        assert(self.database != null);
        assert(sql.len > 0);
        try check(c.sqlite3_exec(self.database, sql, null, null, null));
    }

    pub fn reset_metrics(self: *Adapter) void {
        assert(self.database != null);
        assert(c.sqlite3_get_autocommit(self.database) == 1);
        var current: i64 = 0;
        var peak: i64 = 0;
        assert(c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &current, &peak, 1) == c.SQLITE_OK);
        allocation_failures = 0;
        spill.written = 0;
    }

    pub fn metrics(self: *Adapter) workload.Metrics {
        assert(self.database != null);
        var current: i64 = 0;
        var peak: i64 = 0;
        assert(c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &current, &peak, 0) == c.SQLITE_OK);
        assert(peak >= current);
        return .{
            .peak = @intCast(peak),
            .failures = allocation_failures,
            .spill_bytes = spill.written,
        };
    }
};

fn rows(statement: *c.sqlite3_stmt, writer: *std.Io.Writer) !void {
    const columns = c.sqlite3_column_count(statement);
    assert(columns <= 2000);
    assert(columns >= 0);
    for (0..65537) |_| {
        const status = c.sqlite3_step(statement);
        if (status == c.SQLITE_DONE) return;
        if (status != c.SQLITE_ROW) return check(status);
        for (0..@intCast(columns)) |index| {
            if (index > 0) try writer.writeByte('\t');
            assert(c.sqlite3_column_type(statement, @intCast(index)) == c.SQLITE_INTEGER);
            try writer.print("{d}", .{c.sqlite3_column_int64(statement, @intCast(index))});
        }
        try writer.writeByte('\n');
    }
    return error.RowsLimit;
}

fn check(status: c_int) !void {
    assert(status >= 0);
    assert(status & 0xff <= c.SQLITE_WARNING);
    if (status == c.SQLITE_OK) return;
    if (status & 0xff == c.SQLITE_NOMEM) return error.SQLiteMemory;
    std.debug.print("SQLite status={d} message={s}\n", .{ status, c.sqlite3_errstr(status) });
    return error.SQLite;
}
