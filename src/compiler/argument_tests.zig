//! ink's argument checks against inklecate: Divert.CheckArgumentValidity, the by-reference
//! and divert-parameter checks, the EXTERNAL argument count, and the built-ins' arities.
//! Each story's errors are codes on the lines inklecate reports them; the expected messages
//! are inklecate's (ink v1.2.1), quoted above each case. Valid calls compile.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("compile.zig");
const termination_tests = @import("termination_tests.zig");
const Code = @import("resolve.zig").Code;

const Case = struct { source: []const u8, code: Code, line: u32 };

/// Each case has its one error, and fails to compile.
fn expect_errors(cases: []const Case) !void {
    assert(cases.len > 0);
    const gpa = std.testing.allocator;
    for (cases) |case| {
        assert(!case.code.is_warning());
        try termination_tests.expect_diagnostics(case.source, &.{
            .{ .code = case.code, .line = case.line },
        });
        try std.testing.expectError(error.CompileFailed, compile.compile_source(gpa, case.source));
    }
}

/// Each source compiles without a diagnostic.
fn expect_valid(sources: []const []const u8) !void {
    assert(sources.len > 0);
    const gpa = std.testing.allocator;
    for (sources) |source| {
        try termination_tests.expect_diagnostics(source, &.{});
        var program = try compile.compile_source(gpa, source);
        program.deinit(gpa);
    }
}

test "a divert or call passes as many arguments as its target has parameters" {
    // ERROR: line 1: Divert to 't2' requires 1 arguments, but there weren't any passed to it
    // (twice), Function call to 'f' requires 1 arguments, but got 2, Function call to 'f'
    // requires 2 arguments, but only got 1, Divert to 't' requires 1 arguments, but got 2.
    try expect_errors(&.{
        .{ .source = "-> t2\n== t2(a)\n{a}\n-> DONE\n", .code = .wrong_argument_count, .line = 1 },
        .{
            .source = "-> t2 ->\nx\n-> DONE\n== t2(a)\n{a}\n->->\n",
            .code = .wrong_argument_count,
            .line = 1,
        },
        .{
            .source = "{f(1,2)}\n== function f(a)\n~ return a\n",
            .code = .wrong_argument_count,
            .line = 1,
        },
        .{
            .source = "{f(1)}\n== function f(a, b)\n~ return a\n",
            .code = .wrong_argument_count,
            .line = 1,
        },
        .{
            .source = "<- t(1, 2)\n-> DONE\n== t(a)\n{a}\n-> DONE\n",
            .code = .wrong_argument_count,
            .line = 1,
        },
        .{
            .source = "-> k.s\n== k\n= s(a)\n{a}\n-> DONE\n",
            .code = .wrong_argument_count,
            .line = 1,
        },
    });
    try expect_valid(&.{
        "-> k\n== k()\nhi\n-> DONE\n",
        "-> k.s(1)\n== k\n= s(a)\n{a}\n-> DONE\n",
        "{f()}\n== function f()\n~ return 1\n",
        "-> t(1) ->\n-> DONE\n== t(a)\n{a}\n->->\n",
    });
}

test "arguments go only to a knot or stitch with parameters, not into a divert target" {
    // ERROR: line 1: Divert target (k) doesn't take parameters
    // ERROR: line 1: Divert can't store arguments in a divert target variable
    // (`-> top(1)` to a label makes inklecate throw; ink's message would be "Divert target
    // needs to be a knot or stitch in order to pass arguments".)
    try expect_errors(&.{
        .{ .source = "-> k(1)\n== k\nhi\n-> DONE\n", .code = .flow_takes_no_parameters, .line = 1 },
        .{
            .source = "{-> k(1)}\n== k(a)\n-> DONE\n",
            .code = .arguments_in_divert_target,
            .line = 1,
        },
        .{ .source = "- (top) x\n-> top(1)\n", .code = .arguments_to_non_flow, .line = 2 },
    });
    try expect_valid(&.{"-> k()\n== k\nhi\n-> DONE\n"});
}

test "a ref parameter takes a variable's name" {
    // ERROR: line 2: Function call Expected variable name to pass by reference to 'ref a' but
    //   saw 5
    // ERROR: line 1: Function call can't pass a read count by reference. 'k' is a
    //   knot/stitch/label, but 'inc' requires the name of a VAR to be passed.
    try expect_errors(&.{
        .{
            .source = "VAR x = 1\n~ inc(5)\n== function inc(ref a)\n~ a++\n",
            .code = .reference_argument_not_variable,
            .line = 2,
        },
        .{
            .source = "~ inc(k)\n-> DONE\n== function inc(ref a)\n~ a++\n== k\n-> DONE\n",
            .code = .read_count_by_reference,
            .line = 1,
        },
    });
    try expect_valid(&.{
        "VAR x = 1\n~ inc(x)\n{x}\n== function inc(ref a)\n~ a++\n",
        "VAR g = 1\n~ a(g)\n{g}\n== function a(ref x)\n~ b(x)\n== function b(ref y)\n~ y++\n",
    });
}

test "a divert parameter is marked -> name and gets a divert target" {
    // ERROR: line 2: Since 'target' is used as a variable divert target (on line 3), it
    //   should be marked as: -> target
    // ERROR: line 1: Target 't' expects a divert target for the parameter named -> x but
    //   saw 5
    // ERROR: line 1: Divert Passing read count of 'k' instead of a divert target. You
    //   probably meant '-> k'
    try expect_errors(&.{
        .{
            .source = "-> t(d)\n== t(target)\n-> target\n== d\n-> DONE\n",
            .code = .divert_parameter_unmarked,
            .line = 2,
        },
        .{
            .source = "-> t(5)\n== t(-> x)\n-> x\n",
            .code = .divert_target_argument_expected,
            .line = 1,
        },
        .{
            .source = "-> t(k)\n== t(-> x)\n-> x\n== k\n-> DONE\n",
            .code = .read_count_instead_of_divert_target,
            .line = 1,
        },
    });
    try expect_valid(&.{
        "-> t(-> d)\n== t(-> target)\n-> target\n== d\n-> DONE\n",
        "VAR v = -> k\n-> t(v)\n== t(-> x)\n-> x\n== k\n-> DONE\n",
        "-> k(-> d)\n== k(-> n)\n-> j(n)\n== j(-> m)\n-> m\n== d\n-> DONE\n",
    });
}

test "an EXTERNAL is called with its own arity, and its fallback's" {
    // ERROR: line 2: Function call to 'e' requires 2 arguments, but only got 1
    // ERROR: line 2: Function call incorrect number of arguments sent to external function
    //   'e'. Expected 1 but got 2
    try expect_errors(&.{
        .{
            .source = "EXTERNAL e(a)\n{e(1)}\n== function e(a, b)\n~ return 1\n",
            .code = .wrong_argument_count,
            .line = 2,
        },
        .{ .source = "EXTERNAL e(a)\n{e(1,2)}\n", .code = .external_argument_count, .line = 2 },
        .{ .source = "{e(1)}\nEXTERNAL e()\n", .code = .external_argument_count, .line = 1 },
    });
    try expect_valid(&.{
        "EXTERNAL e(a)\n{e(1)}\n== function e(a)\n~ return 1\n",
        "EXTERNAL e(a)\n{e(1)}\n",
    });
}

test "each built-in takes its number of arguments" {
    // ERROR: line 1: POW should take 2 parameters; RANDOM should take 2 parameters: a
    //   minimum and a maximum integer; MIN, MAX ...; FLOOR should take 1 parameter; The
    //   CHOICE_COUNT() function shouldn't take any arguments; LIST_RANGE should take 3
    //   parameters - a list, a min and a max; The TURNS_SINCE() function should take one
    //   argument: a divert target ...; _ should take 1 parameter (inklecate throws on
    //   TURNS_SINCE(), SEED_RANDOM() and LIST_RANDOM(), which index a missing argument.)
    const sources = [_][]const u8{
        "{POW(2)}\n",         "{RANDOM(1,2,3)}\n", "{TURNS_SINCE()}\n",
        "{TURNS_SINCE(5)}\n", "{READ_COUNT()}\n",  "{MIN(1)}\n",
        "{MAX(1,2,3)}\n",     "{FLOOR()}\n",       "{CEILING(1,2)}\n",
        "{INT()}\n",          "{FLOAT()}\n",       "{LIST_MIN()}\n",
        "{LIST_MAX()}\n",     "{LIST_ALL()}\n",    "{LIST_COUNT()}\n",
        "{LIST_VALUE()}\n",   "{LIST_INVERT()}\n", "{CHOICE_COUNT(1)}\n",
        "{TURNS(2)}\n",       "~ SEED_RANDOM()\n", "{LIST_RANGE(1,2)}\n",
        "{LIST_RANDOM()}\n",  "~ _(1, 2)\n",
    };
    var cases: [sources.len]Case = undefined;
    for (sources, &cases) |source, *case| {
        case.* = .{ .source = source, .code = .builtin_argument_count, .line = 1 };
    }
    try expect_errors(&cases);
    // ERROR: line 1: RANDOM's minimum parameter should be an integer (maximum for the
    //   second); SEED_RANDOM's parameter should be an integer seed.
    // ERROR: line 2: Can currently only construct a list from one integer (or an empty list
    //   from a given list definition)
    try expect_errors(&.{
        .{ .source = "{RANDOM(1.5, 2)}\n", .code = .builtin_argument_not_integer, .line = 1 },
        .{ .source = "{RANDOM(1, -2.5)}\n", .code = .builtin_argument_not_integer, .line = 1 },
        .{ .source = "~ SEED_RANDOM(true)\n", .code = .builtin_argument_not_integer, .line = 1 },
        .{
            .source = "LIST l = a, b\n{l(1,2)}\n",
            .code = .list_from_more_than_one_value,
            .line = 2,
        },
    });
    try expect_valid(&.{
        "{POW(2,3)} {RANDOM(1,2)} {TURNS_SINCE(-> k)} {MIN(1,2)} {FLOOR(1.5)} {TURNS()}\n" ++
            "{CHOICE_COUNT()} {READ_COUNT(-> k)}\n-> DONE\n== k\n-> DONE\n",
        "~ temp x = 1\n{RANDOM(-1, 5)} {RANDOM(x, 2)}\n~ SEED_RANDOM(3)\n",
        "VAR x = -> k\n{TURNS_SINCE(x)}\n-> DONE\n== k\n-> DONE\n",
        "LIST l = a, b\nVAR x = (a)\n{LIST_RANGE(LIST_ALL(x), 1, 2)} {LIST_RANDOM(x)}\n" ++
            "{LIST_VALUE(x)} {LIST_INVERT(x)} {LIST_MIN(x)} {LIST_MAX(x)} {LIST_COUNT(x)}\n" ++
            "{INT(1.5)} {FLOAT(1)} {CEILING(1.2)} {l()} {l(1)}\n",
    });
}
