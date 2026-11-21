//! ink's termination and function-flow checks against inklecate: each story's
//! errors and warnings, as codes on the lines inklecate reports them. The expected messages
//! are inklecate's (ink v1.2.1, `dotnet reference/ink_harness_build/ink_harness.dll
//! warnings story.ink`), quoted above each case.

const std = @import("std");
const assert = std.debug.assert;
const grammar = @import("grammar.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const lower = @import("lower.zig");
const compile = @import("compile.zig");
const Code = resolve.Code;

pub const Expected = struct { code: Code, line: u32 };

/// The story's diagnostics: the resolution's, or with none, the lowering's.
pub fn expect_diagnostics(source: []const u8, expected: []const Expected) !void {
    assert(source.len > 0);
    assert(expected.len < 16);
    const gpa = std.testing.allocator;
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), parsed.diagnostics_count);
    var tree = try sema.build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    var resolution = try resolve.resolve(gpa, &parsed, &tree);
    defer resolution.deinit(gpa);
    var lowering = try lower.Lowering.init(gpa, &parsed, &tree, &resolution);
    defer lowering.deinit();
    const diagnostics = if (resolution.diagnostics.len > 0) resolution.diagnostics else lowered: {
        try lowering.generate_all();
        try lowering.finish_story();
        break :lowered lowering.diagnostics.items;
    };
    try std.testing.expectEqual(expected.len, diagnostics.len);
    for (expected, diagnostics) |want, diagnostic| {
        const offset = sema.object_offset(&parsed, &tree, diagnostic.object);
        const line: u32 = @intCast(std.mem.count(u8, parsed.source[0..offset], "\n") + 1);
        try std.testing.expectEqual(want.code, diagnostic.code);
        try std.testing.expectEqual(want.line, line);
    }
}

test "a single choice in a conditional without a divert is an error" {
    // ERROR: line 4: Choices with conditions should be written: '* {condition} choice'.
    // Otherwise, choices nested in conditionals or sequences need to explicitly divert
    // afterwards.
    try expect_diagnostics("-> k\n== k ==\n{true:\n  * one\n}\n-> END\n", &.{
        .{ .code = .conditional_choice_syntax, .line = 4 },
    });
    const source = "-> k\n== k ==\n{true:\n  * one\n}\n-> END\n";
    try std.testing.expectError(error.CompileFailed, compile.compile_source(
        std.testing.allocator,
        source,
    ));
}

test "choices in a conditional or a sequence need to divert afterwards" {
    // ERROR: line 5: Choices nested in conditionals or sequences need to explicitly divert
    // afterwards. (And the same on line 6.)
    try expect_diagnostics("-> k\n== k ==\n{true:\n  * one\n    a\n  * two\n}\n-> END\n", &.{
        .{ .code = .nested_choice_needs_divert, .line = 5 },
        .{ .code = .nested_choice_needs_divert, .line = 6 },
    });
    // ERROR: line 4: Choices nested in conditionals or sequences need to explicitly divert
    // afterwards.
    try expect_diagnostics("-> k\n== k ==\n{shuffle:\n- * x\n- y\n}\n-> END\n", &.{
        .{ .code = .nested_choice_needs_divert, .line = 4 },
    });
}

test "a loose end where a flow runs out is a warning, which doesn't stop compilation" {
    // WARNING: line 4: Apparent loose end exists where the flow runs out. ... When final
    //   tunnel to '-> t ->' returns it won't have anywhere to go.
    // WARNING: line 7: Apparent loose end exists where the flow runs out. ...
    // TODO: line 9: later (no loose-end warning after a TODO)
    // WARNING: line 13: Apparent loose end exists where the flow runs out. ...
    // WARNING: line 11: Apparent loose end exists where the flow runs out. ... Note that if
    //   you intend to enter 's1' next, you need to divert to it explicitly.
    const source = "-> k\n== k ==\nhello\n-> t ->\n== l ==\n* c\n  x\n== m ==\n" ++
        "TODO: later\n== n ==\nfirst\n= s1\nin s1\n== t ==\nt\n->->\n";
    try expect_diagnostics(source, &.{
        .{ .code = .loose_end, .line = 4 },
        .{ .code = .loose_end, .line = 7 },
        .{ .code = .loose_end, .line = 13 },
        .{ .code = .loose_end, .line = 11 },
    });
    var program = try compile.compile_source(std.testing.allocator, source);
    program.deinit(std.testing.allocator);
}

test "terminated weaves and flows have no termination diagnostics" {
    // inklecate: no errors or warnings.
    const source = "VAR v = 1\n-> k\n== k ==\n* a\n  -> END\n* b\n- (g) gathered\n" ++
        "{true:\n  * c\n  -> END\n}\n";
    try expect_diagnostics(source, &.{});
}

test "functions may not contain stitches, diverts or choices" {
    // ERROR: line 5: Functions may not contain diverts, but saw '-> k'
    // ERROR: line 6: Functions may not contain choices, but saw '* ContentList(a choice)...'
    const source = "{f()}\n-> END\n== function f ==\nhello\n-> k\n* a choice\n~ return 1\n" ++
        "== k ==\n-> END\n";
    try expect_diagnostics(source, &.{
        .{ .code = .function_has_divert, .line = 5 },
        .{ .code = .function_has_choice, .line = 6 },
    });
    // ERROR: line 4: Functions may not contain stitches, but saw 'inner' within the
    //   function 'f'
    // ERROR: line 1: f can't be diverted to. It can only be called as a function since it's
    //   been marked as such: 'f(...)'
    try expect_diagnostics("-> f\n== function f ==\n~ return 1\n= inner\nx\n", &.{
        .{ .code = .function_has_stitch, .line = 4 },
        .{ .code = .function_diverted_to, .line = 1 },
    });
}

test "returns are errors outside functions, and functions can't be stitches" {
    // ERROR: line 4: Return statements can only be used in knots that are declared as
    //   functions: == function k ==
    // ERROR: line 6: Return statements can only be used in knots that are declared as
    //   functions: == function s ==
    try expect_diagnostics("-> k\n== k ==\nhi\n~ return 2\n= s\n~ return 3\n", &.{
        .{ .code = .return_outside_function, .line = 4 },
        .{ .code = .return_outside_function, .line = 6 },
    });
    // ERROR: line 6: Return statements can only be used in knots that are declared as
    //   functions: == function k ==
    // ERROR: line 5: Functions cannot be stitches - i.e. they should be defined as
    //   '== function myFunc ==' rather than public to another knot.
    try expect_diagnostics("-> k\n== k ==\nhi\n-> END\n= function s\n~ return 1\n", &.{
        .{ .code = .return_outside_function, .line = 6 },
        .{ .code = .function_is_stitch, .line = 5 },
    });
}

test "-> DONE and -> END can't be divert-target values" {
    // ERROR: line 1: Can't use -> DONE or -> END as variable divert targets
    // (each once reached an unreachable in emission).
    const gpa = std.testing.allocator;
    const cases = [_]struct { source: []const u8, line: u32 }{
        .{ .source = "{-> END}\n", .line = 1 },
        .{ .source = "VAR v = -> DONE\n", .line = 1 },
        .{ .source = "~ temp x = -> DONE\n{x}\n", .line = 1 },
        .{ .source = "== function f\n~ return -> DONE\n", .line = 2 },
    };
    for (cases) |case| {
        try expect_diagnostics(case.source, &.{
            .{ .code = .done_or_end_as_value, .line = case.line },
        });
        try std.testing.expectError(error.CompileFailed, compile.compile_source(gpa, case.source));
    }
    // A plain divert to them is fine.
    var program = try compile.compile_source(gpa, "-> DONE\n");
    program.deinit(gpa);
}

test "a tunnel can't return onwards to END or DONE" {
    // inklecate throws a NullReferenceException on each; the error is ours. Each once
    // reached an unreachable in emission (generate_tunnel_onwards' divert target).
    const gpa = std.testing.allocator;
    const cases = [_]struct { source: []const u8, line: u32 }{
        .{ .source = "->-> END\n", .line = 1 },
        .{ .source = "->-> DONE\n", .line = 1 },
        .{ .source = "-> t ->\n== t\n->-> DONE\n", .line = 3 },
        .{ .source = "-> t ->\n-> END\n== t\nhi\n->-> END\n", .line = 5 },
    };
    for (cases) |case| {
        try expect_diagnostics(case.source, &.{
            .{ .code = .tunnel_onwards_to_end_or_done, .line = case.line },
        });
        try std.testing.expectError(error.CompileFailed, compile.compile_source(gpa, case.source));
    }
    // Returning onwards to a knot, or plainly, is fine.
    const valid = "-> t ->\n-> END\n== t\n->-> k\n== k\n-> END\n";
    var program = try compile.compile_source(gpa, valid);
    program.deinit(gpa);
}

test "a negated left operand of '?' is an error, as in ink" {
    // ERROR: line 3: Using 'not' or '!' here negates 'v' rather than the result of the '?'
    // or 'has' operator. You need to add parentheses around the (A ? B) expression.
    // (also lines 5 and 6: parentheses around `not v` don't count; `-v`, `not (v ? 1)` and
    // `!?` are fine.) Found by the differential swarm run (P16.3).
    const source = "VAR v = true\nLIST l = a, b\n{not v ? 1}\n{not (v ? 1)}\n{(not v) ? 1}\n" ++
        "~ temp x = !v has a\n{-v ? 1}\n{not v !? 1}\n";
    try expect_diagnostics(source, &.{
        .{ .code = .negated_has_operand, .line = 3 },
        .{ .code = .negated_has_operand, .line = 5 },
        .{ .code = .negated_has_operand, .line = 6 },
    });
    // ink's parser folds `not` of a literal into a Number first (WithInner), so a negated
    // literal is no negated operand: these compile in inklecate (PR #2 review).
    const literals = "LIST l = a, b\n{not true ? 1}\n{!1 ? 0}\n~ temp y = !0.5 has a\n{y}\n";
    var program = try compile.compile_source(std.testing.allocator, literals);
    program.deinit(std.testing.allocator);
}

test "a divert target of a variable is an error, as in ink" {
    // ERROR: line 3: Since 'k0' is a variable, it shouldn't be preceded by '->' here.
    // ERROR: line 3: When getting the TURNS_SINCE() of a variable target, remove the '->' -
    // i.e. it should just be TURNS_SINCE(k0)
    // ERROR: line 4: Since 'k0' is a variable, it shouldn't be preceded by '->' here.
    // Found by the limits swarm fuzz target, where lowering reached `unreachable` (P16.4).
    const source = "=== function f(y) ===\n~ temp k0 = 1\n~ temp t = TURNS_SINCE(-> k0)\n" ++
        "~ temp u = -> k0\n~ return t\n";
    try expect_diagnostics(source, &.{
        .{ .code = .variable_divert_target, .line = 3 },
        .{ .code = .turns_since_variable_target, .line = 3 },
        .{ .code = .variable_divert_target, .line = 4 },
    });
    try std.testing.expectError(error.CompileFailed, compile.compile_source(
        std.testing.allocator,
        source,
    ));
}
