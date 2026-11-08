const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub fn setup() !void {
    assert(linux.getpid() == 1);
    try directory("/proc", 0o755);
    try directory("/sys", 0o755);
    try directory("/dev", 0o755);
    try directory("/data", 0o700);
    try check(linux.mount("proc", "/proc", "proc", 0, 0));
    try check(linux.mount("sysfs", "/sys", "sysfs", 0, 0));
    try check(linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0));
    for ([_][:0]const u8{
        "/lib/virtio_blk.ko", "/lib/crc16.ko", "/lib/mbcache.ko",
        "/lib/jbd2.ko",       "/lib/ext4.ko",
    }) |module| try load_module(module);
    for (0..100) |_| {
        const result = linux.mount("/dev/vda", "/data", "ext4", 0, 0);
        if (linux.errno(result) == .SUCCESS) break;
        if (linux.errno(result) != .NOENT) try check(result);
        const delay: linux.timespec = .{ .sec = 0, .nsec = 100000000 };
        try check(linux.nanosleep(&delay, null));
    } else return error.BlockDeviceNotReady;
    try loopback_up();
    std.debug.print("GUEST: ext4 mounted; loopback ready; running native io_uring tests\n", .{});
}

fn directory(path: [:0]const u8, mode: u32) !void {
    assert(path.len > 0);
    assert(path[0] == '/');
    const result = linux.mkdir(path, mode);
    if (linux.errno(result) == .EXIST) return;
    try check(result);
}

fn load_module(path: [:0]const u8) !void {
    assert(path.len > 0);
    assert(std.mem.startsWith(u8, path, "/lib/"));
    std.debug.print("GUEST: loading {s}\n", .{path});
    const result = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try check(result);
    const fd: i32 = @intCast(result);
    assert(fd >= 0);
    defer check(linux.close(fd)) catch @panic("close guest module");
    const loaded = linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(""), 0);
    if (linux.errno(loaded) == .EXIST) return;
    try check(loaded);
}

fn loopback_up() !void {
    const result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    try check(result);
    const fd: i32 = @intCast(result);
    defer check(linux.close(fd)) catch @panic("close guest socket");
    var request: extern struct { name: [16]u8, flags: i16, padding: [22]u8 } = .{
        .name = @splat(0),
        .flags = 0,
        .padding = @splat(0),
    };
    @memcpy(request.name[0..2], "lo");
    assert(@sizeOf(@TypeOf(request)) == 40);
    try check(linux.ioctl(fd, 0x8913, @intFromPtr(&request)));
    request.flags |= 1;
    try check(linux.ioctl(fd, 0x8914, @intFromPtr(&request)));
}

fn check(result: usize) !void {
    const status = linux.errno(result);
    if (status != .SUCCESS) {
        std.debug.print("guest setup errno: {s}\n", .{@tagName(status)});
        return error.GuestSetup;
    }
}

pub fn poweroff() noreturn {
    assert(linux.getpid() == 1);
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    unreachable;
}
