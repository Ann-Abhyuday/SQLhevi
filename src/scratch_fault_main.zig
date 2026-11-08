// Test-only server root. Normal SQLhevi has no fault hook or fault environment setting.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const scratch = @import("scratch.zig");
const Native = @import("scratch_io.zig").Native;
pub const tigerbeetle_config = @import("main.zig").tigerbeetle_config;
pub const std_options = @import("main.zig").std_options;
var mode: enum { none, kill_read, kill_write, corrupt_write } = .none;
var eligible = false;
var writes: u32 = 0;
var damaged: [scratch.block_size]u8 align(4096) = undefined;

pub fn main(init: std.process.Init) !void {
    assert(writes == 0);
    assert(mode == .none);
    if (init.environ_map.get("SQLHEVI_TEST_SCRATCH_FAULT")) |value| {
        mode = std.meta.stringToEnum(@TypeOf(mode), value) orelse return error.TestFaultMode;
    }
    try @import("main.zig").main(init);
}

pub fn sqlite_attempt_hook(sql: []const u8) void {
    assert(sql.len > 0);
    assert(sql.len <= @import("limits.zig").sql_size_max);
    const writing = std.mem.startsWith(u8, sql, "UPDATE guard");
    eligible = switch (mode) {
        .none => false,
        .kill_read => !writing,
        .kill_write, .corrupt_write => writing,
    };
}

pub fn scratch_write_hook(
    native: *Native,
    position: scratch.Position,
    bytes: []align(4096) const u8,
) void {
    assert(bytes.len == damaged.len);
    assert(native.files[position.file] >= 0);
    if (!eligible) return;
    writes += 1;
    if (writes != 48) return;
    std.debug.print("SCRATCH TEST: injecting {s} after {d} real io_uring writes\n", .{
        @tagName(mode), writes,
    });
    if (mode == .kill_read or mode == .kill_write) {
        const killed = linux.kill(linux.getpid(), linux.SIG.KILL);
        assert(linux.errno(killed) == .SUCCESS);
        unreachable;
    }
    @memcpy(&damaged, bytes);
    damaged[damaged.len / 2] ^= 1;
    _ = native.ring.write(1, native.files[position.file], &damaged, position.offset) catch {
        @panic("inject corruption write");
    };
    const submitted = native.ring.submit() catch @panic("submit corruption");
    assert(submitted == 1);
    const result = native.ring.copy_cqe() catch @panic("complete corruption");
    assert(result.res == damaged.len);
    assert(result.user_data == 1);
}
