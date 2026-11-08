const std = @import("std");
const assert = std.debug.assert;

// Disposable local workspace. Only authenticated bytes can reach SQLite. Neither these files
// nor their checksums are database pages, VSR messages, checkpoint data, or recovery inputs.
pub const block_size: u32 = 64 * 1024;
pub const files_max: u32 = 16;
pub const blocks_max: u32 = 65536;
const map_size = 2 * blocks_max;
pub const Position = struct { file: u32, offset: u64 };
pub const Backend = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, u32) anyerror!void,
    close: *const fn (*anyopaque, u32) anyerror!void,
    read: *const fn (*anyopaque, Position, []align(4096) u8) anyerror!void,
    write: *const fn (*anyopaque, Position, []align(4096) const u8) anyerror!void,
};
const Entry = struct { key: u64, digest: [32]u8 = undefined, valid: bool = false };
const Slot = struct { generation: u32 = 0, size: u64 = 0 };

pub const Store = struct {
    backend: Backend,
    entries: []Entry,
    map: []u32,
    buffer: []align(4096) u8,
    verify: []align(4096) u8,
    slots: [files_max]Slot = @splat(.{}),
    count: u32 = 0,
    generation: u32 = 0,
    cached: ?u32 = null,
    position: Position = .{ .file = 0, .offset = 0 },
    dirty: bool = false,
    failure: ?anyerror = null,
    opened: u64 = 0,
    read_bytes: u64 = 0,
    written_bytes: u64 = 0,

    pub fn init(self: *Store, allocator: std.mem.Allocator, backend: *const Backend) !void {
        const entries = try allocator.alloc(Entry, blocks_max);
        errdefer allocator.free(entries);
        const map = try allocator.alloc(u32, map_size);
        errdefer allocator.free(map);
        const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(4096), block_size);
        errdefer allocator.free(buffer);
        const verify = try allocator.alignedAlloc(u8, .fromByteUnits(4096), block_size);
        assert(buffer.len == block_size);
        assert(entries.len * 2 == map.len);
        self.* = .{
            .backend = backend.*,
            .entries = entries,
            .map = map,
            .buffer = buffer,
            .verify = verify,
        };
        self.reset();
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.slots) |slot| assert(slot.generation == 0);
        assert(!self.dirty);
        allocator.free(self.entries);
        allocator.free(self.map);
        allocator.free(self.buffer);
        allocator.free(self.verify);
        self.* = undefined;
    }

    pub fn reset(self: *Store) void {
        for (self.slots) |slot| assert(slot.generation == 0);
        assert(!self.dirty);
        @memset(self.map, 0);
        self.count = 0;
        self.generation = 0;
        self.cached = null;
        self.failure = null;
    }

    pub fn open(self: *Store) !u32 {
        assert(self.count <= self.entries.len);
        assert(self.generation < std.math.maxInt(u32));
        if (self.failure != null) return error.ScratchIO;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.generation != 0) continue;
            const file: u32 = @intCast(index);
            self.backend.open(self.backend.context, file) catch |err| return self.fault(err);
            self.generation += 1;
            slot.* = .{ .generation = self.generation };
            self.opened += 1;
            return file;
        }
        return error.ScratchLimit;
    }

    pub fn close(self: *Store, file: u32) !void {
        assert(file < files_max);
        assert(self.slots[file].generation != 0);
        // The final dirty block need not be written: SQLite has finished with this file.
        if (self.cached != null and self.position.file == file) {
            self.cached = null;
            self.dirty = false;
        }
        self.slots[file] = .{};
        self.backend.close(self.backend.context, file) catch |err| return self.fault(err);
    }

    pub fn fault(self: *Store, err: anyerror) error{ScratchIO} {
        assert(self.count <= blocks_max);
        assert(self.map.len == map_size);
        if (self.failure == null) self.failure = err;
        return error.ScratchIO;
    }

    fn entry(self: *Store, position: Position) !u32 {
        assert(position.file < files_max);
        assert(position.offset % block_size == 0);
        const generation = self.slots[position.file].generation;
        assert(generation != 0);
        const block = position.offset / block_size;
        if (block >= blocks_max) return error.ScratchLimit;
        const key = (@as(u64, generation) << 32) | (block + 1);
        const hash: u32 = @truncate(key *% 0x9e3779b97f4a7c15 >> 32);
        for (0..map_size) |probe| {
            const slot = (hash +% probe) % map_size;
            if (self.map[slot] != 0) {
                const index = self.map[slot] - 1;
                if (self.entries[index].key == key) return index;
            } else {
                if (self.count == self.entries.len) return error.ScratchLimit;
                const index = self.count;
                self.count += 1;
                self.entries[index] = .{ .key = key };
                self.map[slot] = index + 1;
                return index;
            }
        }
        unreachable; // At least half the hash table is always empty.
    }

    pub fn flush(self: *Store) !void {
        assert(self.buffer.len == block_size);
        if (self.failure != null) return error.ScratchIO;
        if (!self.dirty) return;
        assert(self.cached != null);
        const entry_pointer = &self.entries[self.cached.?];
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.buffer, &digest, .{});
        self.backend.write(self.backend.context, self.position, self.buffer) catch |err| {
            return self.fault(err);
        };
        self.written_bytes += block_size;
        self.backend.read(self.backend.context, self.position, self.verify) catch |err| {
            return self.fault(err);
        };
        self.read_bytes += block_size;
        if (!std.mem.eql(u8, self.buffer, self.verify)) return self.fault(error.ScratchCorrupt);
        entry_pointer.digest = digest;
        entry_pointer.valid = true;
        self.dirty = false;
    }

    fn load(self: *Store, position: Position) !void {
        assert(position.offset % block_size == 0);
        assert(position.file < files_max);
        if (self.failure != null) return error.ScratchIO;
        if (self.cached != null and self.position.file == position.file and
            self.position.offset == position.offset) return;
        try self.flush();
        const index = try self.entry(position);
        const expected = &self.entries[index];
        if (expected.valid) {
            self.backend.read(self.backend.context, position, self.buffer) catch |err| {
                return self.fault(err);
            };
            self.read_bytes += block_size;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(self.buffer, &digest, .{});
            if (!std.mem.eql(u8, &digest, &expected.digest)) {
                return self.fault(error.ScratchCorrupt);
            }
        } else @memset(self.buffer, 0);
        self.cached = index;
        self.position = position;
        self.dirty = false;
    }

    pub fn read(self: *Store, position: Position, output: []u8) !usize {
        assert(position.file < files_max);
        const slot = &self.slots[position.file];
        assert(slot.generation != 0);
        @memset(output, 0);
        const length = @min(output.len, slot.size - @min(position.offset, slot.size));
        var done: usize = 0;
        for (0..output.len / block_size + 2) |_| {
            if (done == length) break;
            const at = position.offset + done;
            const within = at % block_size;
            const count = @min(length - done, block_size - within);
            try self.load(.{ .file = position.file, .offset = at - within });
            @memcpy(output[done..][0..count], self.buffer[within..][0..count]);
            done += count;
        }
        assert(done == length);
        return done;
    }

    pub fn write(self: *Store, position: Position, bytes: []const u8) !void {
        assert(position.file < files_max);
        const slot = &self.slots[position.file];
        assert(slot.generation != 0);
        if (position.offset > @as(u64, blocks_max) * block_size) return error.ScratchLimit;
        if (bytes.len > @as(u64, blocks_max) * block_size - position.offset) {
            return error.ScratchLimit;
        }
        var done: usize = 0;
        for (0..bytes.len / block_size + 2) |_| {
            if (done == bytes.len) break;
            const at = position.offset + done;
            const within = at % block_size;
            const count = @min(bytes.len - done, block_size - within);
            try self.load(.{ .file = position.file, .offset = at - within });
            @memcpy(self.buffer[within..][0..count], bytes[done..][0..count]);
            self.dirty = true;
            done += count;
            slot.size = @max(slot.size, position.offset + done);
        }
        assert(done == bytes.len);
    }

    pub fn resize(self: *Store, position: Position) !void {
        assert(position.file < files_max);
        const slot = &self.slots[position.file];
        assert(slot.generation != 0);
        if (position.offset > @as(u64, blocks_max) * block_size) return error.ScratchLimit;
        if (position.offset < slot.size) {
            if (self.cached != null and self.position.file == position.file and
                self.position.offset >= position.offset)
            {
                self.cached = null;
                self.dirty = false;
            }
            const first = (position.offset + block_size - 1) / block_size;
            for (self.entries[0..self.count]) |*item| {
                if (item.key >> 32 != slot.generation) continue;
                const block = @as(u32, @truncate(item.key)) - 1;
                if (block >= first) item.valid = false;
            }
            const tail = position.offset % block_size;
            if (tail != 0) {
                try self.load(.{ .file = position.file, .offset = position.offset - tail });
                @memset(self.buffer[tail..], 0);
                self.dirty = true;
            }
        }
        slot.size = position.offset;
    }

    pub fn size(self: *const Store, file: u32) u64 {
        assert(file < files_max);
        assert(self.slots[file].generation != 0);
        return self.slots[file].size;
    }
};
