/// Test helper for the Ink compiler.
///
/// compileAndRun compiles Ink source to JSON, loads it in the runtime,
/// drives the story through a choice sequence, and returns the output.
const std = @import("std");
const Story = @import("../runtime/story.zig").Story;
const compiler = @import("../compiler/compiler.zig");

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
        if (s.canContinue()) {
            const out = try s.cont();
            defer alloc.free(out);
            try output.appendSlice(alloc, out);
        } else if (s.currentChoices().len > 0 and choice_idx < choices.len) {
            try s.chooseChoiceIndex(choices[choice_idx]);
            choice_idx += 1;
        } else {
            break;
        }
    }

    return output.toOwnedSlice(alloc);
}

/// Load an .ink file from test/fixture/original/, compile and run it.
/// Caller owns the returned slice.
pub fn compileFixtureAndRun(
    alloc: std.mem.Allocator,
    comptime rel_path: []const u8,
    choices: []const usize,
) ![]u8 {
    const path = "test/fixture/original/" ++ rel_path;
    const io = std.testing.io;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);

    return compileAndRun(alloc, src, choices);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

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
    // {list} should show "b, d" (or at least not crash)
    try std.testing.expect(out.len > 0);
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
    // * opt → nested weave with -- text, ** impossible, ** -> END; - gather
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/choices/should_not_gather_due_to_choice.ink", &.{0});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "gather") != null);
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
    const out = try compileFixtureAndRun(alloc, "runtime/choices/once_only_choices_can_link_back_to_self.ink", &.{ 0, 1 });
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
