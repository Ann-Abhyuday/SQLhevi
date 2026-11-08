const std = @import("std");
const assert = std.debug.assert;
const ast = @import("style_ast.zig");

// Cobra supplies tokenization, balanced-delimiter links, and structural queries. Its C parser is
// deliberately disabled: interpreting Zig as preprocessed C would silently skip important code.
const rules =
    \\%{
    \\ if (.txt == "goto" || .txt == "malloc" || .txt == "calloc" || .txt == "realloc") {
    \\   print "FAIL " .fnm ":" .lnr ": forbidden control flow or allocation\n";
    \\ }
    \\ if (.txt != "fn" || .nxt.txt == "(") { Next; }
    \\ name = .nxt;
    \\ cur = name.nxt;
    \\ if (cur.txt != "(") { Next; }
    \\ cur = cur.jmp.nxt;
    \\ if (cur.txt == "type") { Next; }
    \\ if (cur.txt == "error" && cur.nxt.txt == "{") { cur = cur.nxt.jmp.nxt; }
    \\ while (cur.txt != "{" && cur.txt != ";" && cur.txt != "") { cur = cur.nxt; }
    \\ if (cur.txt != "{") { Next; }
    \\ last = cur.jmp;
    \\ lines = last.lnr - .lnr + 1;
    \\ if (lines > 70) {
    \\   print "FAIL " .fnm ":" .lnr ": " name.txt " exceeds 70 lines (" lines ")\n";
    \\ }
    \\ cur = cur.nxt;
    \\ while (cur.seq < last.seq) {
    \\   if (cur.txt == name.txt && cur.nxt.txt == "(" && cur.prv.txt != ".") {
    \\     print "FAIL " .fnm ":" cur.lnr ": direct recursion in " name.txt "\n";
    \\   }
    \\   cur = cur.nxt;
    \\ }
    \\%}
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    try files.append(allocator, "build.zig");
    for ([_][]const u8{ "src", "tools", "tests" }) |directory| {
        try collect(init.io, allocator, directory, &files);
    }
    assert(files.items.len > 1);
    assert(files.items.len < 1000);
    var metrics: Metrics = .{};
    try std.Io.Dir.cwd().createDirPath(init.io, ".tooling/style");
    const rules_file = try std.Io.Dir.cwd().createFile(init.io, ".tooling/style/rules.cobra", .{});
    defer rules_file.close(init.io);
    try rules_file.writeStreamingAll(init.io, rules);
    const sources = try std.Io.Dir.cwd().createFile(init.io, ".tooling/style/sources.txt", .{});
    defer sources.close(init.io);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{
        "dependencies/cobra/src/cobra", "-N1",                        "-quiet", "-nocpp",
        "-f",                           ".tooling/style/rules.cobra",
    });
    for (files.items, 0..) |path, index| {
        const sanitized = try sanitize(init.io, allocator, path, @intCast(index), &metrics);
        try args.append(allocator, sanitized);
        const mapping = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ sanitized, path });
        try sources.writeStreamingAll(init.io, mapping);
    }
    try self_test(&init, allocator);
    try ast.self_test(allocator);
    const result = try std.process.run(allocator, init.io, .{
        .argv = args.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) return error.CobraFailed;
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    if (std.mem.indexOf(u8, result.stdout, "FAIL ") != null) return error.TigerStyle;
    for (files.items) |path| try check_source(init.io, allocator, path);
    if (metrics.assertions < metrics.functions * 2) return error.AssertionDensity;
    std.debug.print("Cobra TigerStyle: {d} files, {d} assertions, {d} functions; " ++
        "positive and negative checks passed\n", .{
        files.items.len, metrics.assertions, metrics.functions,
    });
}

const Metrics = ast.Metrics;

fn collect(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    assert(path.len > 0);
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    for (0..1000) |_| {
        const entry = try walker.next(io) orelse return;
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zig")) {
            const filename = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.path });
            try files.append(allocator, filename);
        }
    }
    return error.SourceFileLimit;
}

fn check_source(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    assert(path.len > 0);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    assert(source.len < 1024 * 1024);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 0;
    for (0..100000) |_| {
        const text = lines.next() orelse return;
        line += 1;
        if (text.len > 100) {
            std.debug.print("FAIL {s}:{d}: line exceeds 100 columns ({d})\n", .{
                path, line, text.len,
            });
            return error.TigerStyle;
        }
        if (std.mem.indexOfScalar(u8, text, '\t') != null) return error.TabIndentation;
    }
    return error.SourceLineLimit;
}

fn sanitize(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    index: u32,
    metrics: *Metrics,
) ![]const u8 {
    assert(path.len > 0);
    assert(index < 1000);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    const terminated = try allocator.dupeZ(u8, source);
    const counts = ast.check(allocator, terminated, path) catch |err| {
        std.debug.print("FAIL {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    metrics.functions += counts.functions;
    metrics.assertions += counts.assertions;
    var tokenizer = std.zig.Tokenizer.init(terminated);
    for (0..1000000) |_| {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        switch (token.tag) {
            .string_literal, .char_literal, .multiline_string_literal_line => {
                for (source[token.loc.start..token.loc.end]) |*byte| {
                    if (byte.* != '\n') byte.* = ' ';
                }
            },
            else => {},
        }
    } else return error.TokenLimit;
    const output = try std.fmt.allocPrint(allocator, ".tooling/style/{d}.zig", .{index});
    const file = try std.Io.Dir.cwd().createFile(io, output, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, source);
    return output;
}

fn self_test(init: *const std.process.Init, allocator: std.mem.Allocator) !void {
    const path = ".tooling/style/reject.zig";
    const source = "fn recursive() void { recursive(); }\n" ++
        "fn too_long() void {\n" ++ "    _ = 1;\n" ** 71 ++ "}\n" ++
        "fn allocate() void { malloc(1); }\n";
    assert(source.len < 4096);
    assert(std.mem.count(u8, source, "fn ") == 3);
    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, source);
    const result = try std.process.run(allocator, init.io, .{
        .argv = &.{
            "dependencies/cobra/src/cobra", "-N1", "-quiet", "-nocpp", "-f",
            ".tooling/style/rules.cobra",   path,
        },
        .stdout_limit = .limited(16384),
        .stderr_limit = .limited(16384),
    });
    if (result.term != .exited or result.term.exited != 0) return error.CobraSelfTest;
    for ([_][]const u8{ "direct recursion", "exceeds 70 lines", "forbidden" }) |expected| {
        if (std.mem.indexOf(u8, result.stdout, expected) == null) {
            std.debug.print("Cobra self-test missing {s}: {s}\n{s}\n", .{
                expected, result.stdout, result.stderr,
            });
            return error.CobraSelfTest;
        }
    }
}
