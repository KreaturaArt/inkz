//! The old parser's 51 shape tests (src/compiler/parser.zig), ported to the new grammar
//! (plan P7.10). Each keeps the old test's input and checks the same facts on the new tree.
//! Where the old parser disagreed with ink, the expectation follows ink, and the test says so.

const std = @import("std");
const assert = std.debug.assert;
const dump = @import("dump.zig");

const fixtures = "test/fixture/original/";

/// The dump of `source` (tree, then diagnostics).
fn dump_of(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    assert(source.len < 1024 * 1024);
    var diagnostics: u32 = 0;
    const text = try dump.dump_alloc(arena, source, &diagnostics);
    assert(diagnostics <= std.mem.count(u8, text, "\n! ") + 1);
    return text;
}

fn dump_of_fixture(arena: std.mem.Allocator, comptime path: []const u8) ![]const u8 {
    assert(path.len > 0);
    const io = std.testing.io;
    const limit: std.Io.Limit = .limited(1024 * 1024);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, fixtures ++ path, arena, limit);
    assert(source.len > 0);
    return dump_of(arena, source);
}

/// Checks the whole dump.
fn expect_dump(source: []const u8, expected: []const u8) !void {
    assert(source.len < 1024 * 1024);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    assert(expected.len > 0);
    try std.testing.expectEqualStrings(expected, try dump_of(arena_state.allocator(), source));
}

/// Checks that the dump contains each of `parts`, and has no diagnostics.
fn expect_parts(text: []const u8, parts: []const []const u8) !void {
    assert(text.len > 0);
    assert(parts.len > 0);
    for (parts) |part| {
        if (std.mem.indexOf(u8, text, part) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ part, text });
            return error.TestExpectedPart;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "\n! ") == null);
}

/// Checks that the dump of `source` contains each of `parts`, and has no diagnostics.
fn expect_source_parts(source: []const u8, parts: []const []const u8) !void {
    assert(parts.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    assert(source.len > 0);
    try expect_parts(try dump_of(arena_state.allocator(), source), parts);
}

/// Checks that the dump of fixture `path` contains each of `parts`, and has no diagnostics.
fn expect_fixture_parts(comptime path: []const u8, parts: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try expect_parts(try dump_of_fixture(arena_state.allocator(), path), parts);
}

/// The dump of the expression in `~ temp e = <expression>`, on one line.
fn expect_expression(expression: []const u8, expected: []const u8) !void {
    assert(expected.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    assert(expression.len > 0);
    const source = try std.fmt.allocPrint(arena, "~ temp e = {s}\n", .{expression});
    const text = try dump_of(arena, source);
    const wanted = try std.fmt.allocPrint(arena, "(temp_declaration identifier\"e\" {s})", .{
        expected,
    });
    try expect_parts(text, &.{wanted});
}

// Fixtures.

test "hello_world.ink: one line of text" {
    try expect_fixture_parts("runtime/misc/hello_world.ink", &.{
        "(statements\n    text\"Hello world\"\n    newline))",
    });
}

test "end_of_content.ink: the knot's name" {
    try expect_fixture_parts("runtime/misc/end_of_content.ink", &.{
        "(knot identifier\"test\" none",
    });
}

test "knot_do_not_gather.ink: a divert, then the knot" {
    const path = "runtime/knots/knot_do_not_gather.ink";
    try expect_fixture_parts(path, &.{
        "(statements\n    (divert (path identifier\"knot\") none)",
        "(knot identifier\"knot\" none",
    });
}

test "variable_get_set_api.ink: VAR x = 5" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const path = "runtime/variables/variable_get_set_api.ink";
    const text = try dump_of_fixture(arena_state.allocator(), path);
    try expect_parts(text, &.{"(variable_declaration identifier\"x\" integer\"5\")"});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "variable_declaration"));
}

test "const.ink: CONST c = 5" {
    try expect_fixture_parts("runtime/variables/const.ink", &.{
        "(const_declaration identifier\"c\" integer\"5\")",
    });
}

test "include.ink: two INCLUDE paths" {
    try expect_fixture_parts("runtime/misc/include.ink", &.{
        "include\"includes/included_file.ink\"",
        "include\"includes/included_file_2.ink\"",
    });
}

test "knot_thread_interaction.ink: three knots" {
    const path = "runtime/knots/knot_thread_interaction.ink";
    try expect_fixture_parts(path, &.{
        "(knot identifier\"knot\"",
        "(knot identifier\"tunnel\"",
        "(knot identifier\"threadB\"",
    });
}

test "knot_stitch_gather_counts.ink: VARs anywhere are declarations" {
    const path = "runtime/knots/knot_stitch_gather_counts.ink";
    try expect_fixture_parts(path, &.{
        "(variable_declaration identifier\"knotCount\"",
        "(variable_declaration identifier\"stitchCount\"",
        "(variable_declaration identifier\"gatherCount\"",
    });
}

// Corner cases.

test "empty source: an empty story" {
    try expect_dump("", "(story\n  (statements))\n");
}

test "only newlines: an empty story" {
    try expect_dump("\n\n\n", "(story\n  (statements))\n");
}

test "only comments: an empty story" {
    try expect_dump("// a comment\n/* block\ncomment */\n", "(story\n  (statements))\n");
}

test "divert to END" {
    try expect_dump("-> END\n",
        \\(story
        \\  (statements
        \\    (divert (path identifier"END") none)))
        \\
    );
}

test "divert to DONE" {
    try expect_dump("-> DONE\n",
        \\(story
        \\  (statements
        \\    (divert (path identifier"DONE") none)))
        \\
    );
}

test "tunnel onwards ->->" {
    try expect_dump("->->\n",
        \\(story
        \\  (statements
        \\    (tunnel_onwards none)))
        \\
    );
}

test "tunnel call -> target ->" {
    try expect_dump("-> mytunnel ->\n",
        \\(story
        \\  (statements
        \\    (tunnel (path identifier"mytunnel") none)))
        \\
    );
}

test "dotted divert path knot.stitch" {
    try expect_dump("-> outer.inner\n",
        \\(story
        \\  (statements
        \\    (divert (path identifier"outer" identifier"inner") none)))
        \\
    );
}

test "a divert at the end of a text line" {
    // ink trims the text and ends it with one space (text_space).
    try expect_dump("go there -> target\n",
        \\(story
        \\  (statements
        \\    text_space"go there"
        \\    (divert (path identifier"target") none)
        \\    newline))
        \\
    );
}

test "a text line with a tag" {
    try expect_dump("Some text # mytag\n",
        \\(story
        \\  (statements
        \\    text"Some text "
        \\    tag_start"#"
        \\    text"mytag"
        \\    tag_end
        \\    newline))
        \\
    );
}

test "a brace expression at the line start" {
    try expect_dump("{2 + 3}\n",
        \\(story
        \\  (statements
        \\    (content_list
        \\      (inline_value (add integer"2" integer"3")))
        \\    newline))
        \\
    );
}

test "nested braces" {
    // The old parser skipped the block. In ink no inner logic covers `outer {inner} still`
    // (an expression stops at `{`, a sequence needs two elements), so InlineLogic fails
    // with an error, the line has no content, and the top-level statements end there:
    // ink's Parse doesn't go on after a statement it can't read. inklecate reports exactly
    // this one error for the input.
    try expect_dump("{outer {inner} still}\ntext\n",
        \\(story
        \\  (statements))
        \\! 1:2 expected inner_logic
        \\
    );
}

test "VAR bool true" {
    try expect_source_parts(("VAR flag = true\n"), &.{
        "(variable_declaration identifier\"flag\" true\"true\")",
    });
}

test "VAR bool false" {
    try expect_source_parts(("VAR flag = false\n"), &.{
        "(variable_declaration identifier\"flag\" false\"false\")",
    });
}

test "VAR float literal" {
    try expect_source_parts(("VAR pi = 3.14\n"), &.{
        "(variable_declaration identifier\"pi\" float\"3.14\")",
    });
}

test "VAR negative integer" {
    // ink parses the minus as a prefix operator and folds it into the number later.
    try expect_source_parts(("VAR debt = -42\n"), &.{
        "(variable_declaration identifier\"debt\" (negate integer\"42\"))",
    });
}

test "VAR string literal" {
    try expect_source_parts(("VAR name = \"Alice\"\n"), &.{
        "(variable_declaration identifier\"name\" (string\n        text\"Alice\"))",
    });
}

test "VAR identifier reference" {
    try expect_source_parts(("VAR x = MYCONST\n"), &.{
        "(variable_declaration identifier\"x\" (variable_reference (path identifier\"MYCONST\")))",
    });
}

test "multiple VAR declarations" {
    try expect_source_parts(("VAR a = 1\nVAR b = 2\nVAR c = 3\n"), &.{
        "(variable_declaration identifier\"a\" integer\"1\")",
        "(variable_declaration identifier\"b\" integer\"2\")",
        "(variable_declaration identifier\"c\" integer\"3\")",
    });
}

test "malformed VAR without equals: a diagnostic, and the next line still parses" {
    // ink: the `=` and the value are expected; without a value it isn't a declaration, so
    // the line is read as text.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try dump_of(arena_state.allocator(), "VAR x\nsome text\n");
    try std.testing.expect(std.mem.indexOf(u8, text, "variable_declaration") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "text\"some text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n! 1:") != null);
}

test "malformed VAR without a name: a diagnostic, and the next line still parses" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try dump_of(arena_state.allocator(), "VAR = 5\ntext\n");
    const declaration = "(variable_declaration missing integer\"5\")";
    try std.testing.expect(std.mem.indexOf(u8, text, declaration) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "text\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n! 1:") != null);
}

test "CONST of every literal type" {
    const source = "CONST a = 7\nCONST b = 2.5\nCONST c = true\nCONST d = \"hi\"\n";
    try expect_source_parts((source), &.{
        "(const_declaration identifier\"a\" integer\"7\")",
        "(const_declaration identifier\"b\" float\"2.5\")",
        "(const_declaration identifier\"c\" true\"true\")",
        "(const_declaration identifier\"d\" (string",
    });
}

test "a knot marked with three equals" {
    try expect_source_parts(("=== myknot ===\nText.\n"), &.{"(knot identifier\"myknot\" none"});
}

test "a knot marked with two equals" {
    try expect_source_parts(("== myknot ==\nText.\n"), &.{"(knot identifier\"myknot\" none"});
}

test "a knot with text and a divert" {
    try expect_dump("=== myknot ===\nSome content\n-> END\n",
        \\(story
        \\  (statements
        \\    (knot identifier"myknot" none (statements
        \\        text"Some content"
        \\        newline
        \\        (divert (path identifier"END") none)))))
        \\
    );
}

test "an empty knot" {
    // ink requires a line in a knot: an error, ink's recovery content, then the next knot.
    try expect_dump("=== empty ===\n=== next ===\nText.\n",
        \\(story
        \\  (statements
        \\    (knot identifier"empty" none (statements
        \\        error_text""))
        \\    (knot identifier"next" none (statements
        \\        text"Text."
        \\        newline))))
        \\! 2:1 expected knot_content
        \\
    );
}

test "a knot with one stitch" {
    try expect_dump("=== myknot ===\n= mystitch\nStitch text\n",
        \\(story
        \\  (statements
        \\    (knot identifier"myknot" none (statements
        \\        (stitch identifier"mystitch" none (statements
        \\            text"Stitch text"
        \\            newline))))))
        \\
    );
}

test "a knot with three stitches" {
    try expect_source_parts(("=== k ===\n= s1\nA\n= s2\nB\n= s3\nC\n"), &.{
        "(stitch identifier\"s1\"",
        "(stitch identifier\"s2\"",
        "(stitch identifier\"s3\"",
    });
}

test "VAR inside a stitch" {
    // Where the declaration lives is sema's business (P8.1); the tree keeps it in place.
    try expect_source_parts(("=== k ===\n= s\nVAR counter = 0\n"), &.{
        "(stitch identifier\"s\" none (statements\n" ++
            "            (variable_declaration identifier\"counter\" integer\"0\")",
    });
}

test "three knots with text" {
    const source = "=== a ===\ntext a\n=== b ===\ntext b\n=== c ===\ntext c\n";
    try expect_source_parts((source), &.{
        "(knot identifier\"a\" none (statements\n        text\"text a\"",
        "(knot identifier\"b\" none (statements\n        text\"text b\"",
        "(knot identifier\"c\" none (statements\n        text\"text c\"",
    });
}

test "root content before the first knot" {
    try expect_dump("-> start\n=== start ===\nKnot text\n",
        \\(story
        \\  (statements
        \\    (divert (path identifier"start") none)
        \\    (knot identifier"start" none (statements
        \\        text"Knot text"
        \\        newline))))
        \\
    );
}

test "glue between text" {
    // The old parser kept `<>` inside the text; ink makes it a glue object.
    try expect_dump("hello <> world\n",
        \\(story
        \\  (statements
        \\    text"hello "
        \\    glue"<>"
        \\    text" world"
        \\    newline))
        \\
    );
}

test "a whitespace-only line is skipped" {
    try expect_dump("   \nreal text\n",
        \\(story
        \\  (statements
        \\    text"real text"
        \\    newline))
        \\
    );
}

// Expressions.

test "expression: integer" {
    try expect_expression("42", "integer\"42\"");
}

test "expression: float" {
    try expect_expression("3.14", "float\"3.14\"");
}

test "expression: true" {
    try expect_expression("true", "true\"true\"");
}

test "expression: addition" {
    try expect_expression("2 + 3", "(add integer\"2\" integer\"3\")");
}

test "expression: multiplication binds tighter than addition" {
    try expect_expression("2 * 3 + 5", "(add (multiply integer\"2\" integer\"3\") integer\"5\")");
}

test "expression: not" {
    try expect_expression("not true", "(not true\"true\")");
}

test "expression: parentheses" {
    const expected = "(multiply integer\"2\" (subtract integer\"5\" integer\"1\"))";
    try expect_expression("2 * (5 - 1)", expected);
}

test "expression: mod" {
    try expect_expression("8 mod 3", "(modulo integer\"8\" integer\"3\")");
}

test "expression: comparison" {
    try expect_expression("3 > 1", "(greater integer\"3\" integer\"1\")");
}

test "expression: in braces with spaces" {
    const expected = "(story\n  (statements\n    (content_list\n      (inline_value " ++
        "(add (multiply integer\"2\" integer\"3\") (multiply integer\"5\" integer\"6\"))))\n" ++
        "    newline))\n";
    try expect_dump("{ 2 * 3 + 5 * 6 }\n", expected);
}

test "dense logic stays within the step bound" {
    // Goal: the core's gas bound (steps per byte) holds for ink's backtracking on dense input,
    // the worst case being short inline logic (each brace tries several rules). Method: lines
    // of `{a}{f(b)}{c:d|e}` and choices with conditions, with no no_progress diagnostic.
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    for (0..500) |_| try source.appendSlice(gpa, "{a}{f(b)}{c:d|e}{-x}\n* {a} {b} [x{y}] z -> k\n");
    var parsed = try @import("grammar.zig").parse(gpa, source.items, .{});
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), parsed.diagnostics_count);
}
