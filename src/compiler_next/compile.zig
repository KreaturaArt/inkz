//! The new compiler's entry points (plan P8.4): source to Program, as ink's
//! Compiler.Compile does it: parse (with INCLUDEs), and with no parse error, build the object
//! tree, resolve names, and with no error, lower, flatten, lay out and emit.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const grammar = @import("grammar.zig");
const core = @import("core.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const source_space = @import("source_space.zig");
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const emit = @import("lower_emit.zig");
const json = @import("lower_json.zig");
const limits = @import("../core/limits.zig");
const Program = @import("../core/program.zig").Program;

pub const Error = error{
    /// The story has errors (see the diagnostics).
    CompileFailed,
};

/// Whether a parse diagnostic is one of ink's warnings (it doesn't stop compilation).
fn is_warning(diagnostic: core.Diagnostic) bool {
    assert(diagnostic.offset < std.math.maxInt(u32));
    assert(@backingInt(diagnostic.code) < 8);
    if (diagnostic.code != .message) return false;
    const message: grammar.Message = @fromBackingInt(@intCast(diagnostic.extra));
    return message == .return_without_tilde or message == .choice_empty or message == .choice_blank;
}

/// What a compilation left: the diagnostics' counts, and the program if it succeeded.
pub const Compiled = struct {
    parse_errors: u32 = 0,
    resolve_errors: u32 = 0,
};

/// The stages after parsing, on a parsed story (one file, or a space's).
fn compile_parsed(
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    space: ?*const source_space.Space,
    json_out: ?*std.Io.Writer,
) !Program {
    assert(parsed.tree.tags.len > 0);
    assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
    for (parsed.diagnostics()) |diagnostic| {
        if (!is_warning(diagnostic)) return error.CompileFailed;
    }
    var tree = if (space) |files| try sema.build_space_tree(gpa, files) else try sema.build_tree(
        gpa,
        parsed,
    );
    defer tree.deinit(gpa);
    var resolution = try resolve.resolve(gpa, parsed, &tree);
    defer resolution.deinit(gpa);
    if (resolution.diagnostics.len > 0) return error.CompileFailed;
    var lowering = try lower.Lowering.init(gpa, parsed, &tree, &resolution);
    defer lowering.deinit();
    try lowering.generate_all();
    try lowering.finish_story();
    layout_module.set_count_flags(&lowering);
    try layout_module.flatten(&lowering);
    var layout = try layout_module.lay_out(&lowering);
    defer layout.deinit();
    if (json_out) |out| try json.write(&lowering, &layout, out);
    return emit.emit_program(&lowering, &layout);
}

/// Compiles one ink file's text (INCLUDE needs `compile_file`).
pub fn compile_source(gpa: Allocator, source: []const u8) !Program {
    assert(@TypeOf(gpa) == Allocator);
    assert(source.len < std.math.maxInt(u32));
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    return compile_parsed(gpa, &parsed, null, null);
}

/// Compiles `path` (in `directory`) and the files it includes.
pub fn compile_file(gpa: Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !Program {
    assert(std.fs.path.basename(path).len > 0);
    assert(path.len > 0);
    var space = try source_space.load(gpa, io, directory, path, .{});
    defer space.deinit(gpa);
    if (space.problems.len > 0) return error.CompileFailed;
    return compile_parsed(gpa, &space.parsed, &space, null);
}

/// The ink JSON of a story (for comparing the layout with inklecate's).
pub fn compile_to_json(gpa: Allocator, source: []const u8) ![]u8 {
    assert(source.len < std.math.maxInt(u32));
    assert(@TypeOf(gpa) == Allocator);
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var program = try compile_parsed(gpa, &parsed, null, &out.writer);
    program.deinit(gpa);
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
