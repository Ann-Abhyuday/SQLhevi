const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const addresses = @import("container_client.zig").addresses;

pub const Cluster = struct {
    process: *const std.process.Init,
    directory: []const u8,
    live: [6]bool = @splat(false),
    kills: [6]u32 = @splat(0),
    starts: [6]u32 = @splat(0),

    pub fn init(self: *Cluster) !void {
        assert(self.directory[0] == '/');
        assert(self.count() == 0);
        const io = self.process.io;
        const cwd = std.Io.Dir.cwd();
        // A fresh directory is mandatory: never format over an existing test or user database.
        try cwd.createDir(io, self.directory, .default_dir);
        var buffer: [4096]u8 = undefined;
        for ([_][]const u8{ "rootfs", "rootfs/proc", "rootfs/dev", "rootfs/data", "run" }) |dir| {
            const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.directory, dir });
            try cwd.createDir(io, path, .default_dir);
        }
        const executable = try std.fmt.bufPrint(&buffer, "{s}/rootfs/SQLhevi", .{self.directory});
        try cwd.copyFile("/SQLhevi", cwd, executable, io, .{});
        for (0..6) |index| try self.prepare(index);
    }

    fn prepare(self: *Cluster, index: usize) !void {
        assert(index < self.live.len);
        assert(!self.live[index]);
        var buffer: [4096]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        for ([_][]const u8{ "", "/data" }) |suffix| {
            const path = try std.fmt.bufPrint(&buffer, "{s}/{d}{s}", .{
                self.directory, index, suffix,
            });
            try cwd.createDir(self.process.io, path, .default_dir);
        }
        var id_buffer: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{index});
        const database = try std.fmt.bufPrint(&buffer, "{s}/{d}/data/replica", .{
            self.directory, index,
        });
        try self.command(&.{ "/SQLhevi", "format", "0", id, "6", database }, null);
        try self.config(index);
    }

    fn config(self: *Cluster, index: usize) !void {
        assert(index < self.live.len);
        assert(self.directory.len < 512);
        var buffer: [8192]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer,
            \\{{"ociVersion":"1.0.2",
            \\"root":{{"path":"{s}/rootfs","readonly":true}},
            \\"hostname":"SQLhevi-{d}",
            \\"process":{{"terminal":false,"user":{{"uid":0,"gid":0}},
            \\"args":["/SQLhevi","start","{s}","/data/replica","1073741824"],
            \\"env":["PATH=/"],"cwd":"/data","noNewPrivileges":true,
            \\"capabilities":{{"bounding":[],"effective":[],"permitted":[]}},
            \\"rlimits":[{{"type":"RLIMIT_NOFILE","hard":4096,"soft":4096}}]}},
            \\"mounts":[{{"destination":"/proc","type":"proc","source":"proc"}},
            \\{{"destination":"/dev","type":"tmpfs","source":"tmpfs"}},
            \\{{"destination":"/data","type":"bind","source":"{s}/{d}/data",
            \\"options":["rbind","rw"]}}],
            \\"linux":{{"cgroupsPath":"/SQLhevi-{d}","namespaces":[
            \\{{"type":"pid"}},{{"type":"mount"}},{{"type":"uts"}},
            \\{{"type":"ipc"}},{{"type":"cgroup"}}]}}}}
        , .{ self.directory, index, addresses, self.directory, index, index });
        var path_buffer: [4096]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{d}/config.json", .{
            self.directory, index,
        });
        try std.Io.Dir.cwd().writeFile(self.process.io, .{ .sub_path = path, .data = json });
    }

    pub fn start(self: *Cluster, index: usize) !void {
        assert(index < self.live.len);
        assert(!self.live[index]);
        var bundle_buffer: [4096]u8 = undefined;
        var root_buffer: [4096]u8 = undefined;
        var name_buffer: [32]u8 = undefined;
        var log_buffer: [4096]u8 = undefined;
        const bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/{d}", .{ self.directory, index });
        const root = try std.fmt.bufPrint(&root_buffer, "{s}/run", .{self.directory});
        const name = try std.fmt.bufPrint(&name_buffer, "SQLhevi-{d}", .{index});
        const log = try std.fmt.bufPrint(&log_buffer, "{s}/{d}/start-{d}.log", .{
            self.directory, index, self.starts[index],
        });
        const file = try std.Io.Dir.cwd().createFile(self.process.io, log, .{ .exclusive = true });
        defer file.close(self.process.io);
        // runc's ramdisk mode is required when the guest's old root is initramfs.
        const argv = &.{ "/runc", "--root", root, "run", "--no-pivot", "-d", "-b", bundle, name };
        self.command(argv, file) catch |err| {
            var output: [8192]u8 = undefined;
            const bytes = try std.Io.Dir.cwd().readFile(self.process.io, log, &output);
            std.debug.print("OCI start failed: {s}\n", .{bytes});
            return err;
        };
        self.live[index] = true;
        self.starts[index] += 1;
        try self.verify_container(.{ .root = root, .name = name });
        std.debug.print("CHAOS start node={d} generation={d} live={d}\n", .{
            index, self.starts[index], self.count(),
        });
    }

    pub fn stop(self: *Cluster, index: usize) !void {
        assert(index < self.live.len);
        assert(self.live[index]);
        var root_buffer: [4096]u8 = undefined;
        var name_buffer: [32]u8 = undefined;
        const root = try std.fmt.bufPrint(&root_buffer, "{s}/run", .{self.directory});
        const name = try std.fmt.bufPrint(&name_buffer, "SQLhevi-{d}", .{index});
        try self.command(&.{ "/runc", "--root", root, "kill", name, "KILL" }, null);
        try self.command(&.{ "/runc", "--root", root, "delete", "--force", name }, null);
        self.live[index] = false;
        self.kills[index] += 1;
        try reap();
        std.debug.print("CHAOS kill node={d} live={d}\n", .{ index, self.count() });
    }

    pub fn count(self: *const Cluster) u32 {
        var total: u32 = 0;
        for (self.live) |live| total += @intFromBool(live);
        assert(total <= self.live.len);
        return total;
    }

    pub fn cleanup(self: *Cluster) void {
        for (0..self.live.len) |index| {
            if (self.live[index]) self.stop(index) catch |err| {
                std.debug.print("CHAOS cleanup failed: {s}\n", .{@errorName(err)});
            };
        }
        assert(self.count() <= self.live.len);
    }

    fn command(self: *Cluster, argv: []const []const u8, log: ?std.Io.File) !void {
        assert(argv.len >= 2);
        assert(argv.len <= 9);
        var child = try std.process.spawn(self.process.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = if (log) |file| .{ .file = file } else .inherit,
            .stderr = if (log) |file| .{ .file = file } else .inherit,
        });
        const term = try child.wait(self.process.io);
        if (term != .exited or term.exited != 0) {
            std.debug.print("CHAOS command failed: {s} {any}\n", .{ argv[0], term });
            return error.ContainerCommandFailed;
        }
    }

    fn verify_container(self: *Cluster, options: struct {
        root: []const u8,
        name: []const u8,
    }) !void {
        assert(self.count() > 0);
        const result = try std.process.run(self.process.gpa, self.process.io, .{
            .argv = &.{ "/runc", "--root", options.root, "state", options.name },
            .stdout_limit = .limited(8192),
            .stderr_limit = .limited(8192),
        });
        defer self.process.gpa.free(result.stdout);
        defer self.process.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.ContainerState;
        const State = struct { pid: i32, status: []const u8 };
        const state = try std.json.parseFromSlice(State, self.process.gpa, result.stdout, .{
            .ignore_unknown_fields = true,
        });
        defer state.deinit();
        if (!std.mem.eql(u8, state.value.status, "running")) return error.ContainerNotRunning;
        assert(state.value.pid > 1);
        try self.verify_namespaces(state.value.pid);
    }

    fn verify_namespaces(self: *Cluster, pid: i32) !void {
        assert(pid > 1);
        const cwd = std.Io.Dir.cwd();
        var path_buffer: [128]u8 = undefined;
        var ours: [128]u8 = undefined;
        var theirs: [128]u8 = undefined;
        for ([_][]const u8{ "pid", "mnt", "uts", "ipc", "cgroup" }) |kind| {
            const own_path = try std.fmt.bufPrint(&path_buffer, "/proc/self/ns/{s}", .{kind});
            const own_size = try cwd.readLink(self.process.io, own_path, &ours);
            const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/ns/{s}", .{ pid, kind });
            const size = try cwd.readLink(self.process.io, path, &theirs);
            if (std.mem.eql(u8, ours[0..own_size], theirs[0..size])) return error.NamespaceShared;
        }
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/status", .{pid});
        var status_buffer: [8192]u8 = undefined;
        const status = try cwd.readFile(self.process.io, path, &status_buffer);
        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "NSpid:\t{d}\t1\n", .{pid});
        if (!std.mem.containsAtLeast(u8, status, 1, expected)) return error.ContainerPid;
        std.debug.print("OCI verified pid={d}: private pid/mount/uts/ipc/cgroup namespaces\n", .{
            pid,
        });
    }
};

fn reap() !void {
    assert(linux.getpid() == 1);
    for (0..128) |_| {
        var status: u32 = undefined;
        const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (result == 0 or linux.errno(result) == .CHILD) return;
        if (linux.errno(result) != .SUCCESS) return error.ReapFailed;
    }
    return error.ReapBoundExceeded;
}

pub fn setup() !void {
    assert(linux.getpid() == 1);
    const created = linux.mkdir("/sys/fs/cgroup", 0o755);
    if (linux.errno(created) != .SUCCESS and linux.errno(created) != .EXIST) {
        return error.CgroupDirectory;
    }
    const mounted = linux.mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, 0);
    if (linux.errno(mounted) != .SUCCESS) return error.CgroupMount;
    const private = linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0);
    if (linux.errno(private) != .SUCCESS) return error.MountPropagation;
}
