//! The new compiler's entry points: source to Program, as ink's
//! Compiler.Compile does it: parse (with INCLUDEs), and with no parse error, build the object
//! tree, resolve names, and with no error, lower, flatten, lay out and emit.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const Allocator = std.mem.Allocator;
const grammar = @import("grammar.zig");
const core = @import("core.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const source_space = @import("source_space.zig");
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const emit = @import("lower_emit.zig");
const ink_json = @import("../core/ink_json.zig");
const limits = @import("../core/limits.zig");
const Program = @import("../core/program.zig").Program;

pub const Error = error{
    /// The story has errors (see the diagnostics).
    CompileFailed,
};

/// Whether a parse diagnostic is one of ink's warnings (it doesn't stop compilation).
pub fn is_warning(diagnostic: core.Diagnostic) bool {
    assert(@backingInt(diagnostic.code) < 8);
    if (diagnostic.code != .message) return false;
    const message: grammar.Message = @fromBackingInt(@intCast(diagnostic.extra));
    return message == .return_without_tilde or message == .choice_empty or message == .choice_blank;
}

pub const Options = struct {
    /// ink's countAllVisits: count the visits of every knot, stitch, gather and choice.
    count_all_visits: bool = false,
};

/// The stages after parsing, on a parsed story (one file, or a space's). The object tree,
/// the resolution and the syntax are freed once lowered, before layout and emission.
fn compile_parsed(
    gpa: Allocator,
    parsed: *grammar.Parsed,
    space: ?*const source_space.Space,
    options: Options,
) !Program {
    assert(parsed.tree.tags.len > 0);
    assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
    for (parsed.diagnostics()) |diagnostic| {
        if (!is_warning(diagnostic)) return error.CompileFailed;
    }
    var lowered = try lower_parsed(gpa, parsed, space, options);
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
    if (resolution.diagnostics.len > 0) return error.CompileFailed;
    const lower_zone = profile.begin(.compile_lower);
    var lowering = try lower.Lowering.init(gpa, parsed, &tree, &resolution);
    errdefer lowering.deinit();
    lowering.count_all_visits = options.count_all_visits;
    try lowering.generate_all();
    try lowering.finish_story();
    lower_zone.end();
    if (lowering.failed()) return error.CompileFailed;
    const flatten_zone = profile.begin(.compile_flatten);
    defer flatten_zone.end();
    layout_module.set_count_flags(&lowering);
    try layout_module.flatten(&lowering);
    return lowering.into_lowered();
}

/// Compiles one ink file's text (INCLUDE needs `compile_file`).
pub fn compile_source(gpa: Allocator, source: []const u8) !Program {
    assert(@TypeOf(gpa) == Allocator);
    var parsed = parsed: {
        const profile_zone = profile.begin(.compile_parse);
        defer profile_zone.end();
        break :parsed try grammar.parse(gpa, source, .{});
    };
    defer parsed.deinit(gpa);
    return compile_parsed(gpa, &parsed, null, .{});
}

/// Compiles `path` (in `directory`) and the files it includes.
pub fn compile_file(gpa: Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !Program {
    assert(path.len > 0);
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
    var space = try source_space.load(gpa, io, directory, path, .{});
    defer space.deinit(gpa);
    if (space.problems.len > 0) return error.CompileFailed;
    return compile_parsed(gpa, &space.parsed, &space, options);
}

/// A story compiled and serialized as ink's JSON (for comparing with inklecate's).
pub fn compile_to_json(gpa: Allocator, source: []const u8) ![]u8 {
    assert(@TypeOf(gpa) == Allocator);
    var program = try compile_source(gpa, source);
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
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
