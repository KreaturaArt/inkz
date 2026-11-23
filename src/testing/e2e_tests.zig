//! The compiler's end-to-end tests: each story is compiled from source and played through a
//! fixed list of choices, choosing whenever the story can't continue
//! (`support.play_program`). They began as the old compiler's e2e tests; where the old
//! pipeline differed from ink, the expectation is what ink prints. Stories checked by their
//! output alone are rows of `source_rows` and `fixture_rows`; tests that need more steps
//! follow them. The tests that drive the story API directly live in e2e_api.zig.

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
    return (try support.play_program(gpa, &program, choices)).output;
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
    const played = try support.play_program(gpa, &program, choices);
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
    // Deleting a row is a visible change: the tables' sizes are pinned.
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

/// The fixtures whose run here ground truth doesn't cover: test/ground_truth has no case
/// for them (includes/ and player/), or its case plays another path or other host actions.
/// Every other fixture's case plays it (structure_gate: the compiled program is the one
/// ground truth plays) and checks the whole transcript.
const fixture_rows = [_]FixtureRow{
    // Includes
    .{
        .path = "runtime/misc/includes/included_file.ink",
        .expect = .{ .exact = "This is include 1.\n" },
    },
    .{
        .path = "runtime/misc/includes/included_file_2.ink",
        .expect = .{ .exact = "This is include 2.\n" },
    },
    .{ .path = "runtime/misc/includes/included_file_4.ink", .expect = .{ .has = &.{"5"} } },

    // ink offers "one", "two", "three", "four"; the second is "two".
    .{
        .path = "runtime/choices/conditional_choices.ink",
        .choices = &.{1},
        .expect = .{ .exact = "two\n" },
    },

    // Evaluation
    .{
        .path = "runtime/evaluation/evaluating_function_variable_state_bug.ink",
        .expect = .{ .exact = "Start\nIn tunnel.\nEnd\n" },
    },

    // Variables
    .{
        .path = "runtime/variables/set_non_existant_variable.ink",
        .expect = .{ .exact = "Hello world.\n" },
    },

    // Diverts
    .{ .path = "runtime/diverts/tunnel_vs_thread_behaviour.ink", .choices = &.{ 0, 2 }, .expect = .{
        .has = &.{"Done."},
    } },

    // Built-ins
    .{
        .path = "runtime/evaluation/evaluating_ink_functions_from_game.ink",
        .choices = &.{0},
        .expect = .{ .has = &.{"Top level content"} },
    },
    .{
        .path = "runtime/callstack/clean_callstack_reset_on_path_choice.ink",
        .expect = .{ .exact = "The first line.\nThe second line.\n" },
    },

    // Player
    .{ .path = "player/ink_error.ink", .expect = .{ .exact = "" } },
    .{ .path = "player/ink_list_roundtrip.ink", .expect = .{ .exact = "Hello World.\n" } },
};

const source_rows_count = 32;
const fixture_rows_count = 11;

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

// ── Integration stories ──────────────────────────────────────────────────────
// structure_gate checks that each one's JSON loads back as the compiled program.

/// Plays `choices` on `program` and checks the output.
fn expect_played(program: *const Program, choices: []const u32, expect: Expect) !void {
    const played = try support.play_program(std.testing.allocator, program, choices);
    defer std.testing.allocator.free(played.output);
    try expect_output(played.output, expect);
}

fn compile_story(path: []const u8) !Program {
    return support.compile_fixture(std.testing.allocator, std.testing.io, path);
}

test "simple_taster_tutorial.ink - all choice paths" {
    // Choice tree (all 8 paths), every one converging at "we passed the day in silence":
    //   [1]           silent ("said nothing")
    //   [0,1]         the "Ah." branch
    //   [0,0,0,0..2]  "A wager!", "But surely", then post-gather choice 0, 1 or 2
    //   [0,0,1,0..2]  "A wager!", "Most serious", then post-gather choice 0, 1 or 2
    var program = try compile_story("test/fixture/simple_taster_tutorial.ink");
    defer program.deinit(std.testing.allocator);
    const foolish = "surely that is foolishness";
    const serious = "most serious matter";
    try expect_taster(&program, &.{1}, &.{"said nothing"});
    try expect_taster(&program, &.{ 0, 1 }, &.{"uncertain what I thought"});
    try expect_taster(&program, &.{ 0, 0, 0, 0 }, &.{ foolish, "endeavour to find out" });
    try expect_taster(&program, &.{ 0, 0, 0, 1 }, &.{ foolish, "Twenty thousand pounds" });
    try expect_taster(&program, &.{ 0, 0, 0, 2 }, &.{ foolish, "polite cough" });
    try expect_taster(&program, &.{ 0, 0, 1, 0 }, &.{ serious, "endeavour to find out" });
    try expect_taster(&program, &.{ 0, 0, 1, 1 }, &.{ serious, "Twenty thousand pounds" });
    try expect_taster(&program, &.{ 0, 0, 1, 2 }, &.{ serious, "polite cough" });
}

/// A path through simple_taster_tutorial: its own phrases, then the common ending.
fn expect_taster(program: *const Program, choices: []const u32, phrases: []const []const u8) !void {
    const played = try support.play_program(std.testing.allocator, program, choices);
    defer std.testing.allocator.free(played.output);
    try expect_output(played.output, .{ .has = phrases });
    try expect_output(played.output, .{ .has = &.{"we passed the day in silence"} });
}

const crime_scene = "test/fixture/crime_scene.ink";

test "crime_scene.ink - initial scene loads" {
    var program = try compile_story(crime_scene);
    defer program.deinit(std.testing.allocator);
    try expect_played(&program, &.{}, .{ .has = &.{"bedroom"} });
}

test "crime_scene.ink - examine desk and get cane" {
    var program = try compile_story(crime_scene);
    defer program.deinit(std.testing.allocator);
    try expect_played(&program, &.{ 1, 0 }, .{ .has = &.{ "desk", "cane" } });
}

test "crime_scene.ink - examine bed fully" {
    var program = try compile_story(crime_scene);
    defer program.deinit(std.testing.allocator);
    try expect_played(&program, &.{ 0, 0, 0, 0 }, .{ .has = &.{ "neatly made", "crumpled" } });
}

test "crime_scene.ink - examine window" {
    // The top, the window, look down, look at the glass.
    var program = try compile_story(crime_scene);
    defer program.deinit(std.testing.allocator);
    try expect_played(&program, &.{ 2, 0 }, .{ .has = &.{ "window", "brook" } });
}

const depth_max = 3;

/// A choice sequence of at most `depth_max` choices.
const Path = struct {
    choices: [depth_max]u32 = undefined,
    len: u32 = 0,
};

test "crime_scene.ink - all states reachable within 3 choices" {
    // Explores every choice sequence up to three choices deep, with an explicit stack; every
    // node must play.
    var program = try compile_story(crime_scene);
    defer program.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(Path) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{});
    var visited: u32 = 0;
    while (stack.pop()) |path| {
        visited += 1;
        const played = try support.play_program(gpa, &program, path.choices[0..path.len]);
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
