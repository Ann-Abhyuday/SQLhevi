const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite.zig").c;
const scratch = @import("scratch.zig");
pub var active: ?*scratch.Store = null;
pub const File = extern struct { base: c.sqlite3_file, store: *scratch.Store, index: u32 };

pub fn open(file: [*c]c.sqlite3_file, flags: c_int, output: [*c]c_int) c_int {
    assert(file != null);
    assert(file.*.pMethods == null);
    const allowed = c.SQLITE_OPEN_TEMP_DB | c.SQLITE_OPEN_TRANSIENT_DB |
        c.SQLITE_OPEN_TEMP_JOURNAL | c.SQLITE_OPEN_SUBJOURNAL;
    if (active == null or flags & allowed == 0 or flags & c.SQLITE_OPEN_DELETEONCLOSE == 0) {
        return c.SQLITE_CANTOPEN;
    }
    const store = active.?;
    const index = store.open() catch |err| return status(err);
    const own: *File = @ptrCast(@alignCast(file));
    own.* = .{ .base = .{ .pMethods = &methods }, .store = store, .index = index };
    if (output != null) output.* = flags;
    return c.SQLITE_OK;
}

fn owner(file: [*c]c.sqlite3_file) *File {
    assert(file != null);
    assert(file.*.pMethods == &methods);
    const own: *File = @ptrCast(@alignCast(file));
    assert(own.store == active.?);
    return own;
}

fn status(err: anyerror) c_int {
    assert(active != null);
    assert(err == error.ScratchLimit or err == error.ScratchIO);
    return if (err == error.ScratchLimit) c.SQLITE_FULL else c.SQLITE_IOERR;
}

fn close(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    const own = owner(file);
    assert(own.index < scratch.files_max);
    assert(file.*.pMethods != null);
    file.*.pMethods = null;
    own.store.close(own.index) catch |err| return status(err);
    return c.SQLITE_OK;
}

fn read(file: [*c]c.sqlite3_file, data: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    assert(n > 0);
    assert(off >= 0);
    const own = owner(file);
    const bytes: [*]u8 = @ptrCast(data.?);
    const length = own.store.read(
        .{ .file = own.index, .offset = @intCast(off) },
        bytes[0..@intCast(n)],
    ) catch |err| return status(err);
    return if (length == n) c.SQLITE_OK else c.SQLITE_IOERR_SHORT_READ;
}

fn write(file: [*c]c.sqlite3_file, data: ?*const anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    assert(n > 0);
    assert(off >= 0);
    const own = owner(file);
    const bytes: [*]const u8 = @ptrCast(data.?);
    own.store.write(
        .{ .file = own.index, .offset = @intCast(off) },
        bytes[0..@intCast(n)],
    ) catch |err| return status(err);
    return c.SQLITE_OK;
}

fn truncate(file: [*c]c.sqlite3_file, length: i64) callconv(.c) c_int {
    assert(length >= 0);
    const own = owner(file);
    assert(own.index < scratch.files_max);
    own.store.resize(.{ .file = own.index, .offset = @intCast(length) }) catch |err| {
        return status(err);
    };
    return c.SQLITE_OK;
}

fn sync(file: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    const own = owner(file);
    assert(flags != 0);
    assert(own.index < scratch.files_max);
    // Scratch needs verified contents, not durable recovery. The replicated main database
    // still gets its durability exclusively from VSR's journal and checkpoint barriers.
    own.store.flush() catch |err| return status(err);
    return c.SQLITE_OK;
}

fn size(file: [*c]c.sqlite3_file, result: [*c]i64) callconv(.c) c_int {
    const own = owner(file);
    assert(result != null);
    assert(own.index < scratch.files_max);
    result.* = @intCast(own.store.size(own.index));
    return c.SQLITE_OK;
}

fn lock(file: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    _ = owner(file);
    assert(level >= c.SQLITE_LOCK_NONE);
    assert(level <= c.SQLITE_LOCK_EXCLUSIVE);
    return c.SQLITE_OK;
}

fn reserved(file: [*c]c.sqlite3_file, result: [*c]c_int) callconv(.c) c_int {
    _ = owner(file);
    assert(result != null);
    result.* = 0;
    return c.SQLITE_OK;
}

fn control(file: [*c]c.sqlite3_file, operation: c_int, _: ?*anyopaque) callconv(.c) c_int {
    _ = owner(file);
    assert(operation > 0);
    return c.SQLITE_NOTFOUND;
}

fn sector(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    _ = owner(file);
    return 4096;
}

fn characteristics(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    _ = owner(file);
    return 0;
}

comptime {
    assert(scratch.block_size % 4096 == 0);
    assert(methods.iVersion == 1);
    assert(methods.xFetch == null);
    assert(methods.xShmMap == null);
}

const methods: c.sqlite3_io_methods = .{
    .iVersion = 1,
    .xClose = close,
    .xRead = read,
    .xWrite = write,
    .xTruncate = truncate,
    .xSync = sync,
    .xFileSize = size,
    .xLock = lock,
    .xUnlock = lock,
    .xCheckReservedLock = reserved,
    .xFileControl = control,
    .xSectorSize = sector,
    .xDeviceCharacteristics = characteristics,
};
