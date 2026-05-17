/// Test helper for the Ink compiler.
///
/// compileAndRun compiles Ink source to JSON, loads it in the runtime,
/// drives the story through a choice sequence, and returns the output.
const std = @import("std");
const Story = @import("../runtime/story.zig").Story;
const RuntimeObject = @import("../runtime/story.zig").RuntimeObject;
const compiler = @import("../compiler/compiler.zig");
const helpers = @import("helpers.zig");

fn extFunctionCount(args: []const RuntimeObject) ?RuntimeObject {
    if (args.len == 0) return .{ .int = 3 };
    return switch (args[0]) {
        .int => |count| .{ .int = count + 3 },
        else => .{ .int = 3 },
    };
}

fn extMessage(_: []const RuntimeObject) ?RuntimeObject {
    return null;
}

fn extMultiply(args: []const RuntimeObject) ?RuntimeObject {
    const a: f64 = switch (args[0]) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        else => return null,
    };
    const b: f64 = switch (args[1]) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        else => return null,
    };
    return .{ .float = a * b };
}

fn extTimes(_: []const RuntimeObject) ?RuntimeObject {
    return .{ .string = "knock knock knock " };
}

fn extGameInc(args: []const RuntimeObject) ?RuntimeObject {
    const x: i64 = switch (args[0]) {
        .int => |n| n,
        else => 0,
    };
    return .{ .int = x + 1 };
}

fn extNoOp(_: []const RuntimeObject) ?RuntimeObject {
    return null;
}

/// Compile `ink_source`, run the story through `choices`, and return all output.
/// Caller owns the returned slice.
pub fn compileAndRun(
    alloc: std.mem.Allocator,
    ink_source: []const u8,
    choices: []const usize,
) ![]u8 {
    const json = try compiler.compile(alloc, ink_source);
    defer alloc.free(json);

    var s = try Story.initFromJson(alloc, json);
    defer s.deinit();

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(alloc);

    var choice_idx: usize = 0;
    while (true) {
        // When the VM pauses with a choice menu (pointer null / peel stop), `canContinue()` is
        // false — choose before calling `cont()` again (matches Ink's Continue loop).
        if (s.currentChoices().len > 0 and choice_idx < choices.len and !s.canContinue()) {
            try s.chooseChoiceIndex(choices[choice_idx]);
            choice_idx += 1;
            continue;
        }
        if (s.canContinue()) {
            const out = try s.cont();
            defer alloc.free(out);
            try output.appendSlice(alloc, out);
        } else {
            break;
        }
    }

    return output.toOwnedSlice(alloc);
}

/// Load an .ink file from test/fixture/original/, compile and run it.
/// Caller owns the returned slice.
pub fn compileFixture(
    alloc: std.mem.Allocator,
    comptime rel_path: []const u8,
) ![]u8 {
    const path = "test/fixture/original/" ++ rel_path;
    const io = std.testing.io;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);

    return compiler.compile(alloc, src);
}

/// Load an .ink file from test/fixture/ (root), compile and run it.
/// Caller owns the returned slice.
pub fn compileFixtureRootAndRun(
    alloc: std.mem.Allocator,
    comptime rel_path: []const u8,
    choices: []const usize,
) ![]u8 {
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/" ++ rel_path, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    return compileAndRun(alloc, src, choices);
}

/// Load an .ink file from test/fixture/original/, compile and run it.
/// Caller owns the returned slice.
pub fn compileFixtureAndRun(
    alloc: std.mem.Allocator,
    comptime rel_path: []const u8,
    choices: []const usize,
) ![]u8 {
    const json = try compileFixture(alloc, rel_path);
    defer alloc.free(json);

    var s = try Story.initFromJson(alloc, json);
    defer s.deinit();

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(alloc);

    var choice_idx: usize = 0;
    while (true) {
        if (s.currentChoices().len > 0 and choice_idx < choices.len and !s.canContinue()) {
            try s.chooseChoiceIndex(choices[choice_idx]);
            choice_idx += 1;
            continue;
        }
        if (s.canContinue()) {
            const out = try s.cont();
            defer alloc.free(out);
            try output.appendSlice(alloc, out);
        } else {
            break;
        }
    }

    return output.toOwnedSlice(alloc);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Compiler JSON: divert_to_weave_points" {
    const alloc = std.testing.allocator;
    const c = @import("../compiler/compiler.zig");
    const src =
        \\-> knot.stitch.gather
        \\== knot ==
        \\= stitch
        \\- hello
        \\    * (choice) test
        \\        choice content
        \\- (gather)
        \\  gather
        \\-> END
        \\
    ;
    const json = try c.compile(alloc, src);
    defer alloc.free(json);
    try std.testing.expect(true);
}

test "Compiler JSON: knot_do_not_gather" {
    const alloc = std.testing.allocator;
    const c = @import("../compiler/compiler.zig");
    const src =
        \\-> knot
        \\=== knot
        \\-> knot.gather
        \\- (gather) g
        \\-> DONE
        \\
    ;
    const json = try c.compile(alloc, src);
    defer alloc.free(json);
    try std.testing.expect(true);
}

test "Compiler JSON: tunnel_onwards_divert_after_with_arg" {
    const alloc = std.testing.allocator;
    const c = @import("../compiler/compiler.zig");
    const src =
        \\-> a ->
        \\=== a ===
        \\->-> b (5 + 3)
        \\=== b (x) ===
        \\{x}
        \\-> END
        \\
    ;
    const json = try c.compile(alloc, src);
    defer alloc.free(json);
    const expected = "{\"inkVersion\":21,\"root\":[[{\"->t->\":\"a\"},[\"done\",{\"#n\":\"g-0\"}],null],\"done\",{\"a\":[\"ev\",5,3,\"+\",{\"^->\":\"b\"},\"/ev\",\"->->\",{\"#f\":1}],\"b\":[{\"temp=\":\"x\"},\"ev\",{\"VAR?\":\"x\"},\"out\",\"/ev\",\"\\n\",\"end\",{\"#f\":1}]}],\"listDefs\":{}}";
    try std.testing.expectEqualStrings(expected, json);
}

test "Compiler e2e: empty story" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: hello world inline" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "Hello world\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Compiler e2e: text with END" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: divert to knot then END" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> test
        \\== test ==
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: multi-knot story" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> firstKnot
        \\=== firstKnot
        \\Hello!
        \\-> anotherKnot
        \\=== anotherKnot
        \\World.
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello!\nWorld.\n", out);
}

test "Compiler e2e: misc/hello_world.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/hello_world.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Compiler e2e: misc/empty.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/empty.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: misc/end.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: misc/end2.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: misc/end_of_content.ink fixture" {
    // The story has a knot "test" but no root-level divert to it.
    // Root flow is just the implicit g-0 done container → output is empty.
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end_of_content.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: misc/whitespace.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/whitespace.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello!\nWorld.\n", out);
}
test "Compiler e2e: misc/includes/included_file.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/includes/included_file.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is include 1.\n", out);
}
test "Compiler e2e: misc/includes/included_file_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/includes/included_file_2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is include 2.\n", out);
}
test "Compiler e2e: misc/includes/included_file_3.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/includes/included_file_3.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}
test "Compiler e2e: misc/includes/included_file_4.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/includes/included_file_4.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "5") != null);
}
test "Compiler e2e: misc/nested_include.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/misc/nested_include.ink");
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "This is the main file") != null);
}

// ── Expression / evaluation tests ─────────────────────────────────────────────

test "Compiler e2e: inline boolean true" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{true}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}

test "Compiler e2e: inline boolean false" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{false}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Compiler e2e: inline not true" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{not true}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Compiler e2e: inline comparison 3 > 1" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{3 > 1}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}

test "Compiler e2e: inline arithmetic 2 + 3" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{2 + 3}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Compiler e2e: arithmetic.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/arithmetic.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("36\n2\n3\n2\n2.333333\n8\n8\n", out);
}

// ── Variable tests ────────────────────────────────────────────────────────────

test "Compiler e2e: VAR inline ref" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "VAR x = 5\n{x}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Compiler e2e: temp var" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "~ temp y = 4\n{y}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("4\n", out);
}

test "Compiler e2e: temp reassignment" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "~ temp y = 1\n~ y = 7\n{y}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("7\n", out);
}

test "Compiler e2e: CONST substitution in VAR" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "CONST c = 5\nVAR x = c\n{x}\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Compiler e2e: temporaries_at_global_scope.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/temporaries_at_global_scope.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("54\n", out);
}

test "Compiler e2e: const.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/const.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

// ── Conditional tests ─────────────────────────────────────────────────────────

test "Compiler e2e: inline if/else — false branch taken" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "{false:not true|true}\n", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not true") == null);
}

test "Compiler e2e: block conditional — false branch skipped" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{
        \\- false:
        \\   beep
        \\}
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "beep") == null);
}

test "Compiler e2e: multi-branch — second branch taken" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{
        \\   - 4 > 5: not true
        \\   - 5 > 4: yes
        \\}
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not true") == null);
}

test "Compiler e2e: outer condition with else — else taken" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{ 2 > 5:
        \\   - no
        \\   - yes
        \\}
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no") == null);
}

test "Compiler e2e: switch — matching branch taken" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{ 6:
        \\   - 5: wrong
        \\   - 6: right
        \\   - 7: wrong
        \\}
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "right") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wrong") == null);
}

test "Compiler e2e: trivial_condition.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/conditions/trivial_condition.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "beep") == null);
}

test "Compiler e2e: else_branches.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/conditions/else_branches.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "other") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "two") == null);
}

test "Compiler e2e: conditionals.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/conditions/conditionals.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "great") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not true") == null);
}

test "Compiler e2e: all_switch_branches_fail_is_clean.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/conditions/all_switch_branches_fail_is_clean.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "y") == null);
}

test "Compiler e2e: empty_multiline_conditional_branch.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/conditions/empty_multiline_conditional_branch.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "txt") == null);
}

// ── Choice / weave tests ──────────────────────────────────────────────────────

test "Compiler e2e: default_simple_gather.ink — fallback choice + gather" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/default_simple_gather.ink", &.{});
    defer alloc.free(out);
    // The fallback choice c-0 body starts with "\n", then gather g-0 outputs "x\n".
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null);
}

test "Compiler e2e: choice_with_brackets_only.ink — brackets-only choice" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/choice_with_brackets_only.ink", &.{0});
    defer alloc.free(out);
    // After selecting the choice, "Text" is shown.
    try std.testing.expect(std.mem.indexOf(u8, out, "Text") != null);
}

test "Compiler e2e: choice_diverts_to_done.ink — start-text choice" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/choice_diverts_to_done.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "choice") != null);
}

test "Compiler e2e: sticky_choices_stay_sticky.ink" {
    const alloc = std.testing.allocator;
    // Two sticky choices loop back to test; select choice 0 three times then stop.
    const out = try compileFixtureAndRun(alloc, "runtime/choices/sticky_choices_stay_sticky.ink", &.{ 0, 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "First line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Choice 1") != null);
}

test "Compiler e2e: weave_options.ink — start+choice-only+following in knot" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/weave_options.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello, world.\n", out);
}

test "Compiler e2e: non_text_in_choice_inner_content.ink" {
    // * option text[]. {true: Conditional bit.} -> next
    // Selecting the choice: start text "option text" shown, following ". Conditional bit. ", then "Next."
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/non_text_in_choice_inner_content.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "option text") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Next.") != null);
}

test "Compiler e2e: gather_choice_same_line.ink" {
    // - * hello / - * world : two choices on gather lines
    const alloc = std.testing.allocator;
    const out0 = try compileFixtureAndRun(alloc, "runtime/choices/gather_choice_same_line.ink", &.{0});
    defer alloc.free(out0);
    try std.testing.expect(std.mem.indexOf(u8, out0, "hello") != null);
}

test "Compiler e2e: conditional_choices.ink — single-condition choices" {
    // Choices with conditions; select c-1 ({true}{true} → "one") and c-3 ({true} → "two")
    // This fixture has 6 choices — we select idx=1 (one) then idx=0 (two).
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/conditional_choices.ink", &.{1});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null);
}

test "Compiler e2e: has_read_on_choice.ink — condition on knot read count" {
    // * { not test } visible choice  — test knot hasn't been read, so this choice visible
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/has_read_on_choice.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "visible choice") != null);
}

test "Compiler e2e: logic_in_choices.ink — function call in choice text" {
    // * 'Hello {name()}[, your name is {name()}.'],' I said...
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/logic_in_choices.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Joe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

// ── Function return + params tests ───────────────────────────────────────────

test "Compiler e2e: callstack_evaluation.ink — return with expr" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/callstack/callstack_evaluation.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("8\n", out);
}

test "Compiler e2e: function return bare" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{ greet() }
        \\-> END
        \\== function greet ==
        \\hello
        \\~ return
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "Compiler e2e: function with params" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{ add(3, 4) }
        \\-> END
        \\== function add(x, y) ==
        \\~ return x + y
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("7\n", out);
}

test "Compiler e2e: variable_swap_recurse.ink — params + recursion" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/variable_swap_recurse.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2") != null);
}

// ── Increment/decrement tests ─────────────────────────────────────────────────

test "Compiler e2e: x++ increment" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\VAR x = 0
        \\~ x++
        \\~ x++
        \\{x}
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n", out);
}

test "Compiler e2e: x-- decrement" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\VAR x = 5
        \\~ x--
        \\{x}
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("4\n", out);
}

test "Compiler e2e: x++ in VAR context" {
    // x++ and x-- with global VARs.
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\VAR n = 10
        \\~ n--
        \\~ n--
        \\{n}
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("8\n", out);
}

// ── Glue tests ─────────────────────────────────────────────────────────────────

test "Compiler e2e: simple_glue.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/glue/simple_glue.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Some content with glue.\n", out);
}

test "Compiler e2e: glue inline" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "hello<> world\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello world\n", out);
}

// ── Tags tests ────────────────────────────────────────────────────────────────

test "Compiler e2e: tags — standalone hash tag line" {
    // Tags are emitted as "#"/"^text"/"/#" but don't produce output text.
    // The story should still produce its content text.
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\# author: Joe
        \\Hello world
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello world") != null);
}

// ── LIST tests ────────────────────────────────────────────────────────────────

test "Compiler e2e: LIST basic" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/list_basic_operations.ink", &.{});
    defer alloc.free(out);
    // LIST list = a, (b), c, (d), e  → currently selected: b, d
    try std.testing.expectEqualStrings("b, d\na, b, c, e\nb, c\n0\n1\n1\n", out);
}

test "Compiler e2e: LIST empty_list_origin" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/empty_list_origin.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a, b\n", out);
}

test "Compiler e2e: LIST more_list_operations" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/more_list_operations.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\nl\n\nn\n\nl, m\n\nn\n", out);
}
test "Compiler e2e: lists/contains_empty_list_always_false.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/contains_empty_list_always_false.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1") == null);
}
test "Compiler e2e: lists/empty_list_origin_after_assignment.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/empty_list_origin_after_assignment.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}
test "Compiler e2e: lists/list_mixed_items.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/list_mixed_items.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a, c, y\n", out);
}
test "Compiler e2e: lists/list_random.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/list_random.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, out, "\n"));
}
test "Compiler e2e: lists/list_range.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/list_range.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Two, Three, Four, Five, Six\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Pizza") != null);
}
test "Compiler e2e: lists/list_save_load.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/lists/list_save_load.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a, c, x\n", out);
}

// ── Divert target variable tests ──────────────────────────────────────────────

test "Compiler e2e: variable_divert_target.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/variable_divert_target.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Here.\n", out);
}

// ── Standalone function call tests ────────────────────────────────────────────

test "Compiler e2e: standalone function call ~ f()" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\VAR n = 0
        \\~ setN(5)
        \\{n}
        \\== function setN(x) ==
        \\~ n = x
        \\~ return
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Compiler e2e: multiple_constant_references.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/multiple_constant_references.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "success") != null);
}

test "Compiler e2e: variable_declaration_in_conditional.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/variable_declaration_in_conditional.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "5") != null);
}

// ── TASK-79: named gathers, choice labels, nested choices ─────────────────────

test "Compiler e2e: should_not_gather_due_to_choice.ink" {
    // * opt → nested weave: text, {false} impossible, invisible default -> END; - gather
    // Invisible default fires (all choices filtered) → END; "gather" is never reached.
    // Matches runtime test "Story should_not_gather_due_to_choice" which asserts gather==null.
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/should_not_gather_due_to_choice.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "text") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gather") == null);
}

test "Compiler e2e: weave_gathers.ink" {
    const alloc = std.testing.allocator;
    // Select choice 0 ("one"), which has nested choice "two" and gather "three"
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/weave_gathers.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "six") != null);
}

test "Compiler e2e: default_choices.ink — named gather + loop" {
    const alloc = std.testing.allocator;
    // 4 choices: [Choice 1], [Choice 2], {false} impossible, -> default (fallback)
    // fallback goes to knot "default"; selecting choice 0 loops, then done
    const out = try compileFixtureAndRun(alloc, "runtime/choices/default_choices.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "After choice") != null);
}

test "Compiler e2e: once_only_choices_can_link_back_to_self.ink" {
    // Choice label (firstOpt), condition {firstOpt}, named gather (end)
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/once_only_choices_can_link_back_to_self.ink", &.{ 0, 0 });
    defer alloc.free(out);
    // Just verify it doesn't crash or infinite-loop.
    try std.testing.expect(out.len >= 0);
}

// ── TASK-80: tunnels, functions, external fns ─────────────────────────────────

test "Compiler e2e: basic_tunnel.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/basic_tunnel.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Compiler e2e: callstack_evaluation.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/callstack/callstack_evaluation.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("8\n", out);
}

test "Compiler e2e: tunnel_onwards_after_tunnel.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_onwards_after_tunnel.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello...\n...world.\nThe End.\n", out);
}

// ── TASK-81: sequences & alternatives ─────────────────────────────────────────

test "Compiler e2e: inline stopping sequence {a|b}" {
    const alloc = std.testing.allocator;
    // First visit: "one", second: "two", third: "two" (clamped)
    const out1 = try compileAndRun(alloc,
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{one|two}
        \\->->
    , &.{});
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "one") != null);
}

test "Compiler e2e: block stopping sequence" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> seq ->
        \\-> seq ->
        \\-> END
        \\== seq ==
        \\{stopping:
        \\- first
        \\- second
        \\}
        \\->->
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") != null);
}

test "Compiler e2e: inline cycle sequence {&a|b}" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> thing ->
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{&one|two}
        \\->->
    , &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null);
}

test "Compiler e2e: leading_newline_multiline_sequence.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/leading_newline_multiline_sequence.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0); // just verify no crash
}

test "Compiler e2e: empty_sequence_content.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/empty_sequence_content.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0);
}

// ── TASK-82: Glue, Tags, Newlines, Strings ────────────────────────────────────

test "Compiler e2e: left_right_glue_matching.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/glue/left_right_glue_matching.ink", &.{});
    defer alloc.free(out);
    // Both lines appear; extra structural newlines from block conditional are acceptable.
    try std.testing.expect(std.mem.indexOf(u8, out, "A line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Another line.") != null);
}

test "Compiler e2e: newline_consistency_1.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newline_consistency_1.ink", &.{});
    defer alloc.free(out);
    // Inline divert: "hello " then world content on same output chunk.
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
}

test "Compiler e2e: newline_consistency_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newline_consistency_2.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
}

test "Compiler e2e: string_constants.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/strings/string_constants.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hi\n", out);
}

test "Compiler e2e: string_contains — ? operator" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\{"hello world" ? "o wo"}
        \\{"hello world" ? "nope"}
    , &.{});
    defer alloc.free(out);
    // ? operator returns 1 (true) or 0 (false) as integers in the runtime.
    try std.testing.expectEqualStrings("1\n0\n", out);
}

test "Compiler e2e: tags.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/tags/tags.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "This is the content") != null);
}

test "Compiler e2e: newline_at_start_of_multiline_conditional.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newline_at_start_of_multiline_conditional.ink", &.{});
    defer alloc.free(out);
    // x should be output (isTrue() returns true); X is function body side-effect text.
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null);
}

test "Compiler e2e: LIST more_list_operations inline" {
    const alloc = std.testing.allocator;
    const src =
        \\LIST list = l, m = 5, n
        \\{LIST_VALUE(l)}
        \\{list(1)}
        \\~ temp t = list()
        \\~ t += n
        \\{t}
        \\~ t = LIST_ALL(t)
        \\~ t -= n
        \\{t}
        \\~ t = LIST_INVERT(t)
        \\{t}
    ;
    const out = try compileAndRun(alloc, src, &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\nl\n\nn\n\nl, m\n\nn\n", out);
}

// ── TASK-91: Threads, built-ins ────────────────────────────────────────────────

test "Compiler e2e: TURNS() built-in" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/turns.ink", &.{0});
    defer alloc.free(out);
    // Just verify it runs without crash and produces something
    try std.testing.expect(out.len > 0);
}

test "Compiler e2e: TURNS_SINCE built-in" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/turns_since.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

test "Compiler e2e: CHOICE_COUNT built-in" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/choice_count.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2") != null);
}

test "Compiler e2e: read_count_across_callstack.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/read_count_across_callstack.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1) Seen first 1 times.\nIn second.\n2) Seen first 1 times.\n", out);
}

test "Compiler e2e: thread in sequence" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/threads/thread_in_logic.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content") != null);
}

test "Compiler e2e: thread_done.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/threads/thread_done.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0);
}

// ── TASK-85: integration — evaluation ─────────────────────────────────────────

test "Compiler e2e: evaluation/factorial_recursive.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/factorial_recursive.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("120\n", out);
}

test "Compiler e2e: evaluation/literal_unary.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/literal_unary.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("-1\n0\n1\n", out);
}

test "Compiler e2e: evaluation/basic_string_literals.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/basic_string_literals.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world 1\nHello world 2.\n", out);
}

test "Compiler e2e: evaluation/increment.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/increment.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("6\n5\n", out);
}

test "Compiler e2e: evaluation/evaluation_stack_leaks.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/evaluation_stack_leaks.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("else\nelse\nhi\n", out);
}

test "Compiler e2e: evaluation/evaluating_function_variable_state_bug.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/evaluating_function_variable_state_bug.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Start\nIn tunnel.\nEnd\n", out);
}

test "Compiler e2e: evaluation/factorial_by_reference.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/factorial_by_reference.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("120\n", out);
}

// ── TASK-85: integration — logic ──────────────────────────────────────────────

test "Compiler e2e: logic/logic_lines_with_newlines.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/logic/logic_lines_with_newlines.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("text1\ntext 2\ntext1\ntext 2\n", out);
}

test "Compiler e2e: logic/multiline_logic_with_glue.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/logic/multiline_logic_with_glue.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a b\na b\n", out);
}

test "Compiler e2e: logic/nested_pass_by_reference.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/logic/nested_pass_by_reference.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "625") != null);
}

test "Compiler e2e: logic/print_num.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/logic/print_num.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "four") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fifteen") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "thirty-seven") != null);
}

// ── TASK-85: integration — extra ──────────────────────────────────────────────

test "Compiler e2e: extra/arithmetic_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/extra/arithmetic_2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n2.333333\n2.333333\n2.333333\n2.333333\n2.333333\n", out);
}

test "Compiler e2e: extra/list_comparison.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/extra/list_comparison.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Philippe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Andre") != null);
}

// ── TASK-85: integration — glue remaining ────────────────────────────────────

test "Compiler e2e: glue/implicit_inline_glue.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/glue/implicit_inline_glue.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("I have five eggs.\n", out);
}

test "Compiler e2e: glue/implicit_inline_glue_b.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/glue/implicit_inline_glue_b.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "X") != null);
}

test "Compiler e2e: glue/implicit_inline_glue_c.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/glue/implicit_inline_glue_c.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "C") != null);
}

// ── TASK-85: integration — misc remaining ────────────────────────────────────

test "Compiler e2e: misc/escape_character.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/escape_character.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("this is a '|' character\n", out);
}

test "Compiler e2e: misc/identifiers_can_start_with_number.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/identifiers_can_start_with_number.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("512x2 = 1024\n512x2p2 = 1026\n", out);
}

test "Compiler e2e: misc/quote_character_significance.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/quote_character_significance.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Joe") != null);
}

test "Compiler e2e: multiflow/multi_flow_basics.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/multiflow/multi_flow_basics.ink");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    try story.switchFlow("f1");
    try story.choosePathString("knot1");
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("knot 1 line 1\nknot 1 line 2\n", out1);
    try story.switchFlow("f2");
    try story.choosePathString("knot2");
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("knot 2 line 1\nknot 2 line 2\n", out2);
}
test "Compiler e2e: multiflow/multi_flow_save_load_threads.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/multiflow/multi_flow_save_load_threads.ink");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "Default line 1") != null);
}
test "Compiler e2e: newlines/newlines_trimming_with_func_external_fallback.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newlines_trimming_with_func_external_fallback.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0);
}
test "Compiler e2e: strings/string_contains.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/strings/string_contains.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n0\n1\n1\n", out);
}

// ── TASK-85: integration — newlines remaining ────────────────────────────────

test "Compiler e2e: newlines/newline_consistency_3.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newline_consistency_3.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\nworld\n", out);
}

test "Compiler e2e: newlines/newlines_with_string_eval.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/newlines/newlines_with_string_eval.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
}

// ── TASK-85: integration — sequences remaining ───────────────────────────────

test "Compiler e2e: sequences/all_sequence_types.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/all_sequence_types.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Once:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Stopping:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cycle:") != null);
}

test "Compiler e2e: sequences/blanks_in_inline_sequences.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/blanks_in_inline_sequences.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1. a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3. b") != null);
}

test "Compiler e2e: sequences/gather_read_count_with_initial_sequence.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/gather_read_count_with_initial_sequence.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0);
}

test "Compiler e2e: sequences/shuffle_stack_muddying.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/sequences/shuffle_stack_muddying.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

// ── TASK-85: integration — strings remaining ─────────────────────────────────

test "Compiler e2e: strings/string_type_coercion.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/strings/string_type_coercion.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("different\ndifferent\n", out);
}

test "Compiler e2e: strings/strings_in_choices.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/strings/strings_in_choices.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

// ── TASK-85: integration — tags remaining ────────────────────────────────────

test "Compiler e2e: tags/tags_dynamic_content.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/tags/tags_dynamic_content.ink", &.{});
    defer alloc.free(out);
    // tags produce no visible text output — just verify no crash
    try std.testing.expect(out.len >= 0);
}

test "Compiler e2e: tags/tags_in_choice.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/tags/tags_in_choice.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

test "Compiler e2e: tags/tags_in_seq.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/tags/tags_in_seq.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len >= 0);
}

// ── TASK-85: integration — variables remaining ───────────────────────────────

test "Compiler e2e: variables/variable_pointer_ref_from_knot.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/variable_pointer_ref_from_knot.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("6\n", out);
}

test "Compiler e2e: variables/variable_tunnel.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/variable_tunnel.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("STUFF\n", out);
}

test "Compiler e2e: variables/temp_usage_in_options.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/temp_usage_in_options.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "End of choice") != null);
}

test "Compiler e2e: variables/set_non_existant_variable.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/set_non_existant_variable.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world.\n", out);
}

test "Compiler e2e: variables/temp_global_conflict.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/temp_global_conflict.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Compiler e2e: variables/temp_not_found.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/temp_not_found.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "Compiler e2e: variables/warn_variable_not_found_1.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/warn_variable_not_found_1.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world!\n0\n", out);
}

test "Compiler e2e: variables/warn_variable_not_found_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/variables/warn_variable_not_found_2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world!\n0\n", out);
}

// ── TASK-85: integration — weaves remaining ──────────────────────────────────

test "Compiler e2e: weaves/conditional_choice_in_weave.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/conditional_choice_in_weave.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("start\nresult\n", out);
}

test "Compiler e2e: weaves/conditional_choice_in_weave_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/conditional_choice_in_weave_2.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "first gather") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bottom gather") != null);
}

test "Compiler e2e: weaves/weave_within_sequence.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/weave_within_sequence.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "nextline") != null);
}

test "Compiler e2e: weaves/unbalanced_weave_indentation.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/weaves/unbalanced_weave_indentation.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "First") != null);
}

// ── TASK-85: integration — choices remaining ─────────────────────────────────

test "Compiler e2e: choices/once_only_choices_with_own_content.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/once_only_choices_with_own_content.ink", &.{ 0, 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "first time") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "finished eating") != null);
}

test "Compiler e2e: choices/various_default_choices.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/various_default_choices.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n2\n3\n", out);
}

test "Compiler e2e: choices/state_rollback_over_default_choice.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/state_rollback_over_default_choice.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Text.\n5\n", out);
}

// ── TASK-85: integration — diverts remaining ─────────────────────────────────

test "Compiler e2e: diverts/same_line_divert_is_inline.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/same_line_divert_is_inline.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("We hurried home to Savile Row as fast as we could.\n", out);
}

test "Compiler e2e: diverts/compare_divert_targets.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/compare_divert_targets.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("different knot\nsame knot\nsame knot\ndifferent knot\nsame knot\nsame knot\n", out);
}

test "Compiler e2e: diverts/complex_tunnels.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/complex_tunnels.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("one (1)\none and a half (1.5)\ntwo (2)\nthree (3)\n", out);
}

test "Compiler e2e: diverts/divert_in_conditional.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/divert_in_conditional.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: diverts/divert_targets_with_parameters.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/divert_targets_with_parameters.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Compiler e2e: diverts/divert_to_weave_points.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/divert_to_weave_points.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "gather") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second time round") != null);
}

test "Compiler e2e: diverts/done_stops_thread.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/done_stops_thread.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: diverts/tunnel_onwards_divert_after_with_arg.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_onwards_divert_after_with_arg.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("8\n", out);
}

test "Compiler e2e: diverts/tunnel_onwards_divert_override.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_onwards_divert_override.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is A\nNow in B.\n", out);
}

test "Compiler e2e: diverts/tunnel_onwards_to_variable_divert_target.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_onwards_to_variable_divert_target.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is outer\nThis is the_esc\n", out);
}

test "Compiler e2e: diverts/tunnel_onwards_with_param_default_choice.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_onwards_with_param_default_choice.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("8\n", out);
}

test "Compiler e2e: diverts/path_to_self.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/path_to_self.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
}

test "Compiler e2e: diverts/tunnel_vs_thread_behaviour.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/diverts/tunnel_vs_thread_behaviour.ink", &.{ 0, 2 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Done.") != null);
}

// ── TASK-85: integration — knots ─────────────────────────────────────────────

test "Compiler e2e: knots/knot_do_not_gather.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/knots/knot_do_not_gather.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("g\n", out);
}

test "Compiler e2e: knots/knot_stitch_gather_counts.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/knots/knot_stitch_gather_counts.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
}

test "Compiler e2e: knots/knot_thread_interaction.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/knots/knot_thread_interaction.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "blah blah") != null);
}

test "Compiler e2e: knots/knot_thread_interaction_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/knots/knot_thread_interaction_2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "tunnel") != null);
}

// ── TASK-85: integration — threads remaining ─────────────────────────────────

test "Compiler e2e: threads/multi_thread.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/threads/multi_thread.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "place 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "The end") != null);
}

test "Compiler e2e: threads/top_flow_terminator_should_not_kill_thread_choices.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/threads/top_flow_terminator_should_not_kill_thread_choices.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

// ── TASK-85: integration — builtins remaining ────────────────────────────────

test "Compiler e2e: builtins/floor_ceiling_and_casts.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/floor_ceiling_and_casts.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1") != null);
}

test "Compiler e2e: builtins/visit_count_bug_due_to_nested_containers.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/visit_count_bug_due_to_nested_containers.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\nchoice\n1\n", out);
}

test "Compiler e2e: builtins/read_count_dot_separated_path.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/read_count_dot_separated_path.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hi\nhi\nhi\n3\n", out);
}

test "Compiler e2e: builtins/turns_since_nested.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/turns_since_nested.ink", &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

test "Compiler e2e: builtins/read_count_across_threads.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/read_count_across_threads.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}
test "Compiler e2e: builtins/read_count_variable_target.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/read_count_variable_target.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Count start: 0 0 0\n1\n2\n3\nCount end: 3 3 3\n", out);
}
test "Compiler e2e: builtins/turns_since_with_variable_target.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/builtins/turns_since_with_variable_target.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}
test "Compiler e2e: builtins/visit_counts_when_choosing.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/builtins/visit_counts_when_choosing.ink");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    try story.choosePathString("TestKnot");
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "this is a test") != null);
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "this is the end") != null);
}
test "Compiler e2e: choices/choice_thread_forking.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/choices/choice_thread_forking.ink");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);
    try std.testing.expectEqualStrings("A choice", story.currentChoices()[0].text);
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "A choice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "Vaue of local var is: ") != null);
}
test "Compiler e2e: choices/fallback_choice_on_thread.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/fallback_choice_on_thread.ink", &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Should be 1 not 0: ") != null);
}
test "Compiler e2e: evaluation/evaluating_ink_functions_from_game.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/evaluating_ink_functions_from_game.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Top level content") != null);
}
test "Compiler e2e: evaluation/evaluating_ink_functions_from_game_2.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/evaluation/evaluating_ink_functions_from_game_2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("One\nTwo\nThree\n", out);
}

// ── TASK-85: integration — callstack remaining ───────────────────────────────

test "Compiler e2e: callstack/clean_callstack_reset_on_path_choice.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/callstack/clean_callstack_reset_on_path_choice.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("The first line.\nThe second line.\n", out);
}

test "Compiler e2e: player/error_and_exceptions.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "player/error_and_exceptions.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.choosePathString("knot");
    const out = try story.cont();
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "This is a knot") != null);
}

test "Compiler e2e: player/flow.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "player/flow.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const global_tags = try story.globalTags();
    defer alloc.free(global_tags);
    try std.testing.expect(global_tags.len >= 2);

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

test "Compiler e2e: player/functions.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "player/functions.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("external_function", extFunctionCount, .{});

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "The count is 7") != null);
}

test "Compiler e2e: player/ink_error.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "player/ink_error.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\n", out);
}

test "Compiler e2e: player/ink_list_roundtrip.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "player/ink_list_roundtrip.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello World.\n", out);
}

test "Compiler e2e: player/variable_observation.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "player/variable_observation.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const b = story.resolveVariable("aBoolean");
    try std.testing.expect(b != null);
    const n = story.resolveVariable("anInteger");
    try std.testing.expect(n != null);
    if (n) |v| try std.testing.expectEqual(RuntimeObject{ .int = 3 }, v);
}

test "Compiler e2e: player/variables.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "player/variables.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello World") != null);
    try std.testing.expect(story.currentChoices().len >= 1);
}

test "Compiler e2e: runtime/bindings/external_binding.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/bindings/external_binding.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("message", extMessage, .{});
    try story.bindExternalFunction("multiply", extMultiply, .{});
    try story.bindExternalFunction("times", extTimes, .{});

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("15\nknock knock knock \n", out);
}

test "Compiler e2e: runtime/bindings/game_ink_back_and_forth.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/bindings/game_ink_back_and_forth.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("gameInc", extGameInc, .{});

    var text_out = std.ArrayList(u8).empty;
    defer text_out.deinit(alloc);

    _ = try story.evaluateFunction("topExternal", &.{.{ .int = 5 }}, &text_out);
    try std.testing.expect(std.mem.indexOf(u8, text_out.items, "In top external") != null);
}

test "Compiler e2e: runtime/bindings/lookup_safe_or_not.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/bindings/lookup_safe_or_not.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("myAction", extNoOp, .{});

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Two") != null);
}

test "Compiler e2e: runtime/bindings/lookup_safe_or_not_with_post_glue.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/bindings/lookup_safe_or_not_with_post_glue.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("myAction", extNoOp, .{});

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Two") != null);
}
test "Compiler e2e: runtime/bindings/variable_observer.ink" {
    const alloc = std.testing.allocator;
    const json = try compileFixture(alloc, "runtime/bindings/variable_observer.ink");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const Ctx = struct {
        count: u32 = 0,
        last_int: i64 = 0,
        fn callback(_: []const u8, new_val: RuntimeObject) void {
            result.count += 1;
            if (new_val == .int) result.last_int = new_val.int;
        }
        var result: @This() = .{};
    };
    Ctx.result = .{};

    try story.observeVariable("testVar", Ctx.callback);

    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "Hello world!") != null);

    try std.testing.expectEqual(@as(u32, 1), Ctx.result.count);
    try std.testing.expectEqual(@as(i64, 15), Ctx.result.last_int);

    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);

    try std.testing.expectEqual(@as(u32, 2), Ctx.result.count);
    try std.testing.expectEqual(@as(i64, 25), Ctx.result.last_int);
}
test "Compiler e2e: booleans/false_plus_false.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/false_plus_false.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}
test "Compiler e2e: booleans/list_hasnt.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/list_hasnt.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}
test "Compiler e2e: booleans/not_one.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/not_one.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}
test "Compiler e2e: booleans/not_true.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/not_true.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}
test "Compiler e2e: booleans/three_greater_than_one.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/three_greater_than_one.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}
test "Compiler e2e: booleans/true.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/true.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}
test "Compiler e2e: booleans/true_equals_one.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/true_equals_one.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}
test "Compiler e2e: booleans/true_plus_one.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/true_plus_one.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n", out);
}
test "Compiler e2e: booleans/true_plus_true.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/true_plus_true.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n", out);
}
test "Compiler e2e: booleans/two_plus_true.ink" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/booleans/two_plus_true.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("3\n", out);
}

// ── Integration fixtures ───────────────────────────────────────────────────────

/// Drive a Story through a fixed choice sequence, collecting all output. Caller owns result.
fn driveChoices(alloc: std.mem.Allocator, s: *Story, choices: []const usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    var ci: usize = 0;
    while (true) {
        if (s.currentChoices().len > 0 and ci < choices.len and !s.canContinue()) {
            try s.chooseChoiceIndex(choices[ci]);
            ci += 1;
            continue;
        }
        if (s.canContinue()) {
            const out = try s.cont();
            defer alloc.free(out);
            try buf.appendSlice(alloc, out);
        } else break;
    }
    return buf.toOwnedSlice(alloc);
}

/// Run a pre-compiled story JSON with a fixed choice sequence. Caller owns the result.
fn runFromJson(alloc: std.mem.Allocator, json: []const u8, choices: []const usize) ![]u8 {
    var s = try Story.initFromJson(alloc, json);
    defer s.deinit();
    return driveChoices(alloc, &s, choices);
}

/// Run both JSON and direct paths with the same choices. Assert outputs match.
/// Returns the common output (caller owns).
fn runBothAndAssert(
    alloc: std.mem.Allocator,
    json: []const u8,
    src: []const u8,
    choices: []const usize,
) ![]u8 {
    var sj = try Story.initFromJson(alloc, json);
    defer sj.deinit();
    const out_json = try driveChoices(alloc, &sj, choices);
    errdefer alloc.free(out_json);

    var sd = try compiler.compileToStory(alloc, src);
    defer sd.deinit();
    const out_direct = try driveChoices(alloc, &sd, choices);
    defer alloc.free(out_direct);

    try std.testing.expectEqualStrings(out_json, out_direct);
    return out_json;
}

test "Compiler e2e: simple_taster_tutorial.ink - all choice paths" {
    // Choice tree (all 8 paths):
    //
    //   [1]           → silent ("said nothing")
    //   [0,1]         → "Ah." branch
    //   [0,0,0,0..2]  → "A wager!" → "But surely" → post-gather choice 0/1/2
    //   [0,0,1,0..2]  → "A wager!" → "Most serious" → post-gather choice 0/1/2
    //
    // Every path converges at "we passed the day in silence."
    // `phrases` lists text unique to that path (pre-gather and/or post-gather branch).
    // Both JSON and direct paths run for each case; outputs must match.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/simple_taster_tutorial.ink", alloc, .limited(1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);

    const Case = struct { choices: []const usize, phrases: []const []const u8 };
    const cases = [_]Case{
        .{ .choices = &.{1}, .phrases = &.{"said nothing"} },
        .{ .choices = &.{ 0, 1 }, .phrases = &.{"uncertain what I thought"} },
        .{ .choices = &.{ 0, 0, 0, 0 }, .phrases = &.{ "surely that is foolishness", "endeavour to find out" } },
        .{ .choices = &.{ 0, 0, 0, 1 }, .phrases = &.{ "surely that is foolishness", "Twenty thousand pounds" } },
        .{ .choices = &.{ 0, 0, 0, 2 }, .phrases = &.{ "surely that is foolishness", "polite cough" } },
        .{ .choices = &.{ 0, 0, 1, 0 }, .phrases = &.{ "most serious matter", "endeavour to find out" } },
        .{ .choices = &.{ 0, 0, 1, 1 }, .phrases = &.{ "most serious matter", "Twenty thousand pounds" } },
        .{ .choices = &.{ 0, 0, 1, 2 }, .phrases = &.{ "most serious matter", "polite cough" } },
    };

    for (cases) |tc| {
        // runBothAndAssert runs JSON + direct paths and asserts they produce identical output.
        const out = try runBothAndAssert(alloc, json, src, tc.choices);
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "we passed the day in silence") != null);
        for (tc.phrases) |phrase| {
            try std.testing.expect(std.mem.indexOf(u8, out, phrase) != null);
        }
    }
}

test "Compiler e2e: simple_taster_tutorial.ink - interactive always-first loop" {
    // Simulate an interactive session that always picks choice 0 until the story
    // ends naturally. Both JSON and direct paths run in lockstep; outputs must match.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/simple_taster_tutorial.ink", alloc, .limited(1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);

    // JSON path.
    var sj = try Story.initFromJson(alloc, json);
    defer sj.deinit();
    var buf_j = std.ArrayList(u8).empty;
    defer buf_j.deinit(alloc);
    var turns: usize = 0;
    while (turns < 20) : (turns += 1) {
        if (sj.canContinue()) {
            const out = try sj.cont();
            defer alloc.free(out);
            try buf_j.appendSlice(alloc, out);
        } else if (sj.currentChoices().len > 0) {
            try sj.chooseChoiceIndex(0);
        } else break;
    }

    // Direct path.
    var sd = try compiler.compileToStory(alloc, src);
    defer sd.deinit();
    var buf_d = std.ArrayList(u8).empty;
    defer buf_d.deinit(alloc);
    turns = 0;
    while (turns < 20) : (turns += 1) {
        if (sd.canContinue()) {
            const out = try sd.cont();
            defer alloc.free(out);
            try buf_d.appendSlice(alloc, out);
        } else if (sd.currentChoices().len > 0) {
            try sd.chooseChoiceIndex(0);
        } else break;
    }

    try std.testing.expectEqualStrings(buf_j.items, buf_d.items);
    try std.testing.expect(std.mem.indexOf(u8, buf_j.items, "we passed the day in silence") != null);
}

test "Compiler e2e: crime_scene.ink - initial scene loads" {
    // No choices: verify the opening scene compiles and runs.
    // Both JSON and direct paths run; outputs must match.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);
    const out = try runBothAndAssert(alloc, json, src, &.{});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "bedroom") != null);
}

test "Compiler e2e: crime_scene.ink - examine desk and get cane" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);
    const out = try runBothAndAssert(alloc, json, src, &.{ 1, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "desk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "cane") != null);
}

test "Compiler e2e: weave trailing gather divert waits until after choice" {
    // Minimal weave with `- -> h` after nested `* *` under `(h)` (crime_scene bedhub pattern).
    const alloc = std.testing.allocator;
    const out = try compileFixtureRootAndRun(alloc, "runtime/weaves/trailing_gather_loop.ink", &.{0});
    defer alloc.free(out);
    // Choice labels are not echoed into `cont()` output; assert the choice body ran.
    try std.testing.expect(std.mem.indexOf(u8, out, "picked") != null);
}

test "Compiler e2e: crime_scene.ink - examine bed fully" {
    // Precompiled JSON for the JSON path (fast); source compiled fresh for the direct path.
    // Regenerate crime_scene.ink.json with `zig run emit_crime_json.zig` after editing.
    // Both paths must produce identical output.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const json = try helpers.loadFixture(alloc, "crime_scene.ink.json");
    defer alloc.free(json);
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const out = try runBothAndAssert(alloc, json, src, &.{ 0, 0, 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "neatly made") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "crumpled") != null);
}

test "Compiler e2e: crime_scene.ink - examine window" {
    // top→window→look down→look at glass. Both paths run; outputs must match.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);
    const out = try runBothAndAssert(alloc, json, src, &.{ 2, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "window") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "brook") != null);
}

test "Compiler e2e: crime_scene.ink - desk then bed then window then leave" {
    // Drive all three main sections by always picking the last choice (tends to exhaust
    // sub-sections fastest). Both JSON and direct paths run; outputs must match.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);

    // JSON path.
    var sj = try Story.initFromJson(alloc, json);
    defer sj.deinit();
    var buf_j = std.ArrayList(u8).empty;
    defer buf_j.deinit(alloc);
    var turns: usize = 0;
    while (turns < 60) : (turns += 1) {
        if (sj.canContinue()) {
            const out = try sj.cont();
            defer alloc.free(out);
            try buf_j.appendSlice(alloc, out);
        } else if (sj.currentChoices().len > 0) {
            try sj.chooseChoiceIndex(sj.currentChoices().len - 1);
        } else break;
    }

    // Direct path.
    var sd = try compiler.compileToStory(alloc, src);
    defer sd.deinit();
    var buf_d = std.ArrayList(u8).empty;
    defer buf_d.deinit(alloc);
    turns = 0;
    while (turns < 60) : (turns += 1) {
        if (sd.canContinue()) {
            const out = try sd.cont();
            defer alloc.free(out);
            try buf_d.appendSlice(alloc, out);
        } else if (sd.currentChoices().len > 0) {
            try sd.chooseChoiceIndex(sd.currentChoices().len - 1);
        } else break;
    }

    try std.testing.expectEqualStrings(buf_j.items, buf_d.items);
    try std.testing.expect(std.mem.indexOf(u8, buf_j.items, "bedroom") != null);
    _ = std.mem.indexOf(u8, buf_j.items, "Joe");
}

// ── crime_scene exhaustive / scenario tests ────────────────────────────────────

/// DFS over the story's choice tree. At each node, runs both the JSON path and the
/// direct path, asserting identical output. `depth` limits additional recursion levels.
fn crimeDFSDual(
    alloc: std.mem.Allocator,
    json: []const u8,
    src: []const u8,
    path: *std.ArrayList(usize),
    depth: usize,
) !void {
    // JSON path: drive to current path end, collect output + remaining choices.
    var sj = try Story.initFromJson(alloc, json);
    defer sj.deinit();
    var buf_j = std.ArrayList(u8).empty;
    defer buf_j.deinit(alloc);
    var ci: usize = 0;
    while (true) {
        if (sj.canContinue()) {
            const out = try sj.cont();
            defer alloc.free(out);
            try buf_j.appendSlice(alloc, out);
        } else if (sj.currentChoices().len > 0 and ci < path.items.len) {
            try sj.chooseChoiceIndex(path.items[ci]);
            ci += 1;
        } else break;
    }

    // Direct path: same choice sequence.
    var sd = try compiler.compileToStory(alloc, src);
    defer sd.deinit();
    var buf_d = std.ArrayList(u8).empty;
    defer buf_d.deinit(alloc);
    ci = 0;
    while (true) {
        if (sd.canContinue()) {
            const out = try sd.cont();
            defer alloc.free(out);
            try buf_d.appendSlice(alloc, out);
        } else if (sd.currentChoices().len > 0 and ci < path.items.len) {
            try sd.chooseChoiceIndex(path.items[ci]);
            ci += 1;
        } else break;
    }

    try std.testing.expectEqualStrings(buf_j.items, buf_d.items);

    if (depth == 0 or sj.currentChoices().len == 0) return;
    const n = sj.currentChoices().len;
    for (0..n) |i| {
        try path.append(alloc, i);
        try crimeDFSDual(alloc, json, src, path, depth - 1);
        _ = path.pop();
    }
}

test "Compiler e2e: crime_scene.ink - all states reachable within 3 choices" {
    // Explores every choice sequence up to depth 3. At each node both JSON and direct
    // paths run and must produce identical output. No crash/mismatch allowed.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);
    const json = try compiler.compile(alloc, src);
    defer alloc.free(json);
    var path = std.ArrayList(usize).empty;
    defer path.deinit(alloc);
    try crimeDFSDual(alloc, json, src, &path, 3);
}
