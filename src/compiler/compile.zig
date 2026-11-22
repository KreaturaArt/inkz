//! The new compiler's entry points: source to Program, as ink's
//! Compiler.Compile does it: parse (with INCLUDEs), and with no parse error, build the object
//! tree, resolve names, and with no error, lower, flatten, lay out and emit.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const Allocator = std.mem.Allocator;
const grammar = @import("grammar.zig");
const ast = @import("ast.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const source_space = @import("source_space.zig");
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const emit = @import("lower_emit.zig");
const ink_json = @import("../core/ink_json.zig");
pub const messages = @import("messages.zig");
const limits = @import("../core/limits.zig");
const Program = @import("../core/program.zig").Program;

pub const Error = error{
    /// The story has errors (see the diagnostics), or the parser gave up on it: the source
    /// is longer than `source_bytes_max`, nests deeper than `parse_depth_max`, or needs more
    /// workspace than `compile_retries_max` doublings give.
    CompileFailed,
};

/// Whether a parse diagnostic is one of ink's warnings (it doesn't stop compilation).
pub const is_warning = grammar.Grammar.is_warning;

pub const Options = struct {
    /// ink's countAllVisits: count the visits of every knot, stitch, gather and choice.
    count_all_visits: bool = false,
    /// Filled in with what the compile did, for tests and the bench.
    statistics: ?*Statistics = null,
    /// Receives every error, warning and author note, as inklecate words them, when the
    /// compile ends (failed or not): author notes first, then warnings, then errors.
    diagnostics: ?messages.Sink = null,
};

/// Where the stages render their diagnostics, when the caller asked for them.
const Report = struct {
    collector: *messages.Collector,
    locator: *const messages.Locator,
};

pub const Statistics = struct {
    /// Whole parses after the first: the workspace estimate was too small (T15). The corpus
    /// keeps this at 0 (finding F14).
    workspace_retries: u32 = 0,
};

/// The stages after parsing, on a parsed story (one file, or a space's). The object tree,
/// the resolution and the syntax are freed once lowered, before layout and emission.
fn compile_parsed(
    gpa: Allocator,
    parsed: *grammar.Parsed,
    space: ?*const source_space.Space,
    options: Options,
    report: ?Report,
) !Program {
    assert(parsed.tree.tags.len > 0);
    assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
    if (report) |into| try messages.collect_parse(into.collector, into.locator);
    // An error past the full diagnostics wasn't recorded, but still fails the story.
    if (parsed.errors_dropped) return error.CompileFailed;
    for (parsed.diagnostics()) |diagnostic| {
        if (!is_warning(diagnostic)) return error.CompileFailed;
    }
    var lowered = try lower_parsed(gpa, parsed, space, options, report);
    defer lowered.deinit();
    parsed.release_syntax(gpa);
    var layout = layout: {
        const profile_zone = profile.begin(.compile_layout);
        defer profile_zone.end();
        break :layout try layout_module.lay_out(&lowered);
    };
    defer layout.deinit();
    const profile_zone = profile.begin(.compile_emit);
    defer profile_zone.end();
    return emit.emit_program(&lowered, &layout);
}

/// Object tree, resolution and lowering, up to flattening.
fn lower_parsed(
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    space: ?*const source_space.Space,
    options: Options,
    report: ?Report,
) !lower.Lowered {
    assert(parsed.tree.tags.len > 0);
    assert(space == null or space.?.files.len > 0);
    const sema_zone = profile.begin(.compile_sema);
    var tree = if (space) |files| try sema.build_space_tree(gpa, files) else try sema.build_tree(
        gpa,
        parsed,
    );
    sema_zone.end();
    defer tree.deinit(gpa);
    const resolve_zone = profile.begin(.compile_resolve);
    var resolution = try resolve.resolve(gpa, parsed, &tree);
    resolve_zone.end();
    defer resolution.deinit(gpa);
    const story: ?messages.Story = if (report) |into| .{
        .parsed = parsed,
        .tree = &tree,
        .locator = into.locator,
    } else null;
    const resolved = !resolution.failed();
    // ink generates code (and checks termination) before it resolves references, so a
    // story with reference errors still gets lowering's diagnostics: lowered for them
    // alone, then dropped.
    if (!resolved and report == null) return error.CompileFailed;
    const lower_zone = profile.begin(.compile_lower);
    var lowering = try lower.Lowering.init(gpa, parsed, &tree, &resolution);
    errdefer lowering.deinit();
    lowering.count_all_visits = options.count_all_visits;
    try lowering.generate_all();
    try lowering.finish_story();
    lower_zone.end();
    if (report) |into| try messages.collect_resolve(
        into.collector,
        &story.?,
        resolution.diagnostics,
        lowering.diagnostics.items,
    );
    if (!resolved or lowering.failed()) return error.CompileFailed;
    const flatten_zone = profile.begin(.compile_flatten);
    defer flatten_zone.end();
    layout_module.set_count_flags(&lowering);
    try layout_module.flatten(&lowering);
    return lowering.into_lowered();
}

/// Compiles one ink file's text. It reads no files: a story with an INCLUDE is CompileFailed
/// (use `compile_file`).
pub fn compile_source(gpa: Allocator, source: []const u8) !Program {
    return compile_source_with(gpa, source, .{});
}

/// `compile_source` with options.
pub fn compile_source_with(gpa: Allocator, source: []const u8, options: Options) !Program {
    assert(@TypeOf(gpa) == Allocator);
    var parsed = parsed: {
        const profile_zone = profile.begin(.compile_parse);
        defer profile_zone.end();
        const text = source_space.without_bom(source);
        break :parsed grammar.parse(gpa, text, .{}) catch |err| switch (err) {
            // The parser gave up on the story.
            error.SourceTooLarge, error.ParseFailed, error.WorkspaceFull => {
                if (options.diagnostics) |sink| messages.deliver_give_up(sink, err, "");
                return error.CompileFailed;
            },
            else => |other| return other,
        };
    };
    defer parsed.deinit(gpa);
    if (options.statistics) |statistics| statistics.workspace_retries = parsed.attempts - 1;
    var collector = messages.Collector.init(gpa);
    defer collector.deinit();
    defer if (options.diagnostics) |sink| collector.deliver(sink);
    const locator: messages.Locator = .{ .gpa = gpa, .parsed = &parsed, .space = null };
    const report: ?Report = if (options.diagnostics != null) .{
        .collector = &collector,
        .locator = &locator,
    } else null;
    // There is no directory to INCLUDE from: inklecate's "Failed to load: 'name'" error.
    if (std.mem.indexOfScalar(ast.Tag, parsed.tree.tags, .include) != null) {
        if (report) |into| try messages.collect_includes(into.collector, into.locator);
        return error.CompileFailed;
    }
    return compile_parsed(gpa, &parsed, null, options, report);
}

/// Compiles `path` (in `directory`) and the files it includes.
pub fn compile_file(gpa: Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !Program {
    assert(path.len > 0);
    return compile_file_with(gpa, io, directory, path, .{});
}

pub fn compile_file_with(
    gpa: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    options: Options,
) !Program {
    assert(std.fs.path.basename(path).len > 0);
    assert(path.len > 0);
    var space = source_space.load(gpa, io, directory, path, .{}) catch |err| switch (err) {
        // The parser gave up on a file or on the space.
        error.SourceTooLarge, error.ParseFailed, error.WorkspaceFull => {
            if (options.diagnostics) |sink| messages.deliver_give_up(sink, err, path);
            return error.CompileFailed;
        },
        else => |other| return other,
    };
    defer space.deinit(gpa);
    if (options.statistics) |statistics| statistics.workspace_retries = space.parsed.attempts - 1;
    var collector = messages.Collector.init(gpa);
    defer collector.deinit();
    defer if (options.diagnostics) |sink| collector.deliver(sink);
    const locator: messages.Locator = .{ .gpa = gpa, .parsed = &space.parsed, .space = &space };
    const report: ?Report = if (options.diagnostics != null) .{
        .collector = &collector,
        .locator = &locator,
    } else null;
    if (space.problems.len > 0) {
        if (report) |into| try messages.collect_problems(into.collector, into.locator, &space);
        return error.CompileFailed;
    }
    return compile_parsed(gpa, &space.parsed, &space, options, report);
}

/// A story compiled and serialized as ink's JSON (for comparing with inklecate's). A story
/// whose paths are longer than the JSON writer's 64 components (about 60 nested weave
/// levels) is CompileFailed.
pub fn compile_to_json(gpa: Allocator, source: []const u8) ![]u8 {
    assert(@TypeOf(gpa) == Allocator);
    var program = try compile_source(gpa, source);
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    ink_json.serialize(gpa, &program, &out.writer) catch |err| switch (err) {
        error.PathTooDeep => return error.CompileFailed,
        else => |other| return other,
    };
    return out.toOwnedSlice();
}

test "hello world compiles to inklecate's JSON" {
    const gpa = std.testing.allocator;
    const text = try compile_to_json(gpa, "Hello, world.\n");
    defer gpa.free(text);
    const expected = "{\"inkVersion\":21,\"root\":[[\"^Hello, world.\",\"\\n\"," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}";
    try std.testing.expectEqualStrings(expected, text);
}

test "a 0 byte inside the source is text, not the end" {
    // A NUL byte once ended the text early and crashed the compiler (found by fuzzing).
    const gpa = std.testing.allocator;
    const text = try compile_to_json(gpa, "a\x00b\n");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"^a\\u0000b\"") != null);
}

test "a UTF-8 byte order mark is not text, in a source, a file or an included file" {
    // inklecate reads files with .NET's File.ReadAllText, which drops the mark; it was once
    // compiled as the first character of the first text.
    const gpa = std.testing.allocator;
    const bom = "\xEF\xBB\xBF";
    const expected = "{\"inkVersion\":21,\"root\":[[\"^Hello\",\"\\n\"," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}";
    const text = try compile_to_json(gpa, bom ++ "Hello\n");
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const main_text = bom ++ "INCLUDE other.ink\nMain.\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "main.ink", .data = main_text });
    try temporary.dir.writeFile(io, .{ .sub_path = "other.ink", .data = bom ++ "Other.\n" });
    var program = try compile_file(gpa, io, temporary.dir, "main.ink");
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"^Other.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"^Main.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), bom) == null);
}

test "a literal ink can't fold, such as - true, fails to compile instead of leaking an error" {
    // inklecate throws "Unexpected operation or number type" on each; `{ - true: ... }` once
    // returned error.UnsupportedFold from compile_source.
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "{ - true: -> s }\n== s\nhi\n-> DONE\n",
        "VAR x = - true\n{x}\n",
        "CONST c = - false\n{c}\n",
        "~ temp t = -(-true)\n{t}\n",
        "{RANDOM(-true, 2)}\n",
    };
    for (sources) |source| {
        try std.testing.expectError(error.CompileFailed, compile_source(gpa, source));
        try std.testing.expectError(error.CompileFailed, compile_to_json(gpa, source));
    }
    // What ink folds compiles.
    var program = try compile_source(gpa, "{ - 1: x } {not true} {-1.5} {!0}\n");
    program.deinit(gpa);
}

test "compile_source fails on an INCLUDE it can't load instead of dropping it" {
    // ERROR: line 1: Failed to load: 'missing.ink' (inklecate). compile_source reads no
    // files, so every INCLUDE fails; it was once dropped silently, compiling "Hello" alone.
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "INCLUDE missing.ink\nHello\n",
        "Hello\nINCLUDE other.ink\n== k\n-> DONE\n",
    };
    for (sources) |source| {
        try std.testing.expectError(error.CompileFailed, compile_source(gpa, source));
    }
    // An INCLUDE in a comment is no INCLUDE.
    var program = try compile_source(gpa, "// INCLUDE missing.ink\nHello\n");
    program.deinit(gpa);
}

/// inklecate's JSON for `~ temp x = 1`, `~ x++`, `{x}` at story level: ink resolves a
/// story-level temp as a global, so the re-assignment is `VAR=`.
const story_temp_json = "{\"inkVersion\":21,\"root\":[[\"ev\",1,\"/ev\",{\"temp=\":\"x\"}," ++
    "\"ev\",{\"VAR?\":\"x\"},1,\"+\",{\"VAR=\":\"x\",\"re\":true},\"/ev\",\"ev\"," ++
    "{\"VAR?\":\"x\"},\"out\",\"/ev\",\"\\n\",[\"done\",{\"#n\":\"g-0\"}],null],\"done\"," ++
    "{\"global decl\":[\"ev\",\"/ev\",\"end\",null]}],\"listDefs\":{}}";

test "a story-level temp's re-assignment is VAR=, as inklecate writes it, and still a temp" {
    // The compiler resolved it as global, but the Program kept only a temp assignment, so
    // it was once written {"temp=":"x","re":true}. It runs as a temp, as ink's
    // VariablesState.Assign treats a re-assignment of a name that is no global.
    const gpa = std.testing.allocator;
    const source = "~ temp x = 1\n~ x++\n{x}\n";
    const text = try compile_to_json(gpa, source);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(story_temp_json, text);
    var program = try compile_source(gpa, source);
    defer program.deinit(gpa);
    const support = @import("../testing/support.zig");
    const played = try support.play_program(gpa, &program, &.{});
    defer gpa.free(played.output);
    try std.testing.expectEqualStrings("2\n", played.output);
}

test "VAR= and temp= re-assignments round-trip from ink JSON through a Program" {
    // inklecate's JSON, loaded and written back, keeps each form: VAR= of a story temp,
    // VAR= of a global and temp= of a knot's temp.
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        story_temp_json,
        "{\"inkVersion\":21,\"root\":[[\"ev\",{\"VAR?\":\"g\"},1,\"+\",{\"VAR=\":\"g\"," ++
            "\"re\":true},\"/ev\",{\"->\":\"k\"},[\"done\",{\"#n\":\"g-0\"}],null],\"done\"," ++
            "{\"k\":[\"ev\",1,\"/ev\",{\"temp=\":\"t\"},\"ev\",2,\"/ev\",{\"temp=\":\"t\"," ++
            "\"re\":true},\"done\",null],\"global decl\":[\"ev\",1,{\"VAR=\":\"g\"},\"/ev\"," ++
            "\"end\",null]}],\"listDefs\":{}}",
    };
    for (sources) |json| {
        var program = try ink_json.load(gpa, json);
        defer program.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try ink_json.serialize(gpa, &program, &out.writer);
        try std.testing.expectEqualStrings(json, out.written());
    }
}

/// The old compiler's peak bytes compiling test/fixture/crime_scene.ink to JSON in a Debug
/// build, the baseline of the memory criterion.
const old_compiler_peak_bytes_crime_scene = 535_946;

test "the compiler peaks at no more than half the old compiler's memory" {
    // crime_scene compiled with a counting
    // allocator; the peak, with the object tree, resolution and syntax freed before
    // emission, is at most half the old compiler's.
    const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
    const io = std.testing.io;
    const path = "test/fixture/crime_scene.ink";
    const limit: std.Io.Limit = .limited(1 << 20);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, limit);
    defer std.testing.allocator.free(source);
    var counting: CountingAllocator = .init(std.testing.allocator);
    const gpa = counting.allocator();
    var program = try compile_source(gpa, source);
    defer program.deinit(gpa);
    try std.testing.expect(program.instructions_count() > 1000);
    try std.testing.expect(counting.bytes_peak * 2 <= old_compiler_peak_bytes_crime_scene);
}

test "the parse workspace is sized from the source and retries at most compile_retries_max times" {
    // Dense arithmetic (more nodes and tokens per byte
    // than the first workspace has room for) needs two doublings: with one retry allowed the
    // parse fails with WorkspaceFull, with two it succeeds, settled to the nodes it used.
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "~ temp x = 1");
    for (0..2000) |_| try text.appendSlice(gpa, "+1");
    try text.appendSlice(gpa, "\n{x}\n");
    try std.testing.expectError(
        error.WorkspaceFull,
        grammar.parse(gpa, text.items, .{ .compile_retries_max = 1 }),
    );
    var parsed = try grammar.parse(gpa, text.items, .{ .compile_retries_max = 2 });
    defer parsed.deinit(gpa);
    try std.testing.expect(parsed.workspace.node_tags.len == parsed.tree.tags.len);
}

test "input the parser gives up on fails to compile, freeing everything once" {
    // 200 nested parentheses, 500 unary minuses and 300 nested braces nest deeper than
    // parse_depth_max: the parse is abandoned, and its workspace was once freed twice.
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.append(gpa, '{');
    try text.appendNTimes(gpa, '(', 200);
    try text.append(gpa, '1');
    try text.appendNTimes(gpa, ')', 200);
    try text.appendSlice(gpa, "}\n");
    try std.testing.expectError(error.CompileFailed, compile_source(gpa, text.items));
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "VAR x=1\n{");
    try text.appendNTimes(gpa, '-', 500);
    try text.appendSlice(gpa, "x}\n");
    try std.testing.expectError(error.CompileFailed, compile_source(gpa, text.items));
    text.clearRetainingCapacity();
    try text.appendNTimes(gpa, '{', 300);
    try text.append(gpa, 'x');
    try text.appendNTimes(gpa, '}', 300);
    try text.append(gpa, '\n');
    try std.testing.expectError(error.CompileFailed, compile_source(gpa, text.items));
}

test "an error after more warnings than diagnostics_max still fails the compilation" {
    // 300 empty choices are 300 warnings, more than the 256 diagnostics kept; the
    // unfinished conditional after them is an error, and was once dropped silently.
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "== k\n");
    for (0..300) |_| try text.appendSlice(gpa, "*\n");
    try text.appendSlice(gpa, "- -> DONE\n");
    var warned = try compile_source(gpa, text.items);
    warned.deinit(gpa);
    try text.appendSlice(gpa, "== j\n{x:\n");
    var parsed = try grammar.parse(gpa, text.items, .{});
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(parsed.workspace.diagnostics.len, parsed.diagnostics_count);
    try std.testing.expect(parsed.errors_dropped);
    try std.testing.expectError(error.CompileFailed, compile_source(gpa, text.items));
}

test "a source longer than source_bytes_max is an error, not an assertion" {
    // A synthetic buffer one byte over the default bound fails before any parsing; a
    // smaller bound is checked the same way by the parser.
    const gpa = std.testing.allocator;
    const bounds: limits.CompilerLimits = .{};
    const text = try gpa.alloc(u8, bounds.source_bytes_max + 1);
    defer gpa.free(text);
    @memset(text, 'a');
    try std.testing.expectError(error.CompileFailed, compile_source(gpa, text));
    try std.testing.expectError(
        error.SourceTooLarge,
        grammar.parse(gpa, "Hello.\n", .{ .source_bytes_max = 4 }),
    );
}

test "compile_to_json: weaves nested deeper than the JSON paths allow are CompileFailed" {
    // 70 levels of nested choices compile, but their paths have more components than the
    // JSON writer keeps; 10 levels serialize.
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (1..71) |depth| {
        try text.appendNTimes(gpa, '*', depth);
        try text.appendSlice(gpa, " c\n");
        if (depth == 10) {
            const json = try compile_to_json(gpa, text.items);
            gpa.free(json);
        }
    }
    var program = try compile_source(gpa, text.items);
    program.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, compile_to_json(gpa, text.items));
}

test "a source denser than the workspace estimate retries, and says so" {
    // A story of short knots with nothing but diverts is far denser in nodes per byte than
    // the estimate: the parse retries with a doubled workspace, the compile succeeds, and
    // the statistics count the retries (P16.17, F14).
    const gpa = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    for (0..400) |index| {
        try source.writer.print("==k{d}\n->k{d}\n", .{ index, (index + 1) % 400 });
    }
    var statistics: Statistics = .{};
    var program = try compile_source_with(gpa, source.written(), .{ .statistics = &statistics });
    defer program.deinit(gpa);
    try std.testing.expect(statistics.workspace_retries > 0);
    var plain: Statistics = .{};
    var hello = try compile_source_with(gpa, "Hello, world.\n", .{ .statistics = &plain });
    defer hello.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), plain.workspace_retries);
}

/// Writes each diagnostic as inklecate prints it: `ERROR: 'file' line N: message`.
const Printer = struct {
    out: *std.Io.Writer.Allocating,

    fn print(context: ?*anyopaque, diagnostic: messages.Diagnostic) void {
        assert(diagnostic.line > 0);
        const printer: *Printer = @ptrCast(@alignCast(context.?));
        const kind = switch (diagnostic.severity) {
            .@"error" => "ERROR",
            .warning => "WARNING",
            .author => "TODO",
        };
        printer.out.writer.print("{s}: '{s}' line {d}: {s}\n", .{
            kind,
            diagnostic.file,
            diagnostic.line,
            diagnostic.message,
        }) catch {};
    }
};

test "diagnostics reach the caller as inklecate prints them" {
    // test/ground_truth/diagnostics: each story's messages, lines and severities equal
    // inklecate's (`mise run reference:diagnostics`), in its order (P16.12, F5).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = "test/ground_truth/diagnostics";
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var checked: u32 = 0;
    var mismatches: u32 = 0;
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".ink")) continue;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var printer: Printer = .{ .out = &out };
        const sink: messages.Sink = .{ .context = &printer, .function = Printer.print };
        if (compile_file_with(gpa, io, directory, entry.name, .{ .diagnostics = sink })) |program| {
            var compiled = program;
            compiled.deinit(gpa);
        } else |_| {}
        const stem = entry.name[0 .. entry.name.len - ".ink".len];
        const expected_name = try std.fmt.allocPrint(gpa, "{s}.expected", .{stem});
        defer gpa.free(expected_name);
        const file = try directory.readFileAlloc(io, expected_name, gpa, .limited(1 << 20));
        defer gpa.free(file);
        // The first line is the provenance header the mise task writes.
        const header_end = std.mem.indexOfScalar(u8, file, '\n') orelse return error.MissingHeader;
        const expected = file[header_end + 1 ..];
        checked += 1;
        if (!std.mem.eql(u8, expected, out.written())) {
            mismatches += 1;
            const shown = "{s}:\nexpected:\n{s}got:\n{s}\n";
            std.debug.print(shown, .{ entry.name, expected, out.written() });
        }
    }
    try std.testing.expect(checked >= 8);
    try std.testing.expectEqual(@as(u32, 0), mismatches);
}

const Recorded = struct {
    severities: [1024]messages.Severity = undefined,
    codes: [1024][]const u8 = undefined,
    count: u32 = 0,

    fn record(context: ?*anyopaque, diagnostic: messages.Diagnostic) void {
        assert(diagnostic.line > 0);
        const recorded: *Recorded = @ptrCast(@alignCast(context.?));
        if (recorded.count == recorded.severities.len) return;
        recorded.severities[recorded.count] = diagnostic.severity;
        // Code names are static strings, valid after the call.
        recorded.codes[recorded.count] = diagnostic.code;
        recorded.count += 1;
    }
};

test "a story with only warnings compiles and still delivers them" {
    const gpa = std.testing.allocator;
    var recorded: Recorded = .{};
    const sink: messages.Sink = .{ .context = &recorded, .function = Recorded.record };
    var program = try compile_source_with(gpa, "TODO: tidy this\n=== k ===\n* choice\n  text\n", .{
        .diagnostics = sink,
    });
    defer program.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), recorded.count);
    try std.testing.expectEqual(messages.Severity.author, recorded.severities[0]);
    try std.testing.expectEqual(messages.Severity.warning, recorded.severities[1]);
    try std.testing.expectEqualStrings("loose_end", recorded.codes[1]);
}

test "errors past the diagnostics cap are reported once, last" {
    // More broken lines than the parser keeps diagnostics for: the kept ones arrive, then
    // one `diagnostics_dropped`.
    const gpa = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    for (0..400) |_| try source.writer.writeAll("~ temp = 1\n");
    var recorded: Recorded = .{};
    const sink: messages.Sink = .{ .context = &recorded, .function = Recorded.record };
    try std.testing.expectError(error.CompileFailed, compile_source_with(gpa, source.written(), .{
        .diagnostics = sink,
    }));
    try std.testing.expect(recorded.count > 1);
    var dropped: u32 = 0;
    for (recorded.codes[0..recorded.count]) |code| {
        if (std.mem.eql(u8, code, "diagnostics_dropped")) dropped += 1;
    }
    try std.testing.expect(recorded.count < recorded.codes.len);
    try std.testing.expectEqual(@as(u32, 1), dropped);
    try std.testing.expectEqualStrings("diagnostics_dropped", recorded.codes[recorded.count - 1]);
}

test "a story the parser gives up on still delivers why" {
    // Braces nested deeper than parse_depth_max, and a source over source_bytes_max: no
    // tree, so one error at the start of the story instead of none (PR #2 review).
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '{', 300);
    try text.append(gpa, 'x');
    try text.appendNTimes(gpa, '}', 300);
    try text.append(gpa, '\n');
    var recorded: Recorded = .{};
    const sink: messages.Sink = .{ .context = &recorded, .function = Recorded.record };
    const options: Options = .{ .diagnostics = sink };
    try std.testing.expectError(error.CompileFailed, compile_source_with(gpa, text.items, options));
    try std.testing.expectEqual(@as(u32, 1), recorded.count);
    try std.testing.expectEqual(messages.Severity.@"error", recorded.severities[0]);
    try std.testing.expectEqualStrings("too_deep", recorded.codes[0]);
    const large = try gpa.alloc(u8, (limits.CompilerLimits{}).source_bytes_max + 1);
    defer gpa.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.CompileFailed, compile_source_with(gpa, large, options));
    try std.testing.expectEqual(@as(u32, 2), recorded.count);
    try std.testing.expectEqualStrings("source_too_large", recorded.codes[1]);
}

test "a back reference without a file name is 'line N', as ink's DebugMetadata prints it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var printer: Printer = .{ .out = &out };
    const sink: messages.Sink = .{ .context = &printer, .function = Printer.print };
    try std.testing.expectError(error.CompileFailed, compile_source_with(
        gpa,
        "VAR x = 1\nVAR x = 2\n-> END\n",
        .{ .diagnostics = sink },
    ));
    try std.testing.expectEqualStrings("ERROR: '' line 2: found declaration variable 'x' that " ++
        "was already declared (line 1)\n", out.written());
}
