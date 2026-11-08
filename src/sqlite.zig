const std = @import("std");
const assert = std.debug.assert;
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
pub const limits = @import("limits.zig");
pub const pager = @import("pager.zig");
pub const scratch = @import("scratch.zig");
const scratch_vfs = @import("scratch_vfs.zig");

test {
    _ = @import("capacity_test.zig");
    _ = @import("capacity.zig");
    _ = @import("scratch_test.zig");
}

// SQLite allocates within this startup-reserved heap; it can never request OS memory.
var heap: [limits.sqlite_heap_size]u8 align(16) = undefined;
var initialized = false;
var operation_seed: u64 = 0;
var operation_time_ms: i64 = 0;
var vfs: c.sqlite3_vfs = std.mem.zeroes(c.sqlite3_vfs);

pub const Engine = struct {
    memory: []u8,
    progress_calls: u32 = 0,
    output_size: u32 = 0,
    scratch_store: ?*scratch.Store = null,
    pub const ExecuteOptions = struct { op: u64, timestamp: u64 };

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) !void {
        try initialize();
        assert(initialized);
        const memory = try allocator.alloc(u8, limits.database_size_max);
        assert(memory.len == limits.database_size_max);
        engine.* = .{ .memory = memory };
    }

    pub fn deinit(engine: *Engine, allocator: std.mem.Allocator) void {
        assert(initialized);
        assert(engine.memory.len == limits.database_size_max);
        allocator.free(engine.memory);
        engine.* = undefined;
    }

    pub fn execute_paged(
        engine: *Engine,
        pages: *pager.Pager,
        sql: []const u8,
        options: ExecuteOptions,
        output: []u8,
    ) !void {
        assert(scratch_vfs.active == null);
        assert(pager.active == null);
        if (engine.scratch_store) |store| store.reset();
        scratch_vfs.active = engine.scratch_store;
        defer scratch_vfs.active = null;
        const result = engine.execute_paged_inner(pages, sql, options, output);
        if (engine.scratch_failed()) {
            engine.output_size = 0;
            pages.retry();
            return error.ScratchIO;
        }
        return result;
    }

    fn execute_paged_inner(
        engine: *Engine,
        pages: *pager.Pager,
        sql: []const u8,
        options: ExecuteOptions,
        output: []u8,
    ) !void {
        assert(pager.active == null);
        assert(options.op > 0);
        engine.output_size = 0;
        if (sql.len == 0 or sql.len > limits.sql_size_max) return error.SQLSize;
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.SQLContainsNul;
        if (@hasDecl(@import("root"), "sqlite_attempt_hook")) {
            @import("root").sqlite_attempt_hook(sql);
        }
        pages.retry();
        operation_seed = options.op;
        operation_time_ms = @intCast(options.timestamp / std.time.ns_per_ms);
        c.sqlite3_randomness(0, null);
        pager.active = pages;
        defer pager.active = null;
        var database: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const opened = c.sqlite3_open_v2("SQLhevi.db", &database, flags, "SQLhevi");
        defer if (database != null) assert(c.sqlite3_close(database) == c.SQLITE_OK);
        try check(opened);
        try configure(database);
        engine.progress_calls = 0;
        c.sqlite3_progress_handler(database, 1000, progress, engine);
        try check(c.sqlite3_exec(database, "BEGIN", null, null, null));
        try check(c.sqlite3_set_authorizer(database, authorize, null));
        var writer: std.Io.Writer = .fixed(output);
        try execute_statements(database, sql, &writer);
        try check(c.sqlite3_set_authorizer(database, null, null));
        try check(c.sqlite3_exec(database, "COMMIT", null, null, null));
        engine.output_size = @intCast(writer.end);
        assert(engine.output_size <= output.len);
    }

    // The input image is immutable until every statement, result, and size check succeeds.
    // Closing the private connection discards all partial effects on an error.
    pub fn execute(
        engine: *Engine,
        image: []const u8,
        sql: []const u8,
        options: ExecuteOptions,
        output: []u8,
    ) ![]const u8 {
        assert(scratch_vfs.active == null);
        assert(pager.active == null);
        if (engine.scratch_store) |store| store.reset();
        scratch_vfs.active = engine.scratch_store;
        defer scratch_vfs.active = null;
        const result = engine.execute_inner(image, sql, options, output);
        if (engine.scratch_failed()) {
            engine.output_size = 0;
            return error.ScratchIO;
        }
        return result;
    }

    fn scratch_failed(engine: *const Engine) bool {
        assert(pager.active == null);
        assert(scratch_vfs.active == engine.scratch_store);
        const store = engine.scratch_store orelse return false;
        // SQLite can ignore an error from xClose. Check the sticky local fault after close,
        // even when sqlite3_step and COMMIT reported success.
        return store.failure != null;
    }

    fn execute_inner(
        engine: *Engine,
        image: []const u8,
        sql: []const u8,
        options: ExecuteOptions,
        output: []u8,
    ) ![]const u8 {
        assert(image.len <= engine.memory.len);
        assert(options.op > 0);
        assert(initialized);
        assert(engine.memory.len == limits.database_size_max);
        assert(output.len > 0);
        engine.output_size = 0;
        if (sql.len == 0 or sql.len > limits.sql_size_max) return error.SQLSize;
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.SQLContainsNul;
        operation_seed = options.op;
        operation_time_ms = @intCast(options.timestamp / std.time.ns_per_ms);
        c.sqlite3_randomness(0, null); // Reset SQLite's global PRNG for each replicated operation.
        @memset(engine.memory, 0);
        @memcpy(engine.memory[0..image.len], image);
        var database: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_MEMORY;
        const opened = c.sqlite3_open_v2(":memory:", &database, flags, "SQLhevi");
        defer if (database != null) assert(c.sqlite3_close(database) == c.SQLITE_OK);
        try check(opened);
        try check(c.sqlite3_deserialize(
            database,
            "main",
            engine.memory.ptr,
            @intCast(image.len),
            @intCast(engine.memory.len),
            0,
        ));
        try configure(database);
        engine.progress_calls = 0;
        c.sqlite3_progress_handler(database, 1000, progress, engine);
        try check(c.sqlite3_exec(database, "BEGIN", null, null, null));
        try check(c.sqlite3_set_authorizer(database, authorize, null));
        var writer: std.Io.Writer = .fixed(output);
        try execute_statements(database, sql, &writer);
        try check(c.sqlite3_set_authorizer(database, null, null));
        try check(c.sqlite3_exec(database, "COMMIT", null, null, null));
        var size: i64 = 0;
        const bytes = c.sqlite3_serialize(database, "main", &size, c.SQLITE_SERIALIZE_NOCOPY);
        if (size < 0 or size > engine.memory.len) return error.DatabaseFull;
        if (size > 0 and bytes == null) return error.Serialize;
        assert(size == 0 or bytes == engine.memory.ptr);
        const result = engine.memory[0..@intCast(size)];
        assert(result.len % limits.page_size == 0);
        if (chunks_changed(image, result) > limits.chunks_changed_max) {
            return error.TransactionTooLarge;
        }
        engine.output_size = @intCast(writer.end);
        assert(engine.output_size <= output.len);
        return result;
    }
};

pub fn initialize() !void {
    if (initialized) return;
    assert(!initialized);
    assert(heap.len > 2 * limits.database_size_max);
    assert(@intFromPtr(&heap) % 16 == 0);
    try @import("sqlite_memory.zig").configure(&heap);
    try check(c.sqlite3_initialize());
    _ = c.sqlite3_hard_heap_limit64(limits.sqlite_heap_limit);
    assert(c.sqlite3_hard_heap_limit64(-1) == heap.len);
    initialized = true;
    assert(c.sqlite3_threadsafe() == 0);
}

fn configure(database: ?*c.sqlite3) !void {
    assert(database != null);
    _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_LENGTH, limits.database_size_max);
    _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_SQL_LENGTH, limits.sql_size_max);
    _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_COLUMN, limits.columns_max);
    _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_ATTACHED, 0);
    _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_TRIGGER_DEPTH, 16);
    // Reference tests may explicitly omit scratch; every native replica attaches it at startup.
    const temp = if (scratch_vfs.active != null)
        "PRAGMA temp_store=FILE"
    else
        "PRAGMA temp_store=MEMORY";
    try check(c.sqlite3_exec(database, temp, null, null, null));
    const sql = "PRAGMA page_size=65536; PRAGMA foreign_keys=ON;" ++
        "PRAGMA max_page_count=4294967294;" ++
        "PRAGMA journal_mode=MEMORY; PRAGMA trusted_schema=OFF;" ++
        "PRAGMA reverse_unordered_selects=OFF;";
    try check(c.sqlite3_exec(database, sql, null, null, null));
    assert(c.sqlite3_get_autocommit(database) == 1);
}

fn execute_statements(database: ?*c.sqlite3, sql: []const u8, writer: *std.Io.Writer) !void {
    assert(database != null);
    assert(sql.len <= limits.sql_size_max);
    var remaining = sql;
    for (0..limits.statements_max) |_| {
        if (remaining.len == 0) return;
        var statement: ?*c.sqlite3_stmt = null;
        var completed = false;
        var tail: [*c]const u8 = null;
        try check(c.sqlite3_prepare_v3(
            database,
            remaining.ptr,
            @intCast(remaining.len),
            0,
            &statement,
            &tail,
        ));
        defer if (statement != null) {
            const finalized = c.sqlite3_finalize(statement);
            // After a failed step finalize repeats that error, which has already been handled.
            if (completed) assert(finalized == c.SQLITE_OK);
        };
        const consumed = @intFromPtr(tail) - @intFromPtr(remaining.ptr);
        assert(consumed > 0);
        assert(consumed <= remaining.len);
        remaining = remaining[consumed..];
        if (statement) |ready| try execute_rows(ready, writer);
        completed = true;
    }
    if (remaining.len != 0) return error.StatementsLimit;
}

fn execute_rows(statement: *c.sqlite3_stmt, writer: *std.Io.Writer) !void {
    const columns = c.sqlite3_column_count(statement);
    assert(columns >= 0);
    assert(columns <= limits.columns_max);
    for (0..limits.rows_max + 1) |row| {
        const status = c.sqlite3_step(statement);
        if (status == c.SQLITE_DONE) return;
        if (status != c.SQLITE_ROW) return check(status);
        if (row == limits.rows_max) return error.RowsLimit;
        for (0..@intCast(columns)) |column| {
            if (column > 0) try writer.writeByte('\t');
            try write_column(statement, @intCast(column), writer);
        }
        try writer.writeByte('\n');
    }
    unreachable;
}

fn write_column(statement: *c.sqlite3_stmt, column: c_int, writer: *std.Io.Writer) !void {
    assert(column >= 0);
    assert(column < c.sqlite3_column_count(statement));
    switch (c.sqlite3_column_type(statement, column)) {
        c.SQLITE_NULL => try writer.writeAll("null"),
        c.SQLITE_INTEGER => try writer.print("{d}", .{c.sqlite3_column_int64(statement, column)}),
        c.SQLITE_FLOAT => try writer.print("{d}", .{c.sqlite3_column_double(statement, column)}),
        c.SQLITE_TEXT, c.SQLITE_BLOB => {
            const pointer = c.sqlite3_column_blob(statement, column);
            const size: u32 = @intCast(c.sqlite3_column_bytes(statement, column));
            // Hex prevents embedded tabs/newlines from changing the result's structure.
            const is_text = c.sqlite3_column_type(statement, column) == c.SQLITE_TEXT;
            try writer.writeAll(if (is_text) "t:" else "b:");
            if (size > 0) {
                const data: [*]const u8 = @ptrCast(pointer);
                try writer.print("{x}", .{data[0..size]});
            }
        },
        else => unreachable,
    }
}

fn progress(context: ?*anyopaque) callconv(.c) c_int {
    assert(context != null);
    const engine: *Engine = @ptrCast(@alignCast(context.?));
    assert(engine.progress_calls <= limits.progress_calls_max);
    engine.progress_calls += 1;
    return @intFromBool(engine.progress_calls >= limits.progress_calls_max);
}

fn authorize(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    _ = first;
    assert(action >= c.SQLITE_CREATE_INDEX);
    assert(action <= c.SQLITE_RECURSIVE);
    if (database != null and !std.mem.eql(u8, std.mem.span(database), "main")) return c.SQLITE_DENY;
    switch (action) {
        c.SQLITE_ATTACH,
        c.SQLITE_DETACH,
        c.SQLITE_PRAGMA,
        c.SQLITE_TRANSACTION,
        c.SQLITE_SAVEPOINT,
        c.SQLITE_CREATE_VTABLE,
        c.SQLITE_DROP_VTABLE,
        c.SQLITE_CREATE_TEMP_TABLE,
        c.SQLITE_CREATE_TEMP_INDEX,
        c.SQLITE_CREATE_TEMP_TRIGGER,
        c.SQLITE_CREATE_TEMP_VIEW,
        => return c.SQLITE_DENY,
        c.SQLITE_FUNCTION => {
            if (second == null) return c.SQLITE_DENY;
            const function = std.mem.span(second);
            // These depend on connection history or host/build metadata, which is not replicated.
            const denied_functions = [_][]const u8{
                "changes",
                "total_changes",
                "last_insert_rowid",
                "sqlite_version",
                "sqlite_source_id",
                "sqlite_compileoption_get",
                "sqlite_compileoption_used",
                "load_extension",
            };
            for (denied_functions) |denied| {
                if (std.ascii.eqlIgnoreCase(function, denied)) return c.SQLITE_DENY;
            }
        },
        else => {},
    }
    return c.SQLITE_OK;
}

pub fn chunks_changed(before: []const u8, after: []const u8) u32 {
    assert(before.len <= limits.database_size_max);
    assert(after.len <= limits.database_size_max);
    var changed: u32 = 0;
    for (0..limits.chunk_count_max) |index| {
        const offset = index * limits.chunk_size;
        if (offset >= @max(before.len, after.len)) break;
        const left = before[@min(offset, before.len)..@min(offset + limits.chunk_size, before.len)];
        const right = after[@min(offset, after.len)..@min(offset + limits.chunk_size, after.len)];
        if (!std.mem.eql(u8, left, right) or (index == 0 and before.len != after.len)) changed += 1;
    }
    assert(changed <= limits.chunk_count_max);
    return changed;
}

fn check(status: c_int) !void {
    assert(status >= 0);
    assert(status & 0xff <= c.SQLITE_WARNING);
    if (status == c.SQLITE_OK) return;
    return switch (status & 0xff) {
        c.SQLITE_FULL => error.DatabaseFull,
        c.SQLITE_NOMEM => error.SQLiteMemory,
        c.SQLITE_AUTH => error.SQLForbidden,
        c.SQLITE_INTERRUPT => error.SQLWorkLimit,
        c.SQLITE_CONSTRAINT => error.SQLConstraint,
        else => error.SQLite,
    };
}

// SQLITE_OS_OTHER restricts all database I/O to our main-page and anonymous-scratch adapters.
pub export fn sqlite3_os_init() c_int {
    assert(!initialized);
    assert(vfs.zName == null);
    vfs = std.mem.zeroes(c.sqlite3_vfs);
    vfs.iVersion = 2;
    vfs.szOsFile = @max(@sizeOf(pager.File), @sizeOf(scratch_vfs.File));
    vfs.mxPathname = 128;
    vfs.zName = "SQLhevi";
    vfs.xOpen = vfs_open;
    vfs.xDelete = vfs_delete;
    vfs.xAccess = vfs_access;
    vfs.xFullPathname = vfs_path;
    vfs.xRandomness = vfs_random;
    vfs.xSleep = vfs_sleep;
    vfs.xCurrentTimeInt64 = vfs_time;
    return c.sqlite3_vfs_register(&vfs, 1);
}

pub export fn sqlite3_os_end() c_int {
    assert(vfs.zName != null);
    assert(vfs.iVersion == 2);
    return c.SQLITE_OK;
}

fn vfs_open(
    _: [*c]c.sqlite3_vfs,
    path: [*c]const u8,
    file: [*c]c.sqlite3_file,
    flags: c_int,
    output: [*c]c_int,
) callconv(.c) c_int {
    assert(file != null);
    file.*.pMethods = null;
    assert(file.*.pMethods == null);
    if (flags & c.SQLITE_OPEN_MAIN_DB != 0) return pager.open(file, flags, output);
    if (path != null) return c.SQLITE_CANTOPEN;
    return scratch_vfs.open(file, flags, output);
}

fn vfs_delete(owner: [*c]c.sqlite3_vfs, path: [*c]const u8, _: c_int) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(path != null);
    return c.SQLITE_IOERR_DELETE;
}

fn vfs_access(
    owner: [*c]c.sqlite3_vfs,
    _: [*c]const u8,
    _: c_int,
    result: [*c]c_int,
) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(result != null);
    result.* = 0;
    return c.SQLITE_OK;
}

fn vfs_path(
    owner: [*c]c.sqlite3_vfs,
    path: [*c]const u8,
    size: c_int,
    output: [*c]u8,
) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(size > 0);
    assert(output != null);
    if (path == null or !std.mem.eql(u8, std.mem.span(path), "SQLhevi.db")) {
        return c.SQLITE_CANTOPEN;
    }
    if (size < 11) return c.SQLITE_CANTOPEN;
    @memcpy(output[0..11], "SQLhevi.db\x00");
    return c.SQLITE_OK;
}

fn vfs_random(_: [*c]c.sqlite3_vfs, size: c_int, output: [*c]u8) callconv(.c) c_int {
    assert(size >= 0);
    assert(size <= 256);
    assert(output != null);
    var random = std.Random.DefaultPrng.init(operation_seed);
    random.random().bytes(output[0..@intCast(size)]);
    return size;
}

fn vfs_sleep(owner: [*c]c.sqlite3_vfs, microseconds: c_int) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(microseconds >= 0);
    return 0;
}

fn vfs_time(owner: [*c]c.sqlite3_vfs, result: [*c]c.sqlite3_int64) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(result != null);
    assert(operation_time_ms >= 0);
    result.* = operation_time_ms + 210866760000000;
    return c.SQLITE_OK;
}

const PagedFixture = struct {
    engine: Engine,
    pages: pager.Pager,
    image: []u8,
    size: u64 = 0,
    output: [4096]u8 = undefined,

    fn init(self: *PagedFixture) !void {
        self.* = .{ .engine = undefined, .pages = undefined, .image = undefined };
        try self.engine.init(std.testing.allocator);
        errdefer self.engine.deinit(std.testing.allocator);
        try self.pages.init(std.testing.allocator);
        errdefer self.pages.deinit(std.testing.allocator);
        self.pages.read_limit = 4096;
        self.pages.write_limit = 1024;
        const image = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
        @memset(image, 0);
        assert(image.len > limits.database_size_max);
        assert(self.pages.count == 0);
        self.image = image;
    }

    fn deinit(self: *PagedFixture) void {
        assert(self.size <= self.image.len);
        assert(pager.active == null);
        self.engine.deinit(std.testing.allocator);
        self.pages.deinit(std.testing.allocator);
        std.testing.allocator.free(self.image);
    }

    fn execute(self: *PagedFixture, sql: []const u8, op: u64) ![]const u8 {
        assert(op > 0);
        assert(self.size <= self.image.len);
        self.pages.reset();
        try self.pages.supply(&.{
            .timestamp = 1,
            .image_size = self.size,
            .bytes = @splat(0),
        }, true);
        for (0..limits.read_chunks_max) |_| {
            self.engine.execute_paged(&self.pages, sql, .{
                .op = op,
                .timestamp = 1234567890000000000,
            }, &self.output) catch |err| {
                if (self.pages.failure) |failure| return failure;
                const key = self.pages.missing orelse return err;
                try self.fetch(key);
                continue;
            };
            try self.pages.finish();
            assert(self.pages.size <= self.image.len);
            for (self.pages.writes[0..self.pages.write_count]) |*chunk| {
                if (chunk.timestamp == 1) continue;
                const offset = (chunk.timestamp - 2) * limits.chunk_size;
                const count = @min(limits.chunk_size, self.pages.size -| offset);
                @memcpy(self.image[offset..][0..count], chunk.bytes[0..count]);
            }
            self.size = self.pages.size;
            return self.output[0..self.engine.output_size];
        }
        return error.ReadSetLimit;
    }

    fn fetch(self: *PagedFixture, key: u64) !void {
        assert(key >= 2);
        assert(self.size <= self.image.len);
        for (key..key + limits.page_size / limits.chunk_size + 2) |next| {
            if (self.pages.get(next) != null) continue;
            var chunk: pager.Chunk = .{
                .timestamp = next,
                .image_size = 0,
                .bytes = @splat(0),
            };
            const offset = (next - 2) * limits.chunk_size;
            const count = @min(limits.chunk_size, self.size -| offset);
            if (count > 0) @memcpy(chunk.bytes[0..count], self.image[offset..][0..count]);
            try self.pages.supply(&chunk, count > 0);
        }
    }
};

test "paged SQLite grows, isolates failures, and replays deterministically" {
    var left: PagedFixture = undefined;
    try left.init();
    defer left.deinit();
    var right: PagedFixture = undefined;
    try right.init();
    defer right.deinit();
    const create = "CREATE TABLE big(id INTEGER PRIMARY KEY, payload BLOB);" ++
        "CREATE TABLE randoms(value, time);";
    _ = try left.execute(create, 1);
    _ = try right.execute(create, 1);
    var sql_buffer: [128]u8 = undefined;
    for (0..600) |index| {
        const sql = try std.fmt.bufPrint(
            &sql_buffer,
            "INSERT INTO big VALUES({d}, zeroblob(4000));",
            .{index},
        );
        _ = try left.execute(sql, index + 2);
        _ = try right.execute(sql, index + 2);
    }
    try std.testing.expect(left.size > left.pages.read_limit * limits.chunk_size);
    try std.testing.expectEqualSlices(u8, left.image[0..left.size], right.image[0..right.size]);
    const random_sql = "INSERT INTO randoms VALUES(randomblob(32), datetime('now'));";
    _ = try left.execute(random_sql, 602);
    _ = try right.execute(random_sql, 602);
    try std.testing.expectEqualSlices(u8, left.image[0..left.size], right.image[0..right.size]);
    try std.testing.expectError(error.SQLConstraint, left.execute(
        "UPDATE big SET payload=x'01' WHERE id=0; INSERT INTO big VALUES(0, null)",
        603,
    ));
    try std.testing.expectEqualSlices(u8, left.image[0..left.size], right.image[0..right.size]);
    try std.testing.expectError(error.TransactionTooLarge, left.execute(
        "INSERT INTO big VALUES(999, zeroblob(700000))",
        604,
    ));
    try std.testing.expectEqualSlices(u8, left.image[0..left.size], right.image[0..right.size]);
    try std.testing.expectError(error.ReadSetLimit, left.execute(
        "UPDATE big SET payload=x'02' WHERE id=0; SELECT sum(length(payload)) FROM big;",
        605,
    ));
    try std.testing.expectEqualSlices(u8, left.image[0..left.size], right.image[0..right.size]);
    const result = try left.execute("SELECT id, length(payload) FROM big WHERE id=599", 606);
    try std.testing.expectEqualStrings("599\t4000\n", result);
    try std.testing.expect(left.pages.count < 700);
}

test "SQLite requests are atomic, deterministic, and isolated from the host" {
    var engine: Engine = undefined;
    try engine.init(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var output: [4096]u8 = undefined;
    const options: Engine.ExecuteOptions = .{ .op = 1, .timestamp = 1000000000 };
    const create = "CREATE TABLE t (id INTEGER PRIMARY KEY, v);" ++
        "INSERT INTO t VALUES (1, 'hello'); SELECT id FROM t;";
    const image = try engine.execute(&.{}, create, options, &output);
    try std.testing.expect(image.len >= 8192);
    try std.testing.expectEqualStrings("1\n", output[0..2]);
    const saved = try std.testing.allocator.dupe(u8, image);
    defer std.testing.allocator.free(saved);
    const duplicate = "INSERT INTO t VALUES(2, 'discard'); INSERT INTO t VALUES(1, 'duplicate');";
    try std.testing.expectError(
        error.SQLConstraint,
        engine.execute(saved, duplicate, options, &output),
    );
    _ = try engine.execute(saved, "SELECT count(*) FROM t", options, &output);
    try std.testing.expectEqualStrings("1\n", output[0..2]);
    for ([_][]const u8{ "ATTACH 'x' AS x", "PRAGMA journal_mode=WAL", "COMMIT" }) |sql| {
        try std.testing.expectError(
            error.SQLForbidden,
            engine.execute(saved, sql, options, &output),
        );
    }
    // SQLite reports denied function calls as SQLITE_ERROR, rather than SQLITE_AUTH.
    try std.testing.expectError(
        error.SQLite,
        engine.execute(saved, "SELECT changes()", options, &output),
    );
    const random = "SELECT random(), hex(randomblob(8)), datetime('now')";
    _ = try engine.execute(saved, random, options, &output);
    const first = output;
    _ = try engine.execute(saved, random, options, &output);
    try std.testing.expectEqualSlices(u8, first[0..64], output[0..64]);
}

test "SQLite output overflow and reference image limits discard all writes" {
    var engine: Engine = undefined;
    try engine.init(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var output: [4096]u8 = undefined;
    const options: Engine.ExecuteOptions = .{ .op = 2, .timestamp = 2000000000 };
    const image = try engine.execute(&.{}, "CREATE TABLE t(v BLOB)", options, &output);
    const saved = try std.testing.allocator.dupe(u8, image);
    defer std.testing.allocator.free(saved);
    var small: [1]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, engine.execute(
        saved,
        "INSERT INTO t VALUES('discard') RETURNING v",
        options,
        &small,
    ));
    try std.testing.expectError(error.DatabaseFull, engine.execute(
        saved,
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20) " ++
            "INSERT INTO t SELECT zeroblob(100000) FROM n",
        options,
        &output,
    ));
    _ = try engine.execute(saved, "SELECT count(*) FROM t", options, &output);
    try std.testing.expectEqualStrings("0\n", output[0..engine.output_size]);
}

test "SQLite deterministic time, random rowids, and PRNG survive connection recreation" {
    var engine: Engine = undefined;
    try engine.init(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var output: [4096]u8 = undefined;
    const options: Engine.ExecuteOptions = .{ .op = 99, .timestamp = 1000000000 };
    const sql = "CREATE TABLE t(id INTEGER PRIMARY KEY, v);" ++
        "INSERT INTO t VALUES(9223372036854775807, 'highest');" ++
        "INSERT INTO t(v) VALUES(random()); SELECT id,v FROM t ORDER BY id;" ++
        "SELECT datetime('now');";
    const first = try engine.execute(&.{}, sql, options, &output);
    const first_image = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(first_image);
    const first_reply = output;
    const size = engine.output_size;
    // Intervening operations must not affect replay's random rowid allocation.
    _ = try engine.execute(
        &.{},
        "SELECT randomblob(100)",
        .{ .op = 200, .timestamp = 2000000000 },
        &output,
    );
    const second = try engine.execute(&.{}, sql, options, &output);
    try std.testing.expectEqualSlices(u8, first_image, second);
    try std.testing.expectEqualStrings(first_reply[0..size], output[0..engine.output_size]);
}

test "SQLite schemas, foreign keys, triggers, and typed empty results" {
    var engine: Engine = undefined;
    try engine.init(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var output: [4096]u8 = undefined;
    const options: Engine.ExecuteOptions = .{ .op = 3, .timestamp = 3000000000 };
    const sql = "CREATE TABLE p(id INTEGER PRIMARY KEY);" ++
        "CREATE TABLE c(id INTEGER REFERENCES p(id));" ++
        "CREATE TRIGGER copy AFTER INSERT ON p BEGIN INSERT INTO c VALUES(new.id); END;" ++
        "CREATE VIEW joined AS SELECT p.id FROM p JOIN c ON p.id=c.id;" ++
        "INSERT INTO p VALUES(7); SELECT * FROM joined; SELECT '', x'', NULL, 1.5;";
    const image = try engine.execute(&.{}, sql, options, &output);
    try std.testing.expectEqualStrings("7\nt:\tb:\tnull\t1.5\n", output[0..engine.output_size]);
    const saved = try std.testing.allocator.dupe(u8, image);
    defer std.testing.allocator.free(saved);
    try std.testing.expectError(error.SQLConstraint, engine.execute(
        saved,
        "INSERT INTO c VALUES(9)",
        options,
        &output,
    ));
}

test "SQLite statement, row, VM work, and SQL input bounds" {
    var engine: Engine = undefined;
    try engine.init(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var output: [512 * 1024]u8 = undefined;
    const options: Engine.ExecuteOptions = .{ .op = 4, .timestamp = 4000000000 };
    try std.testing.expectError(
        error.SQLContainsNul,
        engine.execute(&.{}, "SELECT 1\x00;DROP TABLE t", options, &output),
    );
    try std.testing.expectError(
        error.StatementsLimit,
        engine.execute(&.{}, "SELECT 1;" ** (limits.statements_max + 1), options, &output),
    );
    const recursive = "WITH RECURSIVE n(x) AS " ++
        "(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000) ";
    try std.testing.expectError(
        error.SQLWorkLimit,
        engine.execute(&.{}, recursive ++ "SELECT sum(x) FROM n", options, &output),
    );
    try std.testing.expectError(
        error.RowsLimit,
        engine.execute(&.{}, recursive ++ "SELECT x FROM n LIMIT 65537", options, &output),
    );
}
