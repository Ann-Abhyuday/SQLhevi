const std = @import("std");
const assert = std.debug.assert;
const Ast = std.zig.Ast;
pub const Metrics = struct { assertions: u32 = 0, functions: u32 = 0 };

pub fn check(allocator: std.mem.Allocator, source: [:0]const u8, path: []const u8) !Metrics {
    assert(source.len < 1024 * 1024);
    assert(path.len > 0);
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZig;
    var metrics: Metrics = .{};
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) continue;
        try function(&tree, node, path, &metrics);
    }
    return metrics;
}

fn function(tree: *const Ast, node: Ast.Node.Index, path: []const u8, metrics: *Metrics) !void {
    assert(tree.nodeTag(node) == .fn_decl);
    assert(path.len > 0);
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node).?;
    const name = tree.tokenSlice(proto.name_token.?);
    const returns = proto.ast.return_type.unwrap().?;
    if (std.mem.eql(u8, tree.getNodeSource(returns), "type")) return;
    try signature(tree, &proto, path);
    for (name) |byte| {
        if (std.ascii.isUpper(byte)) return error.FunctionSnakeCase;
    }
    metrics.functions += 1;
    const body = tree.nodeData(node).node_and_node[1];
    if (std.mem.count(u8, tree.getNodeSource(node), "\n") + 1 > 70) {
        return error.FunctionTooLong;
    }
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (0..tree.nodes.len) |index| {
        const child: Ast.Node.Index = @enumFromInt(index);
        const token = tree.nodeMainToken(child);
        if (token < first or token > last) continue;
        if (tree.fullWhile(child) != null) {
            if (!std.mem.eql(u8, path, "src/main.zig") or !std.mem.eql(u8, name, "start")) {
                return error.LoopNeedsFixedBound;
            }
            if (!std.mem.containsAtLeast(u8, tree.getNodeSource(body), 1, "unreachable")) {
                return error.EventLoopNeedsAssertion;
            }
        }
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, child) orelse continue;
        const callee = tree.getNodeSource(call.ast.fn_expr);
        if (std.mem.eql(u8, callee, name)) return error.Recursion;
        if (std.mem.eql(u8, callee, "assert") or std.mem.eql(u8, callee, "std.debug.assert")) {
            if (call.ast.params.len != 1) return error.InvalidAssertion;
            const predicate = call.ast.params[0];
            if (tree.nodeTag(predicate) == .bool_and) return error.CompoundAssertion;
            if (std.mem.eql(u8, tree.getNodeSource(predicate), "true")) {
                return error.VacuousAssertion;
            }
            metrics.assertions += 1;
        }
        try allocation(path, name, callee);
    }
}

fn signature(tree: *const Ast, proto: *const Ast.full.FnProto, path: []const u8) !void {
    assert(proto.name_token != null);
    assert(path.len > 0);
    if (proto.ast.callconv_expr != .none) return; // C callbacks prescribe positional arguments.
    const name = tree.tokenSlice(proto.name_token.?);
    if (std.mem.eql(u8, path, "src/state_machine.zig") and
        (std.mem.eql(u8, name, "prefetch") or std.mem.eql(u8, name, "commit")))
    {
        return;
    }
    var integers: [32][]const u8 = undefined;
    var count: u32 = 0;
    var iterator = proto.iterate(tree);
    for (0..32) |_| {
        const parameter = iterator.next() orelse return;
        const node = parameter.type_expr orelse continue;
        const kind = tree.getNodeSource(node);
        if (kind.len < 2 or (kind[0] != 'u' and kind[0] != 'i')) continue;
        for (kind[1..]) |byte| {
            if (!std.ascii.isDigit(byte)) break;
        } else {
            for (integers[0..count]) |previous| {
                if (std.mem.eql(u8, kind, previous)) return error.ParametersNeedNames;
            }
            integers[count] = kind;
            count += 1;
        }
    }
    return error.ParameterLimit;
}

fn allocation(path: []const u8, function_name: []const u8, callee: []const u8) !void {
    assert(function_name.len > 0);
    assert(callee.len > 0);
    if (!std.mem.startsWith(u8, path, "src/")) return;
    // These are the explicitly reviewed initialization/teardown boundaries. Simulator
    // construction and test fixtures are included; request evaluation is deliberately absent.
    for ([_][]const u8{
        "init", "deinit", "main", "start", "format", "sql", "create_cluster", "check",
    }) |allowed| {
        if (std.mem.eql(u8, function_name, allowed)) return;
    }
    const dot = std.mem.lastIndexOfScalar(u8, callee, '.') orelse return;
    for ([_][]const u8{
        "alloc",
        "alignedAlloc",
        "create",
        "dupe",
        "dupeZ",
        "allocPrint",
        "free",
        "destroy",
        "ensureTotalCapacity",
        "ensureUnusedCapacity",
        "append",
        "appendSlice",
        "realloc",
    }) |forbidden| {
        if (std.mem.eql(u8, callee[dot + 1 ..], forbidden)) return error.RuntimeAllocation;
    }
}

pub fn self_test(allocator: std.mem.Allocator) !void {
    const valid = "fn valid(a: u32) void { assert(a > 0); assert(a < 10); }";
    const metrics = try check(allocator, valid, "src/fixture.zig");
    assert(metrics.functions == 1);
    assert(metrics.assertions == 2);
    const fixtures = [_]struct { source: [:0]const u8, failure: anyerror }{
        .{ .source = "fn a() void { while (true) {} }", .failure = error.LoopNeedsFixedBound },
        .{ .source = "fn a() void { a(); }", .failure = error.Recursion },
        .{ .source = "fn a() void { assert(true); }", .failure = error.VacuousAssertion },
        .{ .source = "fn a() void { assert(x and y); }", .failure = error.CompoundAssertion },
        .{
            .source = "fn a() void { allocator.alloc(u8, 1); }",
            .failure = error.RuntimeAllocation,
        },
        .{ .source = "fn badName() void {}", .failure = error.FunctionSnakeCase },
        .{ .source = "fn a(x: u64, y: u64) void {}", .failure = error.ParametersNeedNames },
    };
    for (&fixtures) |*fixture| {
        _ = check(allocator, fixture.source, "src/fixture.zig") catch |err| {
            if (err == fixture.failure) continue;
            return err;
        };
        return error.StyleCheckerAcceptedInvalidFixture;
    }
    // Compile-time and test-block assertions must not inflate function assertion density.
    const excluded = try check(
        allocator,
        "comptime { assert(true); } test { assert(true); } fn empty() void {}",
        "src/fixture.zig",
    );
    if (excluded.assertions != 0 or excluded.functions != 1) {
        return error.DensityIncludesNonFunctions;
    }
}
