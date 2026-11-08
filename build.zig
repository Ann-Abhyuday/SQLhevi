const std = @import("std");
const assert = std.debug.assert;
const upstream = "dependencies/tigerbeetle/src/";

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .cpu_features_add = std.Target.x86.featureSet(&.{ .aes, .pclmul }),
    });
    const optimize = b.standardOptimizeOption(.{});
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        @panic("SQLhevi requires Debug or ReleaseSafe to preserve safety assertions");
    }
    const modules = build_vsr(b);
    const settings = build_settings(b);
    const sqlite = build_sqlite(b, &target, optimize);
    assert(target.result.os.tag == .linux);
    assert(target.result.abi == .musl);
    var capacity_check: *std.Build.Step = undefined;
    for ([_]struct { name: []const u8, source: []const u8, step: []const u8 }{
        .{ .name = "SQLhevi", .source = "src/main.zig", .step = "run" },
        .{ .name = "SQLhevi-sim", .source = "src/simulator.zig", .step = "simulate" },
        .{
            .name = "SQLhevi-test-cluster",
            .source = "tests/native_cluster.zig",
            .step = "test-cluster",
        },
    }) |artifact| {
        const module = b.createModule(.{
            .root_source_file = b.path(artifact.source),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("vsr", modules.vsr);
        module.addImport("stdx", modules.stdx);
        module.addOptions("build_options", settings.options);
        module.code_model = settings.code_model;
        module.addIncludePath(b.path(".tooling/sqlite"));
        module.linkLibrary(sqlite);
        const exe = b.addExecutable(.{
            .name = artifact.name,
            .root_module = module,
            .linkage = .static,
        });
        b.installArtifact(exe);
        if (std.mem.eql(u8, artifact.name, "SQLhevi")) {
            const capacity = b.addRunArtifact(exe);
            capacity.addArgs(&.{ "capacity", "1125899906842624" });
            b.step("test-capacity", "Check actual upstream maximum memory reservation")
                .dependOn(&capacity.step);
            capacity_check = &capacity.step;
        }
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(artifact.step, artifact.name).dependOn(&run.step);
    }
    build_checks(b, &target, optimize, sqlite, capacity_check, settings);
    build_spill_tests(b, &target, optimize, sqlite, modules, settings);
    build_container_tests(b, &target, optimize, sqlite, modules, settings);
    @import("tests/bench_build.zig").build(b, &target, optimize, sqlite, .{
        .vsr = modules.vsr,
        .stdx = modules.stdx,
        .settings = settings.options,
        .code_model = settings.code_model,
    });
}

const Settings = struct {
    options: *std.Build.Step.Options,
    code_model: std.builtin.CodeModel,
};

fn build_settings(b: *std.Build) Settings {
    const bytes = b.option(
        u32,
        "sqlite-memory-limit",
        "SQLite pool and hard heap limit in bytes",
    ) orelse 512 * 1024 * 1024;
    if (bytes < 4 * 1024 * 1024 or bytes > std.math.maxInt(i32)) {
        @panic("sqlite-memory-limit must be between 4194304 and 2147483647 bytes");
    }
    assert(bytes > 0);
    assert(bytes <= std.math.maxInt(c_int));
    const settings = b.addOptions();
    settings.addOption(u32, "sqlite_memory_limit", bytes);
    // Near 2 GiB, use large-data addressing so the pool cannot push other globals out of
    // range of x86-64 PC-relative relocations. Ordinary-size builds keep their default model.
    return .{ .options = settings, .code_model = if (bytes > 2000000000) .medium else .default };
}

const Modules = struct { vsr: *std.Build.Module, stdx: *std.Build.Module };

fn build_container_tests(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Step.Compile,
    modules: Modules,
    settings: Settings,
) void {
    assert(sqlite.linkage == .static);
    assert(target.result.os.tag == .linux);
    const api = b.createModule(.{
        .root_source_file = b.path("src/bench_api.zig"),
        .target = target.*,
        .optimize = optimize,
    });
    api.addIncludePath(b.path(".tooling/sqlite"));
    api.linkLibrary(sqlite);
    api.addImport("vsr", modules.vsr);
    api.addImport("stdx", modules.stdx);
    api.addOptions("build_options", settings.options);
    api.code_model = settings.code_model;
    const module = b.createModule(.{
        .root_source_file = b.path("tests/container_chaos.zig"),
        .target = target.*,
        .optimize = optimize,
    });
    module.addImport("engine", api);
    module.addImport("vsr", modules.vsr);
    module.addImport("stdx", modules.stdx);
    module.code_model = settings.code_model;
    const executable = b.addExecutable(.{
        .name = "SQLhevi-test-containers",
        .root_module = module,
        .linkage = .static,
    });
    b.step("container-tests", "Build the six-container guest chaos test")
        .dependOn(&b.addInstallArtifact(executable, .{}).step);
}

fn build_spill_tests(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Step.Compile,
    modules: Modules,
    settings: Settings,
) void {
    assert(sqlite.linkage == .static);
    assert(target.result.os.tag == .linux);
    const step = b.step("spill-tests", "Build native scratch corruption and crash tests");
    const paths = [_][]const u8{ "src/scratch_fault_main.zig", "tests/native_spill.zig" };
    for (paths, 0..) |path, index| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target.*,
            .optimize = optimize,
        });
        module.addImport("vsr", modules.vsr);
        module.addImport("stdx", modules.stdx);
        module.addOptions("build_options", settings.options);
        module.code_model = settings.code_model;
        module.addImport("fixture", b.createModule(.{
            .root_source_file = b.path("src/scratch_testing.zig"),
        }));
        module.addIncludePath(b.path(".tooling/sqlite"));
        module.linkLibrary(sqlite);
        const exe = b.addExecutable(.{
            .name = if (index == 0) "SQLhevi-fault-test" else "SQLhevi-test-spill",
            .root_module = module,
            .linkage = .static,
        });
        step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

fn build_vsr(b: *std.Build) Modules {
    const stdx = b.createModule(.{ .root_source_file = b.path(upstream ++ "stdx/stdx.zig") });
    const test_options = b.addOptions();
    test_options.addOption(bool, "benchmark", false);
    stdx.addOptions("test_options", test_options);
    const vsr = b.createModule(.{ .root_source_file = b.path(upstream ++ "vsr.zig") });
    vsr.addImport("stdx", stdx);
    vsr.addImport("abi", b.createModule(.{ .root_source_file = b.path(upstream ++ "abi.zig") }));
    const options = b.addOptions();
    options.addOption(bool, "config_verify", true);
    options.addOption(?[40]u8, "git_commit", null);
    options.addOption([]const u8, "release", "0.0.1");
    options.addOption([]const u8, "release_client_min", "0.0.1");
    vsr.addOptions("vsr_options", options);
    assert(vsr != stdx);
    assert(vsr.root_source_file != null);
    return .{ .vsr = vsr, .stdx = stdx };
}

fn build_sqlite(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    assert(target.result.os.tag == .linux);
    assert(target.result.abi == .musl);
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target.*, .optimize = optimize }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = b.path(".tooling/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",                "-DSQLITE_THREADSAFE=0",        "-DSQLITE_OS_OTHER=1",
            "-DSQLITE_TEMP_STORE=1",   "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_LOCALTIME",
            "-DSQLITE_ENABLE_MEMSYS5", "-DSQLITE_DEFAULT_MEMSTATUS=1", "-DSQLITE_MAX_MMAP_SIZE=0",
            "-DSQLITE_DQS=0",          "-DSQLITE_ENABLE_API_ARMOR",    "-DSQLITE_ZERO_MALLOC",
            "-DSQLITE_OMIT_AUTOINIT",
        },
    });
    sqlite.root_module.link_libc = true;
    return sqlite;
}

fn build_checks(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Step.Compile,
    capacity_check: *std.Build.Step,
    settings: Settings,
) void {
    assert(target.result.abi == .musl);
    assert(sqlite.linkage == .static);
    const module = b.createModule(.{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target.*,
        .optimize = optimize,
    });
    module.addIncludePath(b.path(".tooling/sqlite"));
    module.addOptions("build_options", settings.options);
    module.code_model = settings.code_model;
    module.linkLibrary(sqlite);
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    b.step("test", "SQLite isolation, determinism, and atomicity").dependOn(&run.step);
    const format = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tools", "tests" },
        .check = true,
    });
    b.step("fmt-check", "Check Zig formatting").dependOn(&format.step);
    const style = b.addExecutable(.{
        .name = "tigerstyle",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tigerstyle.zig"),
            .target = target.*,
            .optimize = optimize,
        }),
    });
    const check = b.addRunArtifact(style);
    check.setCwd(b.path("."));
    check.setEnvironmentVariable("C_BASE", b.pathFromRoot("dependencies/cobra/rules"));
    b.step("style", "Cobra TigerStyle checks").dependOn(&check.step);
    const all = b.step("check", "Unit tests, formatting, and Cobra checks");
    all.dependOn(&run.step);
    all.dependOn(&format.step);
    all.dependOn(&check.step);
    all.dependOn(capacity_check);
}
