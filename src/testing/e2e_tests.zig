//! The compiler's end-to-end tests (plan P9.2): each story is compiled by the new compiler
//! (src/compiler/compile.zig) and played on the new VM (src/runtime/api.zig) through a fixed
//! list of choices, choosing whenever the story can't continue (e2e_new_vm.play). These are
//! the old compiler's e2e tests (src/test/compiler_helpers.zig) with their expectations; where
//! the old pipeline differed from ink (the `e2e` corpus of the divergence ledger), the
//! expectation is what ink prints. The tests that drove the old runtime's API directly live in
//! e2e_new_vm_api.zig.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const e2e_new_vm = @import("e2e_new_vm.zig");
const vm = @import("../runtime/api.zig");
const Program = @import("../core/program.zig").Program;
const Severity = @import("../runtime/state.zig").Diagnostic.Severity;

const fixtures = "test/fixture/original/";
const steps_max = 100_000;

/// What a played story's output must be: exactly `exact`, and/or contain every part of `has`
/// and none of `lacks`.
const Expect = struct {
    exact: ?[]const u8 = null,
    has: []const []const u8 = &.{},
    lacks: []const []const u8 = &.{},
    nonempty: bool = false,
};

fn expect_output(output: []const u8, expect: Expect) !void {
    assert(output.len < std.math.maxInt(u32));
    assert(expect.exact == null or expect.has.len == 0);
    if (expect.exact) |exact| try std.testing.expectEqualStrings(exact, output);
    if (expect.nonempty) try std.testing.expect(output.len > 0);
    for (expect.has) |part| {
        if (std.mem.indexOf(u8, output, part) != null) continue;
        std.debug.print("expected \"{s}\" in: \"{s}\"\n", .{ part, output });
        return error.TestExpectedPart;
    }
    for (expect.lacks) |part| {
        if (std.mem.indexOf(u8, output, part) == null) continue;
        std.debug.print("expected no \"{s}\" in: \"{s}\"\n", .{ part, output });
        return error.TestUnexpectedPart;
    }
}

/// Plays the fixture `path` (under test/fixture/original/) and checks its output.
fn expect_fixture(comptime path: []const u8, choices: []const usize, expect: Expect) !void {
    assert(std.mem.endsWith(u8, path, ".ink"));
    assert(choices.len < 64);
    const gpa = std.testing.allocator;
    const output = try e2e_new_vm.play(gpa, "", fixtures ++ path, choices);
    defer gpa.free(output);
    try expect_output(output, expect);
}

/// Plays the inline story `source` and checks its output.
fn expect_source(source: []const u8, choices: []const usize, expect: Expect) !void {
    assert(source.len < std.math.maxInt(u32));
    assert(choices.len < 64);
    const gpa = std.testing.allocator;
    const output = try e2e_new_vm.play(gpa, source, null, choices);
    defer gpa.free(output);
    try expect_output(output, expect);
}

/// `source` compiled and serialized as ink's JSON.
fn compile_to_json(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    assert(source.len > 0);
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
    assert(out.written().len > 0);
    return out.toOwnedSlice();
}

// ── Compiler JSON ─────────────────────────────────────────────────────────────

test "Compiler JSON: divert_to_weave_points" {
    const json = try compile_to_json(std.testing.allocator,
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
    );
    defer std.testing.allocator.free(json);
    // inklecate's JSON for this story.
    try std.testing.expectEqualStrings("{\"inkVersion\":21,\"root\":[[{\"->\":" ++
        "\"knot.stitch.0.gather\"},[\"done\",{\"#n\":\"g-0\"}],null],\"done\",{\"knot\":" ++
        "[{\"->\":\".^.stitch\"},{\"stitch\":[[[\"^hello\",\"\\n\",[\"ev\",{\"^->\":" ++
        "\"knot.stitch.0.g-0.2.$r1\"},{\"temp=\":\"$r\"},\"str\",{\"->\":\".^.s\"}," ++
        "[{\"#n\":\"$r1\"}],\"/str\",\"/ev\",{\"*\":\".^.^.c-0\",\"flg\":18},{\"s\":" ++
        "[\"^test\",{\"->\":\"$r\",\"var\":true},null]}],{\"c-0\":[\"ev\",{\"^->\":" ++
        "\"knot.stitch.0.g-0.c-0.$r2\"},\"/ev\",{\"temp=\":\"$r\"},{\"->\":" ++
        "\".^.^.2.s\"},[{\"#n\":\"$r2\"}],\"\\n\",\"^choice content\",\"\\n\"," ++
        "{\"->\":\".^.^.^.gather\"},{\"#f\":5}],\"#n\":\"g-0\"}],{\"gather\":" ++
        "[\"^gather\",\"\\n\",\"end\",null]}],null]}]}],\"listDefs\":{}}", json);
}

test "Compiler JSON: knot_do_not_gather" {
    const json = try compile_to_json(std.testing.allocator,
        \\-> knot
        \\=== knot
        \\-> knot.gather
        \\- (gather) g
        \\-> DONE
        \\
    );
    defer std.testing.allocator.free(json);
    // inklecate's JSON for this story.
    try std.testing.expectEqualStrings("{\"inkVersion\":21,\"root\":[[{\"->\":\"knot\"}," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",{\"knot\":[[{\"->\":\".^.gather\"}," ++
        "[\"^g\",\"\\n\",\"done\",{\"#n\":\"gather\"}],null],null]}],\"listDefs\":{}}", json);
}

test "Compiler JSON: tunnel_onwards_divert_after_with_arg" {
    const json = try compile_to_json(std.testing.allocator,
        \\-> a ->
        \\=== a ===
        \\->-> b (5 + 3)
        \\=== b (x) ===
        \\{x}
        \\-> END
        \\
    );
    defer std.testing.allocator.free(json);
    // inklecate's JSON for this story (the old compiler's had `{"#f":1}` for `null`).
    try std.testing.expectEqualStrings("{\"inkVersion\":21,\"root\":[[{\"->t->\":\"a\"}," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",{\"a\":[\"ev\",5,3,\"+\"," ++
        "{\"^->\":\"b\"},\"/ev\",\"->->\",null],\"b\":[{\"temp=\":\"x\"},\"ev\"," ++
        "{\"VAR?\":\"x\"},\"out\",\"/ev\",\"\\n\",\"end\",null]}],\"listDefs\":{}}", json);
}

// ── Basics ────────────────────────────────────────────────────────────────────

test "empty story" {
    try expect_source("", &.{}, .{ .exact = "" });
}

test "hello world inline" {
    try expect_source("Hello world\n", &.{}, .{ .exact = "Hello world\n" });
}

test "text with END" {
    try expect_source(
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{}, .{ .exact = "hello\n" });
}

test "divert to knot then END" {
    try expect_source(
        \\-> test
        \\== test ==
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{}, .{ .exact = "hello\n" });
}

test "multi-knot story" {
    try expect_source(
        \\-> firstKnot
        \\=== firstKnot
        \\Hello!
        \\-> anotherKnot
        \\=== anotherKnot
        \\World.
        \\-> END
    , &.{}, .{ .exact = "Hello!\nWorld.\n" });
}

test "misc/hello_world.ink fixture" {
    try expect_fixture("runtime/misc/hello_world.ink", &.{}, .{ .exact = "Hello world\n" });
}

test "misc/empty.ink fixture" {
    try expect_fixture("runtime/misc/empty.ink", &.{}, .{ .exact = "" });
}

test "misc/end.ink fixture" {
    try expect_fixture("runtime/misc/end.ink", &.{}, .{ .exact = "hello\n" });
}

test "misc/end2.ink fixture" {
    try expect_fixture("runtime/misc/end2.ink", &.{}, .{ .exact = "hello\n" });
}

test "misc/end_of_content.ink fixture" {
    // The story has a knot "test" but no root-level divert to it: the output is empty.
    try expect_fixture("runtime/misc/end_of_content.ink", &.{}, .{ .exact = "" });
}

test "misc/whitespace.ink fixture" {
    try expect_fixture("runtime/misc/whitespace.ink", &.{}, .{ .exact = "Hello!\nWorld.\n" });
}

test "misc/includes/included_file.ink" {
    const path = "runtime/misc/includes/included_file.ink";
    try expect_fixture(path, &.{}, .{ .exact = "This is include 1.\n" });
}

test "misc/includes/included_file_2.ink" {
    const path = "runtime/misc/includes/included_file_2.ink";
    try expect_fixture(path, &.{}, .{ .exact = "This is include 2.\n" });
}

test "misc/includes/included_file_3.ink" {
    // Compiled on its own, its INCLUDE resolves from its own directory and fails, as in
    // inklecate (the old compiler ignored INCLUDE and printed nothing).
    const path = "runtime/misc/includes/included_file_3.ink";
    const result = e2e_new_vm.play(std.testing.allocator, "", fixtures ++ path, &.{});
    try std.testing.expectError(error.CompileFailed, result);
}

test "misc/includes/included_file_4.ink" {
    try expect_fixture("runtime/misc/includes/included_file_4.ink", &.{}, .{ .has = &.{"5"} });
}

test "misc/nested_include.ink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = fixtures ++ "runtime/misc/nested_include.ink";
    var directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path).?, .{});
    defer directory.close(io);
    var program = try compile.compile_file(gpa, io, directory, std.fs.path.basename(path));
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "This is the main file") != null);
}

// ── Expressions ───────────────────────────────────────────────────────────────

test "inline boolean true" {
    try expect_source("{true}\n", &.{}, .{ .exact = "true\n" });
}

test "inline boolean false" {
    try expect_source("{false}\n", &.{}, .{ .exact = "false\n" });
}

test "inline not true" {
    try expect_source("{not true}\n", &.{}, .{ .exact = "false\n" });
}

test "inline comparison 3 > 1" {
    try expect_source("{3 > 1}\n", &.{}, .{ .exact = "true\n" });
}

test "inline arithmetic 2 + 3" {
    try expect_source("{2 + 3}\n", &.{}, .{ .exact = "5\n" });
}

test "arithmetic.ink fixture" {
    try expect_fixture("runtime/evaluation/arithmetic.ink", &.{}, .{
        .exact = "36\n2\n3\n2\n2.3333333\n8\n8\n",
    });
}

// ── Variables ─────────────────────────────────────────────────────────────────

test "VAR inline ref" {
    try expect_source("VAR x = 5\n{x}\n", &.{}, .{ .exact = "5\n" });
}

test "temp var" {
    try expect_source("~ temp y = 4\n{y}\n", &.{}, .{ .exact = "4\n" });
}

test "temp reassignment" {
    try expect_source("~ temp y = 1\n~ y = 7\n{y}\n", &.{}, .{ .exact = "7\n" });
}

test "CONST substitution in VAR" {
    try expect_source("CONST c = 5\nVAR x = c\n{x}\n", &.{}, .{ .exact = "5\n" });
}

test "temporaries_at_global_scope.ink fixture" {
    const path = "runtime/variables/temporaries_at_global_scope.ink";
    try expect_fixture(path, &.{}, .{ .exact = "54\n" });
}

test "const.ink fixture" {
    try expect_fixture("runtime/variables/const.ink", &.{}, .{ .exact = "5\n" });
}

// ── Conditionals ──────────────────────────────────────────────────────────────

test "inline if/else — false branch taken" {
    try expect_source("{false:not true|true}\n", &.{}, .{
        .has = &.{"true"},
        .lacks = &.{"not true"},
    });
}

test "block conditional — false branch skipped" {
    try expect_source(
        \\{
        \\- false:
        \\   beep
        \\}
    , &.{}, .{ .lacks = &.{"beep"} });
}

test "multi-branch — second branch taken" {
    try expect_source(
        \\{
        \\   - 4 > 5: not true
        \\   - 5 > 4: yes
        \\}
    , &.{}, .{ .has = &.{"yes"}, .lacks = &.{"not true"} });
}

test "outer condition with else — else taken" {
    try expect_source(
        \\{ 2 > 5:
        \\   - no
        \\   - yes
        \\}
    , &.{}, .{ .has = &.{"yes"}, .lacks = &.{"no"} });
}

test "switch — matching branch taken" {
    try expect_source(
        \\{ 6:
        \\   - 5: wrong
        \\   - 6: right
        \\   - 7: wrong
        \\}
    , &.{}, .{ .has = &.{"right"}, .lacks = &.{"wrong"} });
}

test "trivial_condition.ink fixture" {
    try expect_fixture("runtime/conditions/trivial_condition.ink", &.{}, .{
        .lacks = &.{"beep"},
    });
}

test "else_branches.ink fixture" {
    try expect_fixture("runtime/conditions/else_branches.ink", &.{}, .{
        .has = &.{"other"},
        .lacks = &.{ "one", "two" },
    });
}

test "conditionals.ink fixture" {
    try expect_fixture("runtime/conditions/conditionals.ink", &.{}, .{
        .has = &.{ "true", "great" },
        .lacks = &.{"not true"},
    });
}

test "all_switch_branches_fail_is_clean.ink fixture" {
    const path = "runtime/conditions/all_switch_branches_fail_is_clean.ink";
    try expect_fixture(path, &.{}, .{ .lacks = &.{ "x", "y" } });
}

test "empty_multiline_conditional_branch.ink fixture" {
    const path = "runtime/conditions/empty_multiline_conditional_branch.ink";
    try expect_fixture(path, &.{}, .{ .lacks = &.{"txt"} });
}

// ── Choices and weaves ────────────────────────────────────────────────────────

test "default_simple_gather.ink — fallback choice + gather" {
    try expect_fixture("runtime/choices/default_simple_gather.ink", &.{}, .{ .has = &.{"x"} });
}

test "choice_with_brackets_only.ink — brackets-only choice" {
    const path = "runtime/choices/choice_with_brackets_only.ink";
    try expect_fixture(path, &.{0}, .{ .has = &.{"Text"} });
}

test "choice_diverts_to_done.ink — start-text choice" {
    const path = "runtime/choices/choice_diverts_to_done.ink";
    try expect_fixture(path, &.{0}, .{ .has = &.{"choice"} });
}

test "sticky_choices_stay_sticky.ink" {
    // Two sticky choices loop back to test; choose the first three times, then stop.
    const path = "runtime/choices/sticky_choices_stay_sticky.ink";
    try expect_fixture(path, &.{ 0, 0, 0 }, .{ .has = &.{ "First line.", "Choice 1" } });
}

test "weave_options.ink — start+choice-only+following in knot" {
    try expect_fixture("runtime/weaves/weave_options.ink", &.{0}, .{ .exact = "Hello, world.\n" });
}

test "non_text_in_choice_inner_content.ink" {
    const path = "runtime/choices/non_text_in_choice_inner_content.ink";
    try expect_fixture(path, &.{0}, .{ .has = &.{ "option text", "Next." } });
}

test "gather_choice_same_line.ink" {
    try expect_fixture("runtime/choices/gather_choice_same_line.ink", &.{0}, .{
        .has = &.{"hello"},
    });
}

test "conditional_choices.ink — single-condition choices" {
    // ink offers "one", "two", "three", "four"; the second is "two".
    try expect_fixture("runtime/choices/conditional_choices.ink", &.{1}, .{ .exact = "two\n" });
}

test "has_read_on_choice.ink — condition on knot read count" {
    try expect_fixture("runtime/choices/has_read_on_choice.ink", &.{0}, .{
        .has = &.{"visible choice"},
    });
}

test "logic_in_choices.ink — function call in choice text" {
    try expect_fixture("runtime/choices/logic_in_choices.ink", &.{0}, .{
        .has = &.{ "Joe", "Hello" },
    });
}

// ── Functions ─────────────────────────────────────────────────────────────────

test "callstack_evaluation.ink — return with expr" {
    const path = "runtime/callstack/callstack_evaluation.ink";
    try expect_fixture(path, &.{}, .{ .exact = "8\n" });
}

test "function return bare" {
    try expect_source(
        \\{ greet() }
        \\-> END
        \\== function greet ==
        \\hello
        \\~ return
    , &.{}, .{ .has = &.{"hello"} });
}

test "function with params" {
    try expect_source(
        \\{ add(3, 4) }
        \\-> END
        \\== function add(x, y) ==
        \\~ return x + y
    , &.{}, .{ .exact = "7\n" });
}

test "variable_swap_recurse.ink — params + recursion" {
    try expect_fixture("runtime/variables/variable_swap_recurse.ink", &.{}, .{ .has = &.{"2"} });
}

// ── Increment and decrement ───────────────────────────────────────────────────

test "x++ increment" {
    try expect_source(
        \\VAR x = 0
        \\~ x++
        \\~ x++
        \\{x}
    , &.{}, .{ .exact = "2\n" });
}

test "x-- decrement" {
    try expect_source(
        \\VAR x = 5
        \\~ x--
        \\{x}
    , &.{}, .{ .exact = "4\n" });
}

test "x++ in VAR context" {
    try expect_source(
        \\VAR n = 10
        \\~ n--
        \\~ n--
        \\{n}
    , &.{}, .{ .exact = "8\n" });
}

// ── Glue and tags ─────────────────────────────────────────────────────────────

test "simple_glue.ink" {
    try expect_fixture("runtime/glue/simple_glue.ink", &.{}, .{
        .exact = "Some content with glue.\n",
    });
}

test "glue inline" {
    try expect_source("hello<> world\n", &.{}, .{ .exact = "hello world\n" });
}

test "tags — standalone hash tag line" {
    // Tags produce no text; the story's content still does.
    try expect_source(
        \\# author: Joe
        \\Hello world
    , &.{}, .{ .has = &.{"Hello world"} });
}

// ── Lists ─────────────────────────────────────────────────────────────────────

test "LIST basic" {
    // LIST list = a, (b), c, (d), e: b and d are selected.
    try expect_fixture("runtime/lists/list_basic_operations.ink", &.{}, .{
        .exact = "b, d\na, b, c, e\nb, c\nfalse\ntrue\ntrue\n",
    });
}

test "LIST empty_list_origin" {
    try expect_fixture("runtime/lists/empty_list_origin.ink", &.{}, .{ .exact = "a, b\n" });
}

test "LIST more_list_operations" {
    try expect_fixture("runtime/lists/more_list_operations.ink", &.{}, .{
        .exact = "1\nl\nn\nl, m\nn\n",
    });
}

test "lists/contains_empty_list_always_false.ink" {
    const path = "runtime/lists/contains_empty_list_always_false.ink";
    try expect_fixture(path, &.{}, .{ .exact = "false\nfalse\nfalse\n" });
}

test "lists/empty_list_origin_after_assignment.ink" {
    const path = "runtime/lists/empty_list_origin_after_assignment.ink";
    try expect_fixture(path, &.{}, .{ .exact = "a, b, c\n" });
}

test "lists/list_mixed_items.ink" {
    try expect_fixture("runtime/lists/list_mixed_items.ink", &.{}, .{ .exact = "a, y, c\n" });
}

test "lists/list_random.ink" {
    const gpa = std.testing.allocator;
    const path = fixtures ++ "runtime/lists/list_random.ink";
    const output = try e2e_new_vm.play(gpa, "", path, &.{});
    defer gpa.free(output);
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, output, "\n"));
}

test "lists/list_range.ink" {
    try expect_fixture("runtime/lists/list_range.ink", &.{}, .{
        .has = &.{ "Two, Three, Four, Five, Six\n", "Pizza" },
    });
}

test "lists/list_save_load.ink" {
    try expect_fixture("runtime/lists/list_save_load.ink", &.{}, .{ .exact = "a, x, c\n" });
}

// ── Divert targets and standalone calls ───────────────────────────────────────

test "variable_divert_target.ink" {
    const path = "runtime/variables/variable_divert_target.ink";
    try expect_fixture(path, &.{}, .{ .exact = "Here.\n" });
}

test "standalone function call ~ f()" {
    try expect_source(
        \\VAR n = 0
        \\~ setN(5)
        \\{n}
        \\== function setN(x) ==
        \\~ n = x
        \\~ return
    , &.{}, .{ .exact = "5\n" });
}

test "multiple_constant_references.ink" {
    const path = "runtime/variables/multiple_constant_references.ink";
    try expect_fixture(path, &.{}, .{ .has = &.{"success"} });
}

test "variable_declaration_in_conditional.ink" {
    const path = "runtime/variables/variable_declaration_in_conditional.ink";
    try expect_fixture(path, &.{}, .{ .has = &.{"5"} });
}

// ── Named gathers, choice labels, nested choices ──────────────────────────────

test "should_not_gather_due_to_choice.ink" {
    // The nested weave's choices are all filtered, so its invisible default goes to END and
    // "gather" is never reached.
    const path = "runtime/choices/should_not_gather_due_to_choice.ink";
    try expect_fixture(path, &.{0}, .{ .has = &.{"text"}, .lacks = &.{"gather"} });
}

test "weave_gathers.ink" {
    // Choose "one", which has the nested choice "two" and the gather "three".
    try expect_fixture("runtime/weaves/weave_gathers.ink", &.{ 0, 0 }, .{
        .has = &.{ "one", "two", "six" },
    });
}

test "default_choices.ink — named gather + loop" {
    try expect_fixture("runtime/choices/default_choices.ink", &.{0}, .{
        .has = &.{"After choice"},
    });
}

test "once_only_choices_can_link_back_to_self.ink" {
    // A choice label, a condition on it and a named gather: it must just run.
    const path = "runtime/choices/once_only_choices_can_link_back_to_self.ink";
    try expect_fixture(path, &.{ 0, 0 }, .{});
}

// ── Tunnels ───────────────────────────────────────────────────────────────────

test "basic_tunnel.ink" {
    try expect_fixture("runtime/diverts/basic_tunnel.ink", &.{}, .{ .exact = "Hello world\n" });
}

test "callstack_evaluation.ink" {
    try expect_fixture("runtime/callstack/callstack_evaluation.ink", &.{}, .{ .exact = "8\n" });
}

test "tunnel_onwards_after_tunnel.ink" {
    try expect_fixture("runtime/diverts/tunnel_onwards_after_tunnel.ink", &.{}, .{
        .exact = "Hello...\n...world.\nThe End.\n",
    });
}

// ── Sequences ─────────────────────────────────────────────────────────────────

test "inline stopping sequence {a|b}" {
    try expect_source(
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{one|two}
        \\->->
    , &.{}, .{ .has = &.{"one"} });
}

test "block stopping sequence" {
    try expect_source(
        \\-> seq ->
        \\-> seq ->
        \\-> END
        \\== seq ==
        \\{stopping:
        \\- first
        \\- second
        \\}
        \\->->
    , &.{}, .{ .has = &.{"first"} });
}

test "inline cycle sequence {&a|b}" {
    try expect_source(
        \\-> thing ->
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{&one|two}
        \\->->
    , &.{}, .{ .has = &.{"one"} });
}

test "leading_newline_multiline_sequence.ink fixture" {
    try expect_fixture("runtime/sequences/leading_newline_multiline_sequence.ink", &.{}, .{});
}

test "empty_sequence_content.ink fixture" {
    try expect_fixture("runtime/sequences/empty_sequence_content.ink", &.{}, .{});
}

// ── Glue, newlines, strings, tags ─────────────────────────────────────────────

test "left_right_glue_matching.ink" {
    try expect_fixture("runtime/glue/left_right_glue_matching.ink", &.{}, .{
        .has = &.{ "A line.", "Another line." },
    });
}

test "newline_consistency_1.ink" {
    try expect_fixture("runtime/newlines/newline_consistency_1.ink", &.{}, .{
        .has = &.{ "hello", "world" },
    });
}

test "newline_consistency_2.ink" {
    try expect_fixture("runtime/newlines/newline_consistency_2.ink", &.{0}, .{
        .has = &.{"world"},
    });
}

test "string_constants.ink" {
    try expect_fixture("runtime/strings/string_constants.ink", &.{}, .{ .exact = "hi\n" });
}

test "string_contains — ? operator" {
    try expect_source(
        \\{"hello world" ? "o wo"}
        \\{"hello world" ? "nope"}
    , &.{}, .{ .exact = "true\nfalse\n" });
}

test "tags.ink fixture" {
    try expect_fixture("runtime/tags/tags.ink", &.{}, .{ .has = &.{"This is the content"} });
}

test "newline_at_start_of_multiline_conditional.ink" {
    const path = "runtime/newlines/newline_at_start_of_multiline_conditional.ink";
    try expect_fixture(path, &.{}, .{ .exact = "X\nx\n" });
}

test "LIST more_list_operations inline" {
    try expect_source(
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
    , &.{}, .{ .exact = "1\nl\nn\nl, m\nn\n" });
}

// ── Threads and built-ins ─────────────────────────────────────────────────────

test "TURNS() built-in" {
    try expect_fixture("runtime/builtins/turns.ink", &.{0}, .{ .exact = "0\n1\n" });
}

test "TURNS_SINCE built-in" {
    try expect_fixture("runtime/builtins/turns_since.ink", &.{ 0, 0 }, .{
        .exact = "-1\n0\n1\n2\n",
    });
}

test "CHOICE_COUNT built-in" {
    try expect_fixture("runtime/choices/choice_count.ink", &.{0}, .{ .has = &.{"2"} });
}

test "read_count_across_callstack.ink" {
    try expect_fixture("runtime/builtins/read_count_across_callstack.ink", &.{}, .{
        .exact = "1) Seen first 1 times.\nIn second.\n2) Seen first 1 times.\n",
    });
}

test "thread in sequence" {
    try expect_fixture("runtime/threads/thread_in_logic.ink", &.{}, .{ .has = &.{"Content"} });
}

test "thread_done.ink" {
    try expect_fixture("runtime/threads/thread_done.ink", &.{}, .{});
}

// ── Evaluation ────────────────────────────────────────────────────────────────

test "evaluation/factorial_recursive.ink" {
    const path = "runtime/evaluation/factorial_recursive.ink";
    try expect_fixture(path, &.{}, .{ .exact = "120\n" });
}

test "evaluation/literal_unary.ink" {
    try expect_fixture("runtime/evaluation/literal_unary.ink", &.{}, .{
        .exact = "-1\nfalse\ntrue\n",
    });
}

test "evaluation/basic_string_literals.ink" {
    try expect_fixture("runtime/evaluation/basic_string_literals.ink", &.{}, .{
        .exact = "Hello world 1\nHello world 2.\n",
    });
}

test "evaluation/increment.ink" {
    try expect_fixture("runtime/evaluation/increment.ink", &.{}, .{ .exact = "6\n5\n" });
}

test "evaluation/evaluation_stack_leaks.ink" {
    try expect_fixture("runtime/evaluation/evaluation_stack_leaks.ink", &.{}, .{
        .exact = "else\nelse\nhi\n",
    });
}

test "evaluation/evaluating_function_variable_state_bug.ink" {
    const path = "runtime/evaluation/evaluating_function_variable_state_bug.ink";
    try expect_fixture(path, &.{}, .{ .exact = "Start\nIn tunnel.\nEnd\n" });
}

test "evaluation/factorial_by_reference.ink" {
    const path = "runtime/evaluation/factorial_by_reference.ink";
    try expect_fixture(path, &.{}, .{ .exact = "120\n" });
}

// ── Logic ─────────────────────────────────────────────────────────────────────

test "logic/logic_lines_with_newlines.ink" {
    try expect_fixture("runtime/logic/logic_lines_with_newlines.ink", &.{}, .{
        .exact = "text1\ntext 2\ntext1\ntext 2\n",
    });
}

test "logic/multiline_logic_with_glue.ink" {
    try expect_fixture("runtime/logic/multiline_logic_with_glue.ink", &.{}, .{
        .exact = "a b\na b\n",
    });
}

test "logic/nested_pass_by_reference.ink" {
    try expect_fixture("runtime/logic/nested_pass_by_reference.ink", &.{}, .{
        .exact = "5\n625\n",
    });
}

test "logic/print_num.ink" {
    try expect_fixture("runtime/logic/print_num.ink", &.{}, .{
        .has = &.{ "four", "fifteen", "thirty-seven" },
    });
}

// ── Extra ─────────────────────────────────────────────────────────────────────

test "extra/arithmetic_2.ink" {
    try expect_fixture("runtime/extra/arithmetic_2.ink", &.{}, .{
        .exact = "2\n2.3333333\n2.3333333\n2.3333333\n2.3333333\n2.3333333\n",
    });
}

test "extra/list_comparison.ink" {
    try expect_fixture("runtime/extra/list_comparison.ink", &.{}, .{
        .has = &.{ "Philippe", "Andre" },
    });
}

test "glue/implicit_inline_glue.ink" {
    try expect_fixture("runtime/glue/implicit_inline_glue.ink", &.{}, .{
        .exact = "I have five eggs.\n",
    });
}

test "glue/implicit_inline_glue_b.ink" {
    try expect_fixture("runtime/glue/implicit_inline_glue_b.ink", &.{}, .{ .exact = "A\nX\n" });
}

test "glue/implicit_inline_glue_c.ink" {
    try expect_fixture("runtime/glue/implicit_inline_glue_c.ink", &.{}, .{ .exact = "A\nC\n" });
}

// ── Misc ──────────────────────────────────────────────────────────────────────

test "misc/escape_character.ink" {
    try expect_fixture("runtime/misc/escape_character.ink", &.{}, .{
        .exact = "this is a '|' character\n",
    });
}

test "misc/identifiers_can_start_with_number.ink" {
    try expect_fixture("runtime/misc/identifiers_can_start_with_number.ink", &.{}, .{
        .exact = "512x2 = 1024\n512x2p2 = 1026\n",
    });
}

test "misc/quote_character_significance.ink" {
    try expect_fixture("runtime/misc/quote_character_significance.ink", &.{}, .{
        .has = &.{"Joe"},
    });
}

test "newlines/newlines_trimming_with_func_external_fallback.ink" {
    // The external has no binding and fallbacks are off: ink raises an error, as the VM does.
    const path = "runtime/newlines/newlines_trimming_with_func_external_fallback.ink";
    const result = e2e_new_vm.play(std.testing.allocator, "", fixtures ++ path, &.{});
    try std.testing.expectError(error.MissingExternalBinding, result);
}

test "strings/string_contains.ink" {
    try expect_fixture("runtime/strings/string_contains.ink", &.{}, .{
        .exact = "true\nfalse\ntrue\ntrue\n",
    });
}

// ── Newlines ──────────────────────────────────────────────────────────────────

test "newlines/newline_consistency_3.ink" {
    try expect_fixture("runtime/newlines/newline_consistency_3.ink", &.{0}, .{
        .exact = "hello\nworld\n",
    });
}

test "newlines/newlines_with_string_eval.ink" {
    try expect_fixture("runtime/newlines/newlines_with_string_eval.ink", &.{}, .{
        .exact = "A\nB\nA\n3\nB\n",
    });
}

// ── Sequences ─────────────────────────────────────────────────────────────────

test "sequences/all_sequence_types.ink" {
    try expect_fixture("runtime/sequences/all_sequence_types.ink", &.{}, .{
        .has = &.{ "Once:", "Stopping:", "Cycle:" },
    });
}

test "sequences/blanks_in_inline_sequences.ink" {
    try expect_fixture("runtime/sequences/blanks_in_inline_sequences.ink", &.{}, .{
        .has = &.{ "1. a", "3. b" },
    });
}

test "sequences/gather_read_count_with_initial_sequence.ink" {
    const path = "runtime/sequences/gather_read_count_with_initial_sequence.ink";
    try expect_fixture(path, &.{}, .{ .exact = "seen test\n" });
}

test "sequences/shuffle_stack_muddying.ink" {
    try expect_fixture("runtime/sequences/shuffle_stack_muddying.ink", &.{}, .{ .exact = "" });
}

// ── Strings ───────────────────────────────────────────────────────────────────

test "strings/string_type_coercion.ink" {
    try expect_fixture("runtime/strings/string_type_coercion.ink", &.{}, .{
        .exact = "same\ndifferent\n",
    });
}

test "strings/strings_in_choices.ink" {
    try expect_fixture("runtime/strings/strings_in_choices.ink", &.{0}, .{
        .exact = "test1 test4\n",
    });
}

// ── Tags ──────────────────────────────────────────────────────────────────────

test "tags/tags_dynamic_content.ink" {
    try expect_fixture("runtime/tags/tags_dynamic_content.ink", &.{}, .{ .exact = "tag\n" });
}

test "tags/tags_in_choice.ink" {
    try expect_fixture("runtime/tags/tags_in_choice.ink", &.{0}, .{ .exact = "one three" });
}

test "tags/tags_in_seq.ink" {
    try expect_fixture("runtime/tags/tags_in_seq.ink", &.{}, .{
        .exact = "A red sequence.\nA white sequence.\n",
    });
}

// ── Variables ─────────────────────────────────────────────────────────────────

test "variables/variable_pointer_ref_from_knot.ink" {
    const path = "runtime/variables/variable_pointer_ref_from_knot.ink";
    try expect_fixture(path, &.{}, .{ .exact = "6\n" });
}

test "variables/variable_tunnel.ink" {
    try expect_fixture("runtime/variables/variable_tunnel.ink", &.{}, .{ .exact = "STUFF\n" });
}

test "variables/temp_usage_in_options.ink" {
    try expect_fixture("runtime/variables/temp_usage_in_options.ink", &.{0}, .{
        .exact = "1\nEnd of choice\nthis another\n",
    });
}

test "variables/set_non_existant_variable.ink" {
    const path = "runtime/variables/set_non_existant_variable.ink";
    try expect_fixture(path, &.{}, .{ .exact = "Hello world.\n" });
}

test "variables/temp_global_conflict.ink" {
    try expect_fixture("runtime/variables/temp_global_conflict.ink", &.{}, .{ .exact = "0\n" });
}

test "variables/temp_not_found.ink" {
    try expect_fixture("runtime/variables/temp_not_found.ink", &.{}, .{ .exact = "0\nhello\n" });
}

test "variables/warn_variable_not_found_1.ink" {
    const path = "runtime/variables/warn_variable_not_found_1.ink";
    try expect_fixture(path, &.{}, .{ .exact = "Hello world!\n0\n" });
}

test "variables/warn_variable_not_found_2.ink" {
    const path = "runtime/variables/warn_variable_not_found_2.ink";
    try expect_fixture(path, &.{}, .{ .exact = "Hello world!\n0\n" });
}

// ── Weaves ────────────────────────────────────────────────────────────────────

test "weaves/conditional_choice_in_weave.ink" {
    try expect_fixture("runtime/weaves/conditional_choice_in_weave.ink", &.{0}, .{
        .exact = "start\ngather should be seen\nresult\n",
    });
}

test "weaves/conditional_choice_in_weave_2.ink" {
    try expect_fixture("runtime/weaves/conditional_choice_in_weave_2.ink", &.{0}, .{
        .exact = "first gather\nthe main gather\nbottom gather\n",
    });
}

test "weaves/weave_within_sequence.ink" {
    try expect_fixture("runtime/weaves/weave_within_sequence.ink", &.{0}, .{
        .exact = "choice\nnextline\n",
    });
}

test "weaves/unbalanced_weave_indentation.ink" {
    try expect_fixture("runtime/weaves/unbalanced_weave_indentation.ink", &.{ 0, 0 }, .{
        .has = &.{"First"},
    });
}

// ── Choices ───────────────────────────────────────────────────────────────────

test "choices/once_only_choices_with_own_content.ink" {
    const path = "runtime/choices/once_only_choices_with_own_content.ink";
    try expect_fixture(path, &.{ 0, 0, 0 }, .{ .has = &.{ "first time", "finished eating" } });
}

test "choices/various_default_choices.ink" {
    try expect_fixture("runtime/choices/various_default_choices.ink", &.{}, .{
        .exact = "1\n2\n3\n",
    });
}

test "choices/state_rollback_over_default_choice.ink" {
    try expect_fixture("runtime/choices/state_rollback_over_default_choice.ink", &.{}, .{
        .exact = "Text.\n5\n",
    });
}

// ── Diverts ───────────────────────────────────────────────────────────────────

test "diverts/same_line_divert_is_inline.ink" {
    try expect_fixture("runtime/diverts/same_line_divert_is_inline.ink", &.{}, .{
        .exact = "We hurried home to Savile Row as fast as we could.\n",
    });
}

test "diverts/compare_divert_targets.ink" {
    try expect_fixture("runtime/diverts/compare_divert_targets.ink", &.{}, .{
        .exact = "different knot\nsame knot\nsame knot\ndifferent knot\nsame knot\nsame knot\n",
    });
}

test "diverts/complex_tunnels.ink" {
    try expect_fixture("runtime/diverts/complex_tunnels.ink", &.{}, .{
        .exact = "one (1)\none and a half (1.5)\ntwo (2)\nthree (3)\n",
    });
}

test "diverts/divert_in_conditional.ink" {
    try expect_fixture("runtime/diverts/divert_in_conditional.ink", &.{}, .{ .exact = "" });
}

test "diverts/divert_targets_with_parameters.ink" {
    const path = "runtime/diverts/divert_targets_with_parameters.ink";
    try expect_fixture(path, &.{}, .{ .exact = "5\n" });
}

test "diverts/divert_to_weave_points.ink" {
    try expect_fixture("runtime/diverts/divert_to_weave_points.ink", &.{}, .{
        .has = &.{ "gather", "second time round" },
    });
}

test "diverts/done_stops_thread.ink" {
    try expect_fixture("runtime/diverts/done_stops_thread.ink", &.{}, .{ .exact = "" });
}

test "diverts/tunnel_onwards_divert_after_with_arg.ink" {
    const path = "runtime/diverts/tunnel_onwards_divert_after_with_arg.ink";
    try expect_fixture(path, &.{}, .{ .exact = "8\n" });
}

test "diverts/tunnel_onwards_divert_override.ink" {
    try expect_fixture("runtime/diverts/tunnel_onwards_divert_override.ink", &.{}, .{
        .exact = "This is A\nNow in B.\n",
    });
}

test "diverts/tunnel_onwards_to_variable_divert_target.ink" {
    const path = "runtime/diverts/tunnel_onwards_to_variable_divert_target.ink";
    try expect_fixture(path, &.{}, .{ .exact = "This is outer\nThis is the_esc\n" });
}

test "diverts/tunnel_onwards_with_param_default_choice.ink" {
    const path = "runtime/diverts/tunnel_onwards_with_param_default_choice.ink";
    try expect_fixture(path, &.{}, .{ .exact = "8\n" });
}

test "diverts/path_to_self.ink" {
    try expect_fixture("runtime/diverts/path_to_self.ink", &.{ 0, 0 }, .{ .has = &.{"A"} });
}

test "diverts/tunnel_vs_thread_behaviour.ink" {
    try expect_fixture("runtime/diverts/tunnel_vs_thread_behaviour.ink", &.{ 0, 2 }, .{
        .has = &.{"Done."},
    });
}

// ── Knots ─────────────────────────────────────────────────────────────────────

test "knots/knot_do_not_gather.ink" {
    try expect_fixture("runtime/knots/knot_do_not_gather.ink", &.{}, .{ .exact = "g\n" });
}

test "knots/knot_stitch_gather_counts.ink" {
    try expect_fixture("runtime/knots/knot_stitch_gather_counts.ink", &.{}, .{
        .has = &.{ "1 1", "3" },
    });
}

test "knots/knot_thread_interaction.ink" {
    try expect_fixture("runtime/knots/knot_thread_interaction.ink", &.{ 0, 0 }, .{
        .has = &.{"blah blah"},
    });
}

test "knots/knot_thread_interaction_2.ink" {
    try expect_fixture("runtime/knots/knot_thread_interaction_2.ink", &.{}, .{
        .has = &.{"tunnel"},
    });
}

// ── Threads ───────────────────────────────────────────────────────────────────

test "threads/multi_thread.ink" {
    try expect_fixture("runtime/threads/multi_thread.ink", &.{ 0, 0 }, .{
        .has = &.{ "place 1", "The end" },
    });
}

test "threads/top_flow_terminator_should_not_kill_thread_choices.ink" {
    const path = "runtime/threads/top_flow_terminator_should_not_kill_thread_choices.ink";
    try expect_fixture(path, &.{0}, .{ .nonempty = true });
}

// ── Built-ins ─────────────────────────────────────────────────────────────────

test "builtins/floor_ceiling_and_casts.ink" {
    try expect_fixture("runtime/builtins/floor_ceiling_and_casts.ink", &.{}, .{
        .exact = "1\n1\n2\n0.6666667\n0\n1\n",
    });
}

test "builtins/visit_count_bug_due_to_nested_containers.ink" {
    const path = "runtime/builtins/visit_count_bug_due_to_nested_containers.ink";
    try expect_fixture(path, &.{0}, .{ .exact = "1\nchoice\n1\n" });
}

test "builtins/read_count_dot_separated_path.ink" {
    try expect_fixture("runtime/builtins/read_count_dot_separated_path.ink", &.{}, .{
        .exact = "hi\nhi\nhi\n3\n",
    });
}

test "builtins/turns_since_nested.ink" {
    try expect_fixture("runtime/builtins/turns_since_nested.ink", &.{ 0, 0 }, .{
        .exact = "-1 = -1\nstuff\n0 = 0\nmore stuff\n1 = 1\n",
    });
}

test "builtins/read_count_across_threads.ink" {
    try expect_fixture("runtime/builtins/read_count_across_threads.ink", &.{0}, .{
        .nonempty = true,
    });
}

test "builtins/read_count_variable_target.ink" {
    try expect_fixture("runtime/builtins/read_count_variable_target.ink", &.{}, .{
        .exact = "Count start: 0 0 0\n1\n2\n3\nCount end: 3 3 3\n",
    });
}

test "builtins/turns_since_with_variable_target.ink" {
    const path = "runtime/builtins/turns_since_with_variable_target.ink";
    try expect_fixture(path, &.{0}, .{ .exact = "0\n0\n1\n" });
}

test "choices/fallback_choice_on_thread.ink" {
    try expect_fixture("runtime/choices/fallback_choice_on_thread.ink", &.{}, .{
        .exact = "Should be 1 not 0: 1.\n",
    });
}

test "evaluation/evaluating_ink_functions_from_game.ink" {
    const path = "runtime/evaluation/evaluating_ink_functions_from_game.ink";
    try expect_fixture(path, &.{0}, .{ .has = &.{"Top level content"} });
}

test "evaluation/evaluating_ink_functions_from_game_2.ink" {
    const path = "runtime/evaluation/evaluating_ink_functions_from_game_2.ink";
    try expect_fixture(path, &.{}, .{ .exact = "One\nTwo\nThree\n" });
}

test "callstack/clean_callstack_reset_on_path_choice.ink" {
    const path = "runtime/callstack/clean_callstack_reset_on_path_choice.ink";
    try expect_fixture(path, &.{}, .{ .exact = "The first line.\nThe second line.\n" });
}

// ── Player ────────────────────────────────────────────────────────────────────

test "player/ink_error.ink" {
    try expect_fixture("player/ink_error.ink", &.{}, .{ .exact = "" });
}

test "player/ink_list_roundtrip.ink" {
    try expect_fixture("player/ink_list_roundtrip.ink", &.{}, .{ .exact = "Hello World.\n" });
}

// ── Booleans ──────────────────────────────────────────────────────────────────

test "booleans/false_plus_false.ink" {
    try expect_fixture("runtime/booleans/false_plus_false.ink", &.{}, .{ .exact = "0\n" });
}

test "booleans/list_hasnt.ink" {
    try expect_fixture("runtime/booleans/list_hasnt.ink", &.{}, .{ .exact = "true\n" });
}

test "booleans/not_one.ink" {
    try expect_fixture("runtime/booleans/not_one.ink", &.{}, .{ .exact = "false\n" });
}

test "booleans/not_true.ink" {
    try expect_fixture("runtime/booleans/not_true.ink", &.{}, .{ .exact = "false\n" });
}

test "booleans/three_greater_than_one.ink" {
    const path = "runtime/booleans/three_greater_than_one.ink";
    try expect_fixture(path, &.{}, .{ .exact = "true\n" });
}

test "booleans/true.ink" {
    try expect_fixture("runtime/booleans/true.ink", &.{}, .{ .exact = "true\n" });
}

test "booleans/true_equals_one.ink" {
    try expect_fixture("runtime/booleans/true_equals_one.ink", &.{}, .{ .exact = "true\n" });
}

test "booleans/true_plus_one.ink" {
    try expect_fixture("runtime/booleans/true_plus_one.ink", &.{}, .{ .exact = "2\n" });
}

test "booleans/true_plus_true.ink" {
    try expect_fixture("runtime/booleans/true_plus_true.ink", &.{}, .{ .exact = "2\n" });
}

test "booleans/two_plus_true.ink" {
    try expect_fixture("runtime/booleans/two_plus_true.ink", &.{}, .{ .exact = "3\n" });
}

// ── Integration stories: the compiled program and its JSON round trip ────────

fn ignore_error(_: ?*anyopaque, message: []const u8, _: Severity) void {
    assert(message.len < std.math.maxInt(u32));
}

/// A story's program as compiled, and the same program serialized to ink's JSON and loaded.
const Pair = struct {
    compiled: Program,
    loaded: Program,

    fn init(pair: *Pair, comptime path: []const u8) !void {
        assert(std.mem.endsWith(u8, path, ".ink"));
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path).?, .{});
        defer directory.close(io);
        pair.compiled = try compile.compile_file(gpa, io, directory, std.fs.path.basename(path));
        errdefer pair.compiled.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try ink_json.serialize(gpa, &pair.compiled, &out.writer);
        pair.loaded = try ink_json.load(gpa, out.written());
        errdefer pair.loaded.deinit(gpa);
        assert(pair.loaded.containers.len == pair.compiled.containers.len);
    }

    fn deinit(pair: *Pair) void {
        assert(pair.compiled.containers.len > 0);
        assert(pair.loaded.containers.len > 0);
        pair.compiled.deinit(std.testing.allocator);
        pair.loaded.deinit(std.testing.allocator);
    }

    /// Plays both programs through `choices`; their outputs and choices must agree.
    fn play(pair: *const Pair, choices: []const usize) !Played {
        assert(pair.compiled.containers.len > 0);
        const gpa = std.testing.allocator;
        const compiled = try play_program(&pair.compiled, choices);
        defer gpa.free(compiled.output);
        const loaded = try play_program(&pair.loaded, choices);
        errdefer gpa.free(loaded.output);
        try std.testing.expectEqualStrings(compiled.output, loaded.output);
        try std.testing.expectEqual(compiled.choices_count, loaded.choices_count);
        assert(loaded.output.len < std.math.maxInt(u32));
        return loaded;
    }
};

const Played = struct {
    output: []u8,
    /// The choices offered when the story stopped.
    choices_count: u32,
};

/// Plays `program` as e2e_new_vm.play does: choosing whenever it can't continue.
fn play_program(program: *const Program, choices: []const usize) !Played {
    assert(program.containers.len > 0);
    const gpa = std.testing.allocator;
    var story: vm.Story = undefined;
    try story.init(gpa, program, .{ .on_error = ignore_error });
    defer story.deinit(gpa);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var chosen: usize = 0;
    for (0..steps_max) |_| {
        const waiting = story.current_choices_count() > 0 and !story.can_continue();
        if (waiting and chosen < choices.len) {
            try story.choose_choice_index(@intCast(choices[chosen]));
            chosen += 1;
            continue;
        }
        if (!story.can_continue()) break;
        const line = try story.cont_alloc(gpa);
        defer gpa.free(line);
        try output.appendSlice(gpa, line);
    }
    assert(chosen <= choices.len);
    const choices_count = story.current_choices_count();
    assert(choices_count == 0 or !story.can_continue());
    return .{ .output = try output.toOwnedSlice(gpa), .choices_count = choices_count };
}

/// Plays `choices` on both programs of `pair` and checks the output.
fn expect_pair(pair: *const Pair, choices: []const usize, expect: Expect) !void {
    assert(pair.compiled.containers.len > 0);
    assert(choices.len < 64);
    const played = try pair.play(choices);
    defer std.testing.allocator.free(played.output);
    try expect_output(played.output, expect);
}

test "simple_taster_tutorial.ink - all choice paths" {
    // Choice tree (all 8 paths), every one converging at "we passed the day in silence":
    //   [1]           silent ("said nothing")
    //   [0,1]         the "Ah." branch
    //   [0,0,0,0..2]  "A wager!", "But surely", then post-gather choice 0, 1 or 2
    //   [0,0,1,0..2]  "A wager!", "Most serious", then post-gather choice 0, 1 or 2
    var pair: Pair = undefined;
    try pair.init("test/fixture/simple_taster_tutorial.ink");
    defer pair.deinit();
    const foolish = "surely that is foolishness";
    const serious = "most serious matter";
    try expect_taster(&pair, &.{1}, &.{"said nothing"});
    try expect_taster(&pair, &.{ 0, 1 }, &.{"uncertain what I thought"});
    try expect_taster(&pair, &.{ 0, 0, 0, 0 }, &.{ foolish, "endeavour to find out" });
    try expect_taster(&pair, &.{ 0, 0, 0, 1 }, &.{ foolish, "Twenty thousand pounds" });
    try expect_taster(&pair, &.{ 0, 0, 0, 2 }, &.{ foolish, "polite cough" });
    try expect_taster(&pair, &.{ 0, 0, 1, 0 }, &.{ serious, "endeavour to find out" });
    try expect_taster(&pair, &.{ 0, 0, 1, 1 }, &.{ serious, "Twenty thousand pounds" });
    try expect_taster(&pair, &.{ 0, 0, 1, 2 }, &.{ serious, "polite cough" });
}

/// A path through simple_taster_tutorial: its own phrases, then the common ending.
fn expect_taster(pair: *const Pair, choices: []const usize, phrases: []const []const u8) !void {
    assert(choices.len > 0);
    assert(phrases.len > 0);
    try expect_pair(pair, choices, .{ .has = phrases });
    try expect_pair(pair, choices, .{ .has = &.{"we passed the day in silence"} });
}

const crime_scene = "test/fixture/crime_scene.ink";

test "crime_scene.ink - initial scene loads" {
    var pair: Pair = undefined;
    try pair.init(crime_scene);
    defer pair.deinit();
    try expect_pair(&pair, &.{}, .{ .has = &.{"bedroom"} });
}

test "crime_scene.ink - examine desk and get cane" {
    var pair: Pair = undefined;
    try pair.init(crime_scene);
    defer pair.deinit();
    try expect_pair(&pair, &.{ 1, 0 }, .{ .has = &.{ "desk", "cane" } });
}

test "weave trailing gather divert waits until after choice" {
    // A minimal weave with `- -> h` after a nested `* *` under `(h)` (crime_scene's bedhub).
    // The gather leads back to itself with no choices left: ink loops forever, and the VM
    // stops at its choice limit.
    const path = "test/fixture/runtime/weaves/trailing_gather_loop.ink";
    const result = e2e_new_vm.play(std.testing.allocator, "", path, &.{0});
    try std.testing.expectError(error.ChoiceLimit, result);
}

test "crime_scene.ink - examine bed fully" {
    var pair: Pair = undefined;
    try pair.init(crime_scene);
    defer pair.deinit();
    try expect_pair(&pair, &.{ 0, 0, 0, 0 }, .{ .has = &.{ "neatly made", "crumpled" } });
}

test "crime_scene.ink - examine window" {
    // The top, the window, look down, look at the glass.
    var pair: Pair = undefined;
    try pair.init(crime_scene);
    defer pair.deinit();
    try expect_pair(&pair, &.{ 2, 0 }, .{ .has = &.{ "window", "brook" } });
}

const depth_max = 3;

/// A choice sequence of at most `depth_max` choices.
const Path = struct {
    choices: [depth_max]u32 = undefined,
    len: u32 = 0,

    fn slice(path: *const Path, buffer: *[depth_max]usize) []const usize {
        assert(path.len <= depth_max);
        for (path.choices[0..path.len], buffer[0..path.len]) |choice, *wide| wide.* = choice;
        const result = buffer[0..path.len];
        assert(result.len == path.len);
        return result;
    }
};

test "crime_scene.ink - all states reachable within 3 choices" {
    // Explores every choice sequence up to three choices deep, with an explicit stack. At
    // each node both programs must play the same.
    var pair: Pair = undefined;
    try pair.init(crime_scene);
    defer pair.deinit();
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(Path) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{});
    var visited: u32 = 0;
    while (stack.pop()) |path| {
        visited += 1;
        var buffer: [depth_max]usize = undefined;
        const played = try pair.play(path.slice(&buffer));
        gpa.free(played.output);
        if (path.len == depth_max) continue;
        for (0..played.choices_count) |choice| {
            var next = path;
            next.choices[next.len] = @intCast(choice);
            next.len += 1;
            try stack.append(gpa, next);
        }
    }
    try std.testing.expect(visited > 1);
}
