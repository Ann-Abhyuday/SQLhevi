const std = @import("std");
const assert = std.debug.assert;

pub fn build(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Step.Compile,
    dependencies: struct {
        vsr: *std.Build.Module,
        stdx: *std.Build.Module,
        settings: *std.Build.Step.Options,
        code_model: std.builtin.CodeModel,
    },
) void {
    assert(sqlite.linkage == .static);
    assert(target.result.abi == .musl);
    const plain = b.addLibrary(.{
        .name = "sqlite3-benchmark",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target.*, .optimize = optimize }),
    });
    plain.root_module.addCSourceFile(.{
        .file = b.path(".tooling/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",                     "-DSQLITE_THREADSAFE=0",    "-DSQLITE_ENABLE_MEMSYS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_MAX_MMAP_SIZE=0", "-DSQLITE_DQS=0",
            "-DSQLITE_ENABLE_API_ARMOR",
        },
    });
    plain.root_module.link_libc = true;
    const step = b.step("benchmarks", "Build static performance and memory-pressure drivers");
    for ([_][]const u8{ "sqlite", "engine", "cluster" }) |kind| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/bench_{s}.zig", .{kind})),
            .target = target.*,
            .optimize = optimize,
        });
        if (std.mem.eql(u8, kind, "sqlite")) {
            module.addIncludePath(b.path(".tooling/sqlite"));
            module.linkLibrary(plain);
        } else {
            const engine = b.createModule(.{
                .root_source_file = b.path("src/bench_api.zig"),
                .target = target.*,
                .optimize = optimize,
            });
            engine.addIncludePath(b.path(".tooling/sqlite"));
            engine.linkLibrary(sqlite);
            engine.addImport("vsr", dependencies.vsr);
            engine.addImport("stdx", dependencies.stdx);
            engine.addOptions("build_options", dependencies.settings);
            engine.code_model = dependencies.code_model;
            module.code_model = dependencies.code_model;
            module.addImport("engine", engine);
            module.addImport("vsr", dependencies.vsr);
            module.addImport("stdx", dependencies.stdx);
        }
        const executable = b.addExecutable(.{
            .name = b.fmt("SQLhevi-bench-{s}", .{kind}),
            .root_module = module,
            .linkage = .static,
        });
        step.dependOn(&b.addInstallArtifact(executable, .{}).step);
    }
}
