const std = @import("std");
const assert = std.debug.assert;
const c = @import("bench_c.zig").c;
var upstream: [*c]c.sqlite3_vfs = null;
var vfs: c.sqlite3_vfs = undefined;
var slots: [8]Slot = @splat(.{});
pub var written: u64 = 0;
const Slot = struct {
    file: [*c]c.sqlite3_file = null,
    upstream: [*c]const c.sqlite3_io_methods = null,
    methods: c.sqlite3_io_methods = undefined,
};

// TEMPBUF_SPILL does not count the ephemeral btree used by this CTE.
// Wrap only temporary file writes. Everything else uses SQLite's unchanged POSIX VFS.
pub fn initialize() !void {
    assert(upstream == null);
    upstream = c.sqlite3_vfs_find(null);
    assert(upstream != null);
    vfs = upstream.*;
    vfs.zName = "benchmark-spill-audit";
    vfs.pNext = null;
    vfs.xOpen = open;
    if (c.sqlite3_vfs_register(&vfs, 1) != c.SQLITE_OK) return error.VfsRegistration;
}

fn open(
    owner: [*c]c.sqlite3_vfs,
    path: [*c]const u8,
    file: [*c]c.sqlite3_file,
    flags: c_int,
    output: [*c]c_int,
) callconv(.c) c_int {
    assert(owner == &vfs);
    assert(file != null);
    const result = upstream.*.xOpen.?(upstream, path, file, flags, output);
    if (result != c.SQLITE_OK or flags & c.SQLITE_OPEN_DELETEONCLOSE == 0) return result;
    for (&slots) |*slot| {
        if (slot.file != null) continue;
        slot.file = file;
        slot.upstream = file.*.pMethods;
        slot.methods = slot.upstream.*;
        slot.methods.xWrite = write;
        slot.methods.xClose = close;
        file.*.pMethods = &slot.methods;
        return c.SQLITE_OK;
    }
    _ = file.*.pMethods.*.xClose.?(file);
    file.*.pMethods = null;
    return c.SQLITE_CANTOPEN;
}

fn find(file: [*c]c.sqlite3_file) *Slot {
    assert(file != null);
    for (&slots) |*slot| {
        if (slot.file == file) {
            assert(file.*.pMethods == &slot.methods);
            return slot;
        }
    }
    unreachable;
}

fn write(
    file: [*c]c.sqlite3_file,
    bytes: ?*const anyopaque,
    n: c_int,
    off: i64,
) callconv(.c) c_int {
    assert(n > 0);
    assert(off >= 0);
    const slot = find(file);
    const result = slot.upstream.*.xWrite.?(file, bytes, n, off);
    if (result == c.SQLITE_OK) written += @intCast(n);
    return result;
}

fn close(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    const slot = find(file);
    assert(slot.upstream != null);
    assert(slot.upstream.*.xClose != null);
    file.*.pMethods = slot.upstream;
    slot.file = null;
    return file.*.pMethods.*.xClose.?(file);
}
