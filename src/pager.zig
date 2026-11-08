const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite.zig").c;
const limits = @import("limits.zig");

// A transaction reads an immutable snapshot and stages writes in a bounded overlay. A cache miss
// aborts the private SQLite execution. The state machine fetches that range asynchronously and
// replays with the same op/time/PRNG; only the final successful overlay can reach the forest.
pub const Chunk = extern struct {
    timestamp: u64,
    image_size: u64,
    bytes: [limits.chunk_size]u8,
};

pub const Entry = struct { chunk: Chunk, found: bool };
pub var active: ?*Pager = null;

pub const Pager = struct {
    entries: []Entry,
    writes: []Chunk,
    entry_slots: [limits.read_chunks_max * 2]u32 = @splat(0),
    write_slots: [limits.chunks_changed_max * 2]u32 = @splat(0),
    read_limit: u32 = limits.read_chunks_max,
    write_limit: u32 = limits.chunks_changed_max,
    count: u32 = 0,
    write_count: u32 = 0,
    size: u64 = 0,
    size_base: u64 = 0,
    missing: ?u64 = null,
    failure: ?anyerror = null,

    pub fn init(self: *Pager, allocator: std.mem.Allocator) !void {
        assert(@sizeOf(Chunk) == 512);
        const entries = try allocator.alloc(Entry, limits.read_chunks_max);
        errdefer allocator.free(entries);
        const writes = try allocator.alloc(Chunk, limits.chunks_changed_max);
        assert(entries.len > writes.len);
        self.* = .{ .entries = entries, .writes = writes };
    }

    pub fn deinit(self: *Pager, allocator: std.mem.Allocator) void {
        assert(active != self);
        assert(self.entries.len == limits.read_chunks_max);
        allocator.free(self.entries);
        allocator.free(self.writes);
        self.* = undefined;
    }

    pub fn reset(self: *Pager) void {
        assert(active != self);
        assert(self.writes.len == limits.chunks_changed_max);
        self.count = 0;
        @memset(&self.entry_slots, 0);
        self.write_count = 0;
        @memset(&self.write_slots, 0);
        self.size = 0;
        self.size_base = 0;
        self.missing = null;
        self.failure = null;
    }

    pub fn retry(self: *Pager) void {
        assert(active == null);
        assert(self.count > 0);
        self.size_base = self.get(1).?.chunk.image_size;
        self.size = self.size_base;
        self.write_count = 0;
        @memset(&self.write_slots, 0);
        self.missing = null;
        self.failure = null;
    }

    pub fn get(self: *const Pager, key: u64) ?*const Entry {
        assert(key > 0);
        assert(self.count <= self.entries.len);
        const mask = self.entry_slots.len - 1;
        const start = (key *% 0x9e3779b97f4a7c15) & mask;
        for (0..self.entry_slots.len) |probe| {
            const value = self.entry_slots[(start + probe) & mask];
            if (value == 0) return null;
            const entry = &self.entries[value - 1];
            if (entry.chunk.timestamp == key) return entry;
        }
        unreachable; // Occupancy never exceeds one half, so a missing key reaches an empty slot.
    }

    pub fn supply(self: *Pager, chunk: *const Chunk, found: bool) !void {
        assert(active == null);
        assert(self.get(chunk.timestamp) == null);
        if (self.count == self.read_limit) return error.ReadSetLimit;
        self.entries[self.count] = .{ .chunk = chunk.*, .found = found };
        self.count += 1;
        const mask = self.entry_slots.len - 1;
        const start = (chunk.timestamp *% 0x9e3779b97f4a7c15) & mask;
        for (0..self.entry_slots.len) |probe| {
            const slot = &self.entry_slots[(start + probe) & mask];
            if (slot.* != 0) continue;
            slot.* = @intCast(self.count);
            return;
        }
        unreachable;
    }

    fn read_chunk(self: *Pager, key: u64) ?*const Chunk {
        assert(key >= 2);
        assert(self.write_count <= self.writes.len);
        const slot = self.write_slot(key);
        if (slot.* != 0) return &self.writes[slot.* - 1];
        const entry = self.get(key) orelse {
            if (self.missing == null) self.missing = key;
            return null;
        };
        return &entry.chunk;
    }

    fn write_chunk(self: *Pager, key: u64) ?*Chunk {
        assert(key > 0);
        assert(self.write_count <= self.writes.len);
        const slot = self.write_slot(key);
        if (slot.* != 0) return &self.writes[slot.* - 1];
        const entry = self.get(key) orelse {
            if (self.missing == null) self.missing = key;
            return null;
        };
        if (self.write_count == self.write_limit) {
            self.failure = error.TransactionTooLarge;
            return null;
        }
        const chunk = &self.writes[self.write_count];
        chunk.* = entry.chunk;
        self.write_count += 1;
        slot.* = self.write_count;
        return chunk;
    }

    fn write_slot(self: *Pager, key: u64) *u32 {
        assert(key > 0);
        assert(self.write_count <= self.write_slots.len / 2);
        const mask = self.write_slots.len - 1;
        const start = (key *% 0x9e3779b97f4a7c15) & mask;
        for (0..self.write_slots.len) |probe| {
            const slot = &self.write_slots[(start + probe) & mask];
            if (slot.* == 0 or self.writes[slot.* - 1].timestamp == key) return slot;
        }
        unreachable; // A half-empty hash table always has a free slot.
    }

    pub fn read(self: *Pager, buffer: []u8, offset: u64) c_int {
        assert(buffer.len > 0);
        assert(buffer.len <= limits.page_size);
        @memset(buffer, 0);
        assert(self.size <= limits.logical_size_max);
        if (offset > limits.logical_size_max) return c.SQLITE_IOERR_READ;
        const available = self.size -| offset;
        const length = @min(buffer.len, available);
        var done: u32 = 0;
        for (0..length / limits.chunk_size + 2) |_| {
            if (done == length) break;
            const at = offset + done;
            const within: u32 = @intCast(at % limits.chunk_size);
            const count = @min(length - done, limits.chunk_size - within);
            const chunk = self.read_chunk(at / limits.chunk_size + 2) orelse {
                return c.SQLITE_IOERR_READ;
            };
            @memcpy(buffer[done..][0..count], chunk.bytes[within..][0..count]);
            done += @intCast(count);
        }
        assert(done == length);
        return if (length == buffer.len) c.SQLITE_OK else c.SQLITE_IOERR_SHORT_READ;
    }

    pub fn write(self: *Pager, buffer: []const u8, offset: u64) c_int {
        assert(buffer.len > 0);
        assert(buffer.len <= limits.page_size);
        assert(self.size <= limits.logical_size_max);
        if (offset > limits.logical_size_max) return c.SQLITE_FULL;
        if (buffer.len > limits.logical_size_max - offset) return c.SQLITE_FULL;
        var done: u32 = 0;
        for (0..buffer.len / limits.chunk_size + 2) |_| {
            if (done == buffer.len) break;
            const at = offset + done;
            const within: u32 = @intCast(at % limits.chunk_size);
            const count = @min(buffer.len - done, limits.chunk_size - within);
            const chunk = self.write_chunk(at / limits.chunk_size + 2) orelse {
                return c.SQLITE_IOERR_WRITE;
            };
            @memcpy(chunk.bytes[within..][0..count], buffer[done..][0..count]);
            done += @intCast(count);
        }
        self.size = @max(self.size, offset + buffer.len);
        assert(done == buffer.len);
        return c.SQLITE_OK;
    }

    pub fn finish(self: *Pager) !void {
        assert(active == null);
        assert(self.missing == null);
        if (self.size != self.size_base) {
            const metadata = self.write_chunk(1) orelse return error.TransactionTooLarge;
            metadata.image_size = self.size;
        }
        assert(self.size % limits.page_size == 0);
        assert(self.write_count <= limits.chunks_changed_max);
    }
};

pub const File = extern struct { base: c.sqlite3_file, pager: *Pager };

pub fn open(file: [*c]c.sqlite3_file, flags: c_int, output: [*c]c_int) c_int {
    assert(file != null);
    assert(file.*.pMethods == null);
    if (active == null or flags & c.SQLITE_OPEN_MAIN_DB == 0) return c.SQLITE_CANTOPEN;
    const own: *File = @ptrCast(@alignCast(file));
    own.* = .{ .base = .{ .pMethods = &methods }, .pager = active.? };
    if (output != null) output.* = flags;
    return c.SQLITE_OK;
}

fn owner(file: [*c]c.sqlite3_file) *Pager {
    assert(file != null);
    assert(file.*.pMethods == &methods);
    return @as(*File, @ptrCast(@alignCast(file))).pager;
}

fn close(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(file.*.pMethods != null);
    file.*.pMethods = null;
    return c.SQLITE_OK;
}

fn read(file: [*c]c.sqlite3_file, data: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    assert(n > 0);
    assert(off >= 0);
    const bytes: [*]u8 = @ptrCast(data.?);
    return owner(file).read(bytes[0..@intCast(n)], @intCast(off));
}

fn write(file: [*c]c.sqlite3_file, data: ?*const anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    assert(n > 0);
    assert(off >= 0);
    const bytes: [*]const u8 = @ptrCast(data.?);
    return owner(file).write(bytes[0..@intCast(n)], @intCast(off));
}

fn truncate(file: [*c]c.sqlite3_file, length: i64) callconv(.c) c_int {
    assert(length >= 0);
    const self = owner(file);
    assert(self.size <= limits.logical_size_max);
    // Shrinking requires atomically retiring tail chunks. VACUUM/auto_vacuum are not exposed yet.
    // SQLite rollback is discarded with the entire overlay, so it need not truncate durable data.
    if (length != self.size) return c.SQLITE_IOERR_TRUNCATE;
    return c.SQLITE_OK;
}

fn sync(file: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(flags != 0);
    // The overlay becomes durable through VSR and its checkpoint/journal, outside SQLite's pager.
    return c.SQLITE_OK;
}

fn size(file: [*c]c.sqlite3_file, output: [*c]i64) callconv(.c) c_int {
    assert(output != null);
    assert(owner(file).size <= limits.logical_size_max);
    output.* = @intCast(owner(file).size);
    return c.SQLITE_OK;
}

fn lock(file: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(level >= c.SQLITE_LOCK_NONE);
    assert(level <= c.SQLITE_LOCK_EXCLUSIVE);
    return c.SQLITE_OK;
}

fn reserved(file: [*c]c.sqlite3_file, result: [*c]c_int) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(result != null);
    result.* = 0;
    return c.SQLITE_OK;
}

fn control(file: [*c]c.sqlite3_file, operation: c_int, _: ?*anyopaque) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(operation > 0);
    return c.SQLITE_NOTFOUND;
}

fn sector(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(limits.chunk_size < 4096);
    return 4096;
}

fn characteristics(file: [*c]c.sqlite3_file) callconv(.c) c_int {
    assert(owner(file) == active.?);
    assert(methods.iVersion == 1);
    return 0;
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
