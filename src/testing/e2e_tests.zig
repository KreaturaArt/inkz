//! The compiler's end-to-end tests: each story is compiled from source and played through a
//! fixed list of choices, choosing whenever the story can't continue (`support.play`). They
//! began as the old compiler's e2e tests; where the old pipeline differed from ink, the
//! expectation is what ink prints. Stories checked by their output alone are rows of
//! `source_rows` and `fixture_rows`; tests that need more steps follow them. The tests that
//! drive the story API directly live in e2e_api.zig.

const std = @import("std");
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const support = @import("support.zig");

const fixtures = "test/fixture/original/";

/// What a played story's output must be: exactly `exact`, and/or contain every part of `has`
/// and none of `lacks`.
const Expect = struct {
    exact: ?[]const u8 = null,
    has: []const []const u8 = &.{},
    lacks: []const []const u8 = &.{},
    nonempty: bool = false,
};

fn expect_output(output: []const u8, expect: Expect) !void {
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

/// Compiles the fixture at `path` (from the repository root) and plays it.
fn play_file(gpa: std.mem.Allocator, path: []const u8, choices: []const u32) ![]u8 {
    var program = try support.compile_fixture(gpa, std.testing.io, path);
    defer program.deinit(gpa);
    return (try support.play(gpa, &program, choices)).output;
}

/// Plays the fixture `path` (under test/fixture/original/) and checks its output.
fn expect_fixture(path: []const u8, choices: []const u32, expect: Expect) !void {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ fixtures, path });
    const output = try play_file(gpa, full_path, choices);
    defer gpa.free(output);
    try expect_output(output, expect);
}

/// Plays the inline story `source` and checks its output.
fn expect_source(source: []const u8, choices: []const u32, expect: Expect) !void {
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const played = try support.play(gpa, &program, choices);
    defer gpa.free(played.output);
    try expect_output(played.output, expect);
}

/// An inline story checked by its output.
const SourceRow = struct {
    name: []const u8,
    source: []const u8,
    choices: []const u32 = &.{},
    expect: Expect,
};

/// A fixture checked by its output; `path`, below test/fixture/original/, names the row.
const FixtureRow = struct {
    path: []const u8,
    choices: []const u32 = &.{},
    expect: Expect,
};

test "source rows" {
    for (source_rows) |row| {
        expect_source(row.source, row.choices, row.expect) catch |err| {
            std.debug.print("source row failed: {s}\n", .{row.name});
            return err;
        };
    }
}

test "fixture rows" {
    for (fixture_rows) |row| {
        expect_fixture(row.path, row.choices, row.expect) catch |err| {
            std.debug.print("fixture row failed: {s}\n", .{row.path});
            return err;
        };
    }
}

test "no table row goes missing" {
    // Goal: deleting a row is a visible change. Method: the tables' sizes are pinned.
    try std.testing.expectEqual(source_rows_count, source_rows.len);
    try std.testing.expectEqual(fixture_rows_count, fixture_rows.len);
}

const source_rows = [_]SourceRow{
    // Basics
    .{ .name = "empty story", .source = "", .expect = .{ .exact = "" } },
    .{
        .name = "hello world inline",
        .source = "Hello world\n",
        .expect = .{ .exact = "Hello world\n" },
    },
    .{
        .name = "text with END",
        .source =
        \\hello
        \\-> END
        \\world
        \\-> END
        ,
        .expect = .{ .exact = "hello\n" },
    },
    .{
        .name = "divert to knot then END",
        .source =
        \\-> test
        \\== test ==
        \\hello
        \\-> END
        \\world
        \\-> END
        ,
        .expect = .{ .exact = "hello\n" },
    },
    .{
        .name = "multi-knot story",
        .source =
        \\-> firstKnot
        \\=== firstKnot
        \\Hello!
        \\-> anotherKnot
        \\=== anotherKnot
        \\World.
        \\-> END
        ,
        .expect = .{ .exact = "Hello!\nWorld.\n" },
    },

    // Expressions
    .{ .name = "inline boolean true", .source = "{true}\n", .expect = .{ .exact = "true\n" } },
    .{ .name = "inline boolean false", .source = "{false}\n", .expect = .{ .exact = "false\n" } },
    .{ .name = "inline not true", .source = "{not true}\n", .expect = .{ .exact = "false\n" } },
    .{ .name = "inline comparison 3 > 1", .source = "{3 > 1}\n", .expect = .{ .exact = "true\n" } },
    .{ .name = "inline arithmetic 2 + 3", .source = "{2 + 3}\n", .expect = .{ .exact = "5\n" } },

    // Variables
    .{ .name = "VAR inline ref", .source = "VAR x = 5\n{x}\n", .expect = .{ .exact = "5\n" } },
    .{ .name = "temp var", .source = "~ temp y = 4\n{y}\n", .expect = .{ .exact = "4\n" } },
    .{
        .name = "temp reassignment",
        .source = "~ temp y = 1\n~ y = 7\n{y}\n",
        .expect = .{ .exact = "7\n" },
    },
    .{
        .name = "CONST substitution in VAR",
        .source = "CONST c = 5\nVAR x = c\n{x}\n",
        .expect = .{ .exact = "5\n" },
    },

    // Conditionals
    .{
        .name = "inline if/else — false branch taken",
        .source = "{false:not true|true}\n",
        .expect = .{
            .has = &.{"true"},
            .lacks = &.{"not true"},
        },
    },
    .{
        .name = "block conditional — false branch skipped",
        .source =
        \\{
        \\- false:
        \\   beep
        \\}
        ,
        .expect = .{ .lacks = &.{"beep"} },
    },
    .{
        .name = "multi-branch — second branch taken",
        .source =
        \\{
        \\   - 4 > 5: not true
        \\   - 5 > 4: yes
        \\}
        ,
        .expect = .{ .has = &.{"yes"}, .lacks = &.{"not true"} },
    },
    .{
        .name = "outer condition with else — else taken",
        .source =
        \\{ 2 > 5:
        \\   - no
        \\   - yes
        \\}
        ,
        .expect = .{ .has = &.{"yes"}, .lacks = &.{"no"} },
    },
    .{
        .name = "switch — matching branch taken",
        .source =
        \\{ 6:
        \\   - 5: wrong
        \\   - 6: right
        \\   - 7: wrong
        \\}
        ,
        .expect = .{ .has = &.{"right"}, .lacks = &.{"wrong"} },
    },

    // Functions
    .{
        .name = "function return bare",
        .source =
        \\{ greet() }
        \\-> END
        \\== function greet ==
        \\hello
        \\~ return
        ,
        .expect = .{ .has = &.{"hello"} },
    },
    .{
        .name = "function with params",
        .source =
        \\{ add(3, 4) }
        \\-> END
        \\== function add(x, y) ==
        \\~ return x + y
        ,
        .expect = .{ .exact = "7\n" },
    },

    // Increment and decrement
    .{
        .name = "x++ increment",
        .source =
        \\VAR x = 0
        \\~ x++
        \\~ x++
        \\{x}
        ,
        .expect = .{ .exact = "2\n" },
    },
    .{
        .name = "x-- decrement",
        .source =
        \\VAR x = 5
        \\~ x--
        \\{x}
        ,
        .expect = .{ .exact = "4\n" },
    },
    .{
        .name = "x++ in VAR context",
        .source =
        \\VAR n = 10
        \\~ n--
        \\~ n--
        \\{n}
        ,
        .expect = .{ .exact = "8\n" },
    },

    // Glue and tags
    .{
        .name = "glue inline",
        .source = "hello<> world\n",
        .expect = .{ .exact = "hello world\n" },
    },
    // Tags produce no text; the story's content still does.
    .{
        .name = "tags — standalone hash tag line",
        .source =
        \\# author: Joe
        \\Hello world
        ,
        .expect = .{ .has = &.{"Hello world"} },
    },

    // Divert targets and standalone calls
    .{
        .name = "standalone function call ~ f()",
        .source =
        \\VAR n = 0
        \\~ setN(5)
        \\{n}
        \\== function setN(x) ==
        \\~ n = x
        \\~ return
        ,
        .expect = .{ .exact = "5\n" },
    },

    // Sequences
    .{
        .name = "inline stopping sequence {a|b}",
        .source =
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{one|two}
        \\->->
        ,
        .expect = .{ .has = &.{"one"} },
    },
    .{
        .name = "block stopping sequence",
        .source =
        \\-> seq ->
        \\-> seq ->
        \\-> END
        \\== seq ==
        \\{stopping:
        \\- first
        \\- second
        \\}
        \\->->
        ,
        .expect = .{ .has = &.{"first"} },
    },
    .{
        .name = "inline cycle sequence {&a|b}",
        .source =
        \\-> thing ->
        \\-> thing ->
        \\-> thing ->
        \\-> END
        \\== thing ==
        \\{&one|two}
        \\->->
        ,
        .expect = .{ .has = &.{"one"} },
    },

    // Glue, newlines, strings, tags
    .{
        .name = "string_contains — ? operator",
        .source =
        \\{"hello world" ? "o wo"}
        \\{"hello world" ? "nope"}
        ,
        .expect = .{ .exact = "true\nfalse\n" },
    },
    .{
        .name = "LIST more_list_operations inline",
        .source =
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
        ,
        .expect = .{ .exact = "1\nl\nn\nl, m\nn\n" },
    },
};

const fixture_rows = [_]FixtureRow{
    // Basics
    .{ .path = "runtime/misc/hello_world.ink", .expect = .{ .exact = "Hello world\n" } },
    .{ .path = "runtime/misc/empty.ink", .expect = .{ .exact = "" } },
    .{ .path = "runtime/misc/end.ink", .expect = .{ .exact = "hello\n" } },
    .{ .path = "runtime/misc/end2.ink", .expect = .{ .exact = "hello\n" } },
    // The story has a knot "test" but no root-level divert to it: the output is empty.
    .{ .path = "runtime/misc/end_of_content.ink", .expect = .{ .exact = "" } },
    .{ .path = "runtime/misc/whitespace.ink", .expect = .{ .exact = "Hello!\nWorld.\n" } },
    .{
        .path = "runtime/misc/includes/included_file.ink",
        .expect = .{ .exact = "This is include 1.\n" },
    },
    .{
        .path = "runtime/misc/includes/included_file_2.ink",
        .expect = .{ .exact = "This is include 2.\n" },
    },
    .{ .path = "runtime/misc/includes/included_file_4.ink", .expect = .{ .has = &.{"5"} } },

    // Expressions
    .{ .path = "runtime/evaluation/arithmetic.ink", .expect = .{
        .exact = "36\n2\n3\n2\n2.3333333\n8\n8\n",
    } },

    // Variables
    .{
        .path = "runtime/variables/temporaries_at_global_scope.ink",
        .expect = .{ .exact = "54\n" },
    },
    .{ .path = "runtime/variables/const.ink", .expect = .{ .exact = "5\n" } },

    // Conditionals
    .{ .path = "runtime/conditions/trivial_condition.ink", .expect = .{
        .lacks = &.{"beep"},
    } },
    .{ .path = "runtime/conditions/else_branches.ink", .expect = .{
        .has = &.{"other"},
        .lacks = &.{ "one", "two" },
    } },
    .{ .path = "runtime/conditions/conditionals.ink", .expect = .{
        .has = &.{ "true", "great" },
        .lacks = &.{"not true"},
    } },
    .{
        .path = "runtime/conditions/all_switch_branches_fail_is_clean.ink",
        .expect = .{ .lacks = &.{ "x", "y" } },
    },
    .{
        .path = "runtime/conditions/empty_multiline_conditional_branch.ink",
        .expect = .{ .lacks = &.{"txt"} },
    },

    // Choices and weaves
    .{ .path = "runtime/choices/default_simple_gather.ink", .expect = .{ .has = &.{"x"} } },
    .{
        .path = "runtime/choices/choice_with_brackets_only.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"Text"} },
    },
    .{
        .path = "runtime/choices/choice_diverts_to_done.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"choice"} },
    },
    // Two sticky choices loop back to test; choose the first three times, then stop.
    .{
        .path = "runtime/choices/sticky_choices_stay_sticky.ink",
        .choices = &.{ 0, 0, 0 },
        .expect = .{ .has = &.{ "First line.", "Choice 1" } },
    },
    .{
        .path = "runtime/weaves/weave_options.ink",
        .choices = &.{0},
        .expect = .{ .exact = "Hello, world.\n" },
    },
    .{
        .path = "runtime/choices/non_text_in_choice_inner_content.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{ "option text", "Next." } },
    },
    .{ .path = "runtime/choices/gather_choice_same_line.ink", .choices = &.{0}, .expect = .{
        .has = &.{"hello"},
    } },
    // ink offers "one", "two", "three", "four"; the second is "two".
    .{
        .path = "runtime/choices/conditional_choices.ink",
        .choices = &.{1},
        .expect = .{ .exact = "two\n" },
    },
    .{ .path = "runtime/choices/has_read_on_choice.ink", .choices = &.{0}, .expect = .{
        .has = &.{"visible choice"},
    } },
    .{ .path = "runtime/choices/logic_in_choices.ink", .choices = &.{0}, .expect = .{
        .has = &.{ "Joe", "Hello" },
    } },

    // Functions
    .{ .path = "runtime/callstack/callstack_evaluation.ink", .expect = .{ .exact = "8\n" } },
    .{ .path = "runtime/variables/variable_swap_recurse.ink", .expect = .{ .has = &.{"2"} } },

    // Glue and tags
    .{ .path = "runtime/glue/simple_glue.ink", .expect = .{
        .exact = "Some content with glue.\n",
    } },

    // Lists
    // LIST list = a, (b), c, (d), e: b and d are selected.
    .{ .path = "runtime/lists/list_basic_operations.ink", .expect = .{
        .exact = "b, d\na, b, c, e\nb, c\nfalse\ntrue\ntrue\n",
    } },
    .{ .path = "runtime/lists/empty_list_origin.ink", .expect = .{ .exact = "a, b\n" } },
    .{ .path = "runtime/lists/more_list_operations.ink", .expect = .{
        .exact = "1\nl\nn\nl, m\nn\n",
    } },
    .{
        .path = "runtime/lists/contains_empty_list_always_false.ink",
        .expect = .{ .exact = "false\nfalse\nfalse\n" },
    },
    .{
        .path = "runtime/lists/empty_list_origin_after_assignment.ink",
        .expect = .{ .exact = "a, b, c\n" },
    },
    .{ .path = "runtime/lists/list_mixed_items.ink", .expect = .{ .exact = "a, y, c\n" } },
    .{ .path = "runtime/lists/list_range.ink", .expect = .{
        .has = &.{ "Two, Three, Four, Five, Six\n", "Pizza" },
    } },
    .{ .path = "runtime/lists/list_save_load.ink", .expect = .{ .exact = "a, x, c\n" } },

    // Divert targets and standalone calls
    .{ .path = "runtime/variables/variable_divert_target.ink", .expect = .{ .exact = "Here.\n" } },
    .{
        .path = "runtime/variables/multiple_constant_references.ink",
        .expect = .{ .has = &.{"success"} },
    },
    .{
        .path = "runtime/variables/variable_declaration_in_conditional.ink",
        .expect = .{ .has = &.{"5"} },
    },

    // Named gathers, choice labels, nested choices
    // The nested weave's choices are all filtered, so its invisible default goes to END and
    // "gather" is never reached.
    .{
        .path = "runtime/choices/should_not_gather_due_to_choice.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"text"}, .lacks = &.{"gather"} },
    },
    // Choose "one", which has the nested choice "two" and the gather "three".
    .{ .path = "runtime/weaves/weave_gathers.ink", .choices = &.{ 0, 0 }, .expect = .{
        .has = &.{ "one", "two", "six" },
    } },
    .{ .path = "runtime/choices/default_choices.ink", .choices = &.{0}, .expect = .{
        .has = &.{"After choice"},
    } },
    // A choice label, a condition on it and a named gather: it must just run.
    .{
        .path = "runtime/choices/once_only_choices_can_link_back_to_self.ink",
        .choices = &.{ 0, 0 },
        .expect = .{},
    },

    // Tunnels
    .{ .path = "runtime/diverts/basic_tunnel.ink", .expect = .{ .exact = "Hello world\n" } },
    .{ .path = "runtime/callstack/callstack_evaluation.ink", .expect = .{ .exact = "8\n" } },
    .{ .path = "runtime/diverts/tunnel_onwards_after_tunnel.ink", .expect = .{
        .exact = "Hello...\n...world.\nThe End.\n",
    } },

    // Sequences
    .{ .path = "runtime/sequences/leading_newline_multiline_sequence.ink", .expect = .{} },
    .{ .path = "runtime/sequences/empty_sequence_content.ink", .expect = .{} },

    // Glue, newlines, strings, tags
    .{ .path = "runtime/glue/left_right_glue_matching.ink", .expect = .{
        .has = &.{ "A line.", "Another line." },
    } },
    .{ .path = "runtime/newlines/newline_consistency_1.ink", .expect = .{
        .has = &.{ "hello", "world" },
    } },
    .{ .path = "runtime/newlines/newline_consistency_2.ink", .choices = &.{0}, .expect = .{
        .has = &.{"world"},
    } },
    .{ .path = "runtime/strings/string_constants.ink", .expect = .{ .exact = "hi\n" } },
    .{ .path = "runtime/tags/tags.ink", .expect = .{ .has = &.{"This is the content"} } },
    .{
        .path = "runtime/newlines/newline_at_start_of_multiline_conditional.ink",
        .expect = .{ .exact = "X\nx\n" },
    },

    // Threads and built-ins
    .{ .path = "runtime/builtins/turns.ink", .choices = &.{0}, .expect = .{ .exact = "0\n1\n" } },
    .{ .path = "runtime/builtins/turns_since.ink", .choices = &.{ 0, 0 }, .expect = .{
        .exact = "-1\n0\n1\n2\n",
    } },
    .{
        .path = "runtime/choices/choice_count.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"2"} },
    },
    .{ .path = "runtime/builtins/read_count_across_callstack.ink", .expect = .{
        .exact = "1) Seen first 1 times.\nIn second.\n2) Seen first 1 times.\n",
    } },
    .{ .path = "runtime/threads/thread_in_logic.ink", .expect = .{ .has = &.{"Content"} } },
    .{ .path = "runtime/threads/thread_done.ink", .expect = .{} },

    // Evaluation
    .{ .path = "runtime/evaluation/factorial_recursive.ink", .expect = .{ .exact = "120\n" } },
    .{ .path = "runtime/evaluation/literal_unary.ink", .expect = .{
        .exact = "-1\nfalse\ntrue\n",
    } },
    .{ .path = "runtime/evaluation/basic_string_literals.ink", .expect = .{
        .exact = "Hello world 1\nHello world 2.\n",
    } },
    .{ .path = "runtime/evaluation/increment.ink", .expect = .{ .exact = "6\n5\n" } },
    .{ .path = "runtime/evaluation/evaluation_stack_leaks.ink", .expect = .{
        .exact = "else\nelse\nhi\n",
    } },
    .{
        .path = "runtime/evaluation/evaluating_function_variable_state_bug.ink",
        .expect = .{ .exact = "Start\nIn tunnel.\nEnd\n" },
    },
    .{ .path = "runtime/evaluation/factorial_by_reference.ink", .expect = .{ .exact = "120\n" } },

    // Logic
    .{ .path = "runtime/logic/logic_lines_with_newlines.ink", .expect = .{
        .exact = "text1\ntext 2\ntext1\ntext 2\n",
    } },
    .{ .path = "runtime/logic/multiline_logic_with_glue.ink", .expect = .{
        .exact = "a b\na b\n",
    } },
    .{ .path = "runtime/logic/nested_pass_by_reference.ink", .expect = .{
        .exact = "5\n625\n",
    } },
    .{ .path = "runtime/logic/print_num.ink", .expect = .{
        .has = &.{ "four", "fifteen", "thirty-seven" },
    } },

    // Extra
    .{ .path = "runtime/extra/arithmetic_2.ink", .expect = .{
        .exact = "2\n2.3333333\n2.3333333\n2.3333333\n2.3333333\n2.3333333\n",
    } },
    .{ .path = "runtime/extra/list_comparison.ink", .expect = .{
        .has = &.{ "Philippe", "Andre" },
    } },
    .{ .path = "runtime/glue/implicit_inline_glue.ink", .expect = .{
        .exact = "I have five eggs.\n",
    } },
    .{ .path = "runtime/glue/implicit_inline_glue_b.ink", .expect = .{ .exact = "A\nX\n" } },
    .{ .path = "runtime/glue/implicit_inline_glue_c.ink", .expect = .{ .exact = "A\nC\n" } },

    // Misc
    .{ .path = "runtime/misc/escape_character.ink", .expect = .{
        .exact = "this is a '|' character\n",
    } },
    .{ .path = "runtime/misc/identifiers_can_start_with_number.ink", .expect = .{
        .exact = "512x2 = 1024\n512x2p2 = 1026\n",
    } },
    .{ .path = "runtime/misc/quote_character_significance.ink", .expect = .{
        .has = &.{"Joe"},
    } },
    .{ .path = "runtime/strings/string_contains.ink", .expect = .{
        .exact = "true\nfalse\ntrue\ntrue\n",
    } },

    // Newlines
    .{ .path = "runtime/newlines/newline_consistency_3.ink", .choices = &.{0}, .expect = .{
        .exact = "hello\nworld\n",
    } },
    .{ .path = "runtime/newlines/newlines_with_string_eval.ink", .expect = .{
        .exact = "A\nB\nA\n3\nB\n",
    } },

    // Sequences
    .{ .path = "runtime/sequences/all_sequence_types.ink", .expect = .{
        .has = &.{ "Once:", "Stopping:", "Cycle:" },
    } },
    .{ .path = "runtime/sequences/blanks_in_inline_sequences.ink", .expect = .{
        .has = &.{ "1. a", "3. b" },
    } },
    .{
        .path = "runtime/sequences/gather_read_count_with_initial_sequence.ink",
        .expect = .{ .exact = "seen test\n" },
    },
    .{ .path = "runtime/sequences/shuffle_stack_muddying.ink", .expect = .{ .exact = "" } },

    // Strings
    .{ .path = "runtime/strings/string_type_coercion.ink", .expect = .{
        .exact = "same\ndifferent\n",
    } },
    .{ .path = "runtime/strings/strings_in_choices.ink", .choices = &.{0}, .expect = .{
        .exact = "test1 test4\n",
    } },

    // Tags
    .{ .path = "runtime/tags/tags_dynamic_content.ink", .expect = .{ .exact = "tag\n" } },
    .{
        .path = "runtime/tags/tags_in_choice.ink",
        .choices = &.{0},
        .expect = .{ .exact = "one three" },
    },
    .{ .path = "runtime/tags/tags_in_seq.ink", .expect = .{
        .exact = "A red sequence.\nA white sequence.\n",
    } },

    // Variables
    .{
        .path = "runtime/variables/variable_pointer_ref_from_knot.ink",
        .expect = .{ .exact = "6\n" },
    },
    .{ .path = "runtime/variables/variable_tunnel.ink", .expect = .{ .exact = "STUFF\n" } },
    .{ .path = "runtime/variables/temp_usage_in_options.ink", .choices = &.{0}, .expect = .{
        .exact = "1\nEnd of choice\nthis another\n",
    } },
    .{
        .path = "runtime/variables/set_non_existant_variable.ink",
        .expect = .{ .exact = "Hello world.\n" },
    },
    .{ .path = "runtime/variables/temp_global_conflict.ink", .expect = .{ .exact = "0\n" } },
    .{ .path = "runtime/variables/temp_not_found.ink", .expect = .{ .exact = "0\nhello\n" } },
    .{
        .path = "runtime/variables/warn_variable_not_found_1.ink",
        .expect = .{ .exact = "Hello world!\n0\n" },
    },
    .{
        .path = "runtime/variables/warn_variable_not_found_2.ink",
        .expect = .{ .exact = "Hello world!\n0\n" },
    },

    // Weaves
    .{ .path = "runtime/weaves/conditional_choice_in_weave.ink", .choices = &.{0}, .expect = .{
        .exact = "start\ngather should be seen\nresult\n",
    } },
    .{ .path = "runtime/weaves/conditional_choice_in_weave_2.ink", .choices = &.{0}, .expect = .{
        .exact = "first gather\nthe main gather\nbottom gather\n",
    } },
    .{ .path = "runtime/weaves/weave_within_sequence.ink", .choices = &.{0}, .expect = .{
        .exact = "choice\nnextline\n",
    } },
    .{
        .path = "runtime/weaves/unbalanced_weave_indentation.ink",
        .choices = &.{ 0, 0 },
        .expect = .{
            .has = &.{"First"},
        },
    },

    // Choices
    .{
        .path = "runtime/choices/once_only_choices_with_own_content.ink",
        .choices = &.{ 0, 0, 0 },
        .expect = .{ .has = &.{ "first time", "finished eating" } },
    },
    .{ .path = "runtime/choices/various_default_choices.ink", .expect = .{
        .exact = "1\n2\n3\n",
    } },
    .{ .path = "runtime/choices/state_rollback_over_default_choice.ink", .expect = .{
        .exact = "Text.\n5\n",
    } },

    // Diverts
    .{ .path = "runtime/diverts/same_line_divert_is_inline.ink", .expect = .{
        .exact = "We hurried home to Savile Row as fast as we could.\n",
    } },
    .{ .path = "runtime/diverts/compare_divert_targets.ink", .expect = .{
        .exact = "different knot\nsame knot\nsame knot\ndifferent knot\nsame knot\nsame knot\n",
    } },
    .{ .path = "runtime/diverts/complex_tunnels.ink", .expect = .{
        .exact = "one (1)\none and a half (1.5)\ntwo (2)\nthree (3)\n",
    } },
    .{ .path = "runtime/diverts/divert_in_conditional.ink", .expect = .{ .exact = "" } },
    .{
        .path = "runtime/diverts/divert_targets_with_parameters.ink",
        .expect = .{ .exact = "5\n" },
    },
    .{ .path = "runtime/diverts/divert_to_weave_points.ink", .expect = .{
        .has = &.{ "gather", "second time round" },
    } },
    .{ .path = "runtime/diverts/done_stops_thread.ink", .expect = .{ .exact = "" } },
    .{
        .path = "runtime/diverts/tunnel_onwards_divert_after_with_arg.ink",
        .expect = .{ .exact = "8\n" },
    },
    .{ .path = "runtime/diverts/tunnel_onwards_divert_override.ink", .expect = .{
        .exact = "This is A\nNow in B.\n",
    } },
    .{
        .path = "runtime/diverts/tunnel_onwards_to_variable_divert_target.ink",
        .expect = .{ .exact = "This is outer\nThis is the_esc\n" },
    },
    .{
        .path = "runtime/diverts/tunnel_onwards_with_param_default_choice.ink",
        .expect = .{ .exact = "8\n" },
    },
    .{
        .path = "runtime/diverts/path_to_self.ink",
        .choices = &.{ 0, 0 },
        .expect = .{ .has = &.{"A"} },
    },
    .{ .path = "runtime/diverts/tunnel_vs_thread_behaviour.ink", .choices = &.{ 0, 2 }, .expect = .{
        .has = &.{"Done."},
    } },

    // Knots
    .{ .path = "runtime/knots/knot_do_not_gather.ink", .expect = .{ .exact = "g\n" } },
    .{ .path = "runtime/knots/knot_stitch_gather_counts.ink", .expect = .{
        .has = &.{ "1 1", "3" },
    } },
    .{ .path = "runtime/knots/knot_thread_interaction.ink", .choices = &.{ 0, 0 }, .expect = .{
        .has = &.{"blah blah"},
    } },
    .{ .path = "runtime/knots/knot_thread_interaction_2.ink", .expect = .{
        .has = &.{"tunnel"},
    } },

    // Threads
    .{ .path = "runtime/threads/multi_thread.ink", .choices = &.{ 0, 0 }, .expect = .{
        .has = &.{ "place 1", "The end" },
    } },
    .{
        .path = "runtime/threads/top_flow_terminator_should_not_kill_thread_choices.ink",
        .choices = &.{0},
        .expect = .{ .nonempty = true },
    },

    // Built-ins
    .{ .path = "runtime/builtins/floor_ceiling_and_casts.ink", .expect = .{
        .exact = "1\n1\n2\n0.6666667\n0\n1\n",
    } },
    .{
        .path = "runtime/builtins/visit_count_bug_due_to_nested_containers.ink",
        .choices = &.{0},
        .expect = .{ .exact = "1\nchoice\n1\n" },
    },
    .{ .path = "runtime/builtins/read_count_dot_separated_path.ink", .expect = .{
        .exact = "hi\nhi\nhi\n3\n",
    } },
    .{ .path = "runtime/builtins/turns_since_nested.ink", .choices = &.{ 0, 0 }, .expect = .{
        .exact = "-1 = -1\nstuff\n0 = 0\nmore stuff\n1 = 1\n",
    } },
    .{ .path = "runtime/builtins/read_count_across_threads.ink", .choices = &.{0}, .expect = .{
        .nonempty = true,
    } },
    .{ .path = "runtime/builtins/read_count_variable_target.ink", .expect = .{
        .exact = "Count start: 0 0 0\n1\n2\n3\nCount end: 3 3 3\n",
    } },
    .{
        .path = "runtime/builtins/turns_since_with_variable_target.ink",
        .choices = &.{0},
        .expect = .{ .exact = "0\n0\n1\n" },
    },
    .{ .path = "runtime/choices/fallback_choice_on_thread.ink", .expect = .{
        .exact = "Should be 1 not 0: 1.\n",
    } },
    .{
        .path = "runtime/evaluation/evaluating_ink_functions_from_game.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"Top level content"} },
    },
    .{
        .path = "runtime/evaluation/evaluating_ink_functions_from_game_2.ink",
        .expect = .{ .exact = "One\nTwo\nThree\n" },
    },
    .{
        .path = "runtime/callstack/clean_callstack_reset_on_path_choice.ink",
        .expect = .{ .exact = "The first line.\nThe second line.\n" },
    },

    // Player
    .{ .path = "player/ink_error.ink", .expect = .{ .exact = "" } },
    .{ .path = "player/ink_list_roundtrip.ink", .expect = .{ .exact = "Hello World.\n" } },

    // Booleans
    .{ .path = "runtime/booleans/false_plus_false.ink", .expect = .{ .exact = "0\n" } },
    .{ .path = "runtime/booleans/list_hasnt.ink", .expect = .{ .exact = "true\n" } },
    .{ .path = "runtime/booleans/not_one.ink", .expect = .{ .exact = "false\n" } },
    .{ .path = "runtime/booleans/not_true.ink", .expect = .{ .exact = "false\n" } },
    .{ .path = "runtime/booleans/three_greater_than_one.ink", .expect = .{ .exact = "true\n" } },
    .{ .path = "runtime/booleans/true.ink", .expect = .{ .exact = "true\n" } },
    .{ .path = "runtime/booleans/true_equals_one.ink", .expect = .{ .exact = "true\n" } },
    .{ .path = "runtime/booleans/true_plus_one.ink", .expect = .{ .exact = "2\n" } },
    .{ .path = "runtime/booleans/true_plus_true.ink", .expect = .{ .exact = "2\n" } },
    .{ .path = "runtime/booleans/two_plus_true.ink", .expect = .{ .exact = "3\n" } },
};

const source_rows_count = 32;
const fixture_rows_count = 150;

// ── Compiler JSON ─────────────────────────────────────────────────────────────

test "Compiler JSON: divert_to_weave_points" {
    const json = try compile.compile_to_json(std.testing.allocator,
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
    const json = try compile.compile_to_json(std.testing.allocator,
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
    const json = try compile.compile_to_json(std.testing.allocator,
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

// ── Stories that need more than their output ─────────────────────────────────

test "misc/includes/included_file_3.ink" {
    // Compiled on its own, its INCLUDE resolves from its own directory and fails, as in
    // inklecate (the old compiler ignored INCLUDE and printed nothing).
    const path = fixtures ++ "runtime/misc/includes/included_file_3.ink";
    const result = play_file(std.testing.allocator, path, &.{});
    try std.testing.expectError(error.CompileFailed, result);
}

test "misc/nested_include.ink" {
    const gpa = std.testing.allocator;
    const path = fixtures ++ "runtime/misc/nested_include.ink";
    var program = try support.compile_fixture(gpa, std.testing.io, path);
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "This is the main file") != null);
}

test "lists/list_random.ink" {
    const gpa = std.testing.allocator;
    const output = try play_file(gpa, fixtures ++ "runtime/lists/list_random.ink", &.{});
    defer gpa.free(output);
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, output, "\n"));
}

test "newlines/newlines_trimming_with_func_external_fallback.ink" {
    // The external has no binding and fallbacks are off: ink raises an error, as the VM does.
    const path = fixtures ++ "runtime/newlines/newlines_trimming_with_func_external_fallback.ink";
    const result = play_file(std.testing.allocator, path, &.{});
    try std.testing.expectError(error.MissingExternalBinding, result);
}

test "weave trailing gather divert waits until after choice" {
    // A minimal weave with `- -> h` after a nested `* *` under `(h)` (crime_scene's bedhub).
    // The gather leads back to itself with no choices left: ink loops forever, and the VM
    // stops at its choice limit.
    const path = "test/fixture/runtime/weaves/trailing_gather_loop.ink";
    const result = play_file(std.testing.allocator, path, &.{0});
    try std.testing.expectError(error.ChoiceLimit, result);
}

// ── Integration stories: the compiled program and its JSON round trip ────────

/// A story's program as compiled, and the same program serialized to ink's JSON and loaded.
const Pair = struct {
    compiled: Program,
    loaded: Program,

    fn init(pair: *Pair, path: []const u8) !void {
        const gpa = std.testing.allocator;
        pair.compiled = try support.compile_fixture(gpa, std.testing.io, path);
        errdefer pair.compiled.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try ink_json.serialize(gpa, &pair.compiled, &out.writer);
        pair.loaded = try ink_json.load(gpa, out.written());
    }

    fn deinit(pair: *Pair) void {
        pair.compiled.deinit(std.testing.allocator);
        pair.loaded.deinit(std.testing.allocator);
    }

    /// Plays both programs through `choices`; their outputs and choices must agree.
    fn play(pair: *const Pair, choices: []const u32) !support.Played {
        const gpa = std.testing.allocator;
        const compiled = try support.play(gpa, &pair.compiled, choices);
        defer gpa.free(compiled.output);
        const loaded = try support.play(gpa, &pair.loaded, choices);
        errdefer gpa.free(loaded.output);
        try std.testing.expectEqualStrings(compiled.output, loaded.output);
        try std.testing.expectEqual(compiled.choices_count, loaded.choices_count);
        return loaded;
    }
};

/// Plays `choices` on both programs of `pair` and checks the output.
fn expect_pair(pair: *const Pair, choices: []const u32, expect: Expect) !void {
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
fn expect_taster(pair: *const Pair, choices: []const u32, phrases: []const []const u8) !void {
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
        const played = try pair.play(path.choices[0..path.len]);
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
