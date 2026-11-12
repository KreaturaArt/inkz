//! The parsed-object tree (plan §4.12, P8.1): ink's ParsedHierarchy, built from the syntax
//! tree the way ink's constructors build it. A flow's statements are split into its weave and
//! its sub-flows (FlowBase.SplitWeaveAndSubFlowContent; the story's weave ends with a gather
//! and `-> DONE`), a weave nests its choices and gathers by indentation
//! (Weave.ConstructWeaveHierarchyFromIndentation), and conditional branches and sequence
//! elements hold their content in weaves. Names are resolved on this tree (resolve.zig), and
//! the lowering (P8.4) generates from it.
//!
//! An object is a row of parallel arrays: its kind, kind-specific flags, its parent, the syntax
//! node it came from (or none for the objects ink synthesizes), and its children, a contiguous
//! run of `children`. The tree is built breadth-first with a work list, without recursion:
//! creating an object creates its children (shallowly) at once, so each child run is final as
//! soon as it is written.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast_module = @import("ast.zig");
const grammar = @import("grammar.zig");
const build = @import("sema_build.zig");
const source_space = @import("source_space.zig");
const index = @import("../core/index.zig");
const Ast = ast_module.Ast;
const NodeIndex = ast_module.NodeIndex;
const Tag = ast_module.Tag;

pub const ObjectIndex = index.Index("object");

/// ink's parsed object classes.
pub const Kind = enum(u8) {
    // FlowBase: the story, knots and stitches (functions are flagged).
    story,
    knot,
    stitch,
    weave,
    choice,
    gather,
    content_list,
    /// Text, including the "\n" ink appends and its "<ERROR IN FLOW>".
    text,
    glue,
    tag,
    divert,
    tunnel_onwards,
    conditional,
    conditional_branch,
    sequence,
    /// VAR, temp, assignment and LIST (flags say which).
    variable_assignment,
    constant_declaration,
    list_definition,
    list_element,
    external_declaration,
    @"return",
    author_warning,
    included_file,
    // Expressions.
    number,
    string_expression,
    variable_reference,
    function_call,
    divert_target,
    binary,
    unary,
    /// `x++`, `x--`, `x += e`, `x -= e` (ink's IncDecExpression).
    increment,
    list_literal,
    multiple_condition,
};

/// Kind-specific flags.
pub const Flags = struct {
    pub const function: u16 = 1 << 0;
    /// Text: the "\n" ink adds; tag: a start (otherwise an end).
    pub const newline: u16 = 1 << 1;
    pub const tag_start: u16 = 1 << 1;
    /// An expression output when complete (`{x}` in content).
    pub const output: u16 = 1 << 2;
    /// Divert kinds.
    pub const tunnel: u16 = 1 << 3;
    pub const thread: u16 = 1 << 4;
    pub const empty: u16 = 1 << 5;
    pub const function_call: u16 = 1 << 6;
    /// Synthesized `-> DONE` (the story's weave end).
    pub const done: u16 = 1 << 7;
    /// Variable assignments.
    pub const global: u16 = 1 << 3;
    pub const new_temporary: u16 = 1 << 4;
    pub const list: u16 = 1 << 5;
    /// Conditionals and branches.
    pub const inline_conditional: u16 = 1 << 3;
    pub const @"else": u16 = 1 << 4;
    /// A function call whose value is dropped (`~ f()`).
    pub const pop_result: u16 = 1 << 3;
    /// Increments: decrement, and with an expression (`+=`, `-=`).
    pub const decrement: u16 = 1 << 3;
    pub const by_expression: u16 = 1 << 4;
    /// Choices: sticky (not once-only).
    pub const sticky: u16 = 1 << 3;
};

pub const Tree = struct {
    kinds: []const Kind,
    flags: []const u16,
    parents: []const ObjectIndex,
    nodes: []const NodeIndex,
    children_first: []const u32,
    children_count: []const u32,
    children: []const ObjectIndex,
    /// A weave's base indentation (ink's baseIndentIndex), by object; 0 for other objects.
    indents: []const u32,

    pub const root: ObjectIndex = .from_int(0);

    pub fn count(tree: *const Tree) u32 {
        assert(tree.kinds.len == tree.parents.len);
        assert(tree.kinds.len > 0);
        return @intCast(tree.kinds.len);
    }

    pub fn kind(tree: *const Tree, object: ObjectIndex) Kind {
        assert(object.to_int() < tree.count());
        assert(tree.kinds.len == tree.flags.len);
        return tree.kinds[object.to_int()];
    }

    pub fn has(tree: *const Tree, object: ObjectIndex, flag: u16) bool {
        assert(object.to_int() < tree.count());
        assert(flag != 0);
        return tree.flags[object.to_int()] & flag != 0;
    }

    pub fn parent(tree: *const Tree, object: ObjectIndex) ObjectIndex {
        assert(object.to_int() < tree.count());
        assert(tree.parents[0] == .none);
        return tree.parents[object.to_int()];
    }

    pub fn node(tree: *const Tree, object: ObjectIndex) NodeIndex {
        assert(object.to_int() < tree.count());
        assert(tree.nodes.len == tree.kinds.len);
        return tree.nodes[object.to_int()];
    }

    pub fn children_of(tree: *const Tree, object: ObjectIndex) []const ObjectIndex {
        assert(object.to_int() < tree.count());
        const first = tree.children_first[object.to_int()];
        const length = tree.children_count[object.to_int()];
        assert(first + length <= tree.children.len);
        return tree.children[first..][0..length];
    }

    pub fn is_flow(tree: *const Tree, object: ObjectIndex) bool {
        assert(tree.kinds.len == tree.parents.len);
        const object_kind = tree.kind(object);
        assert(@backingInt(object_kind) < @typeInfo(Kind).@"enum".field_names.len);
        return object_kind == .story or object_kind == .knot or object_kind == .stitch;
    }

    /// ink's ClosestFlowBase: the object itself if it is a flow, else its nearest flow.
    pub fn closest_flow(tree: *const Tree, object: ObjectIndex) ObjectIndex {
        var current = object;
        var steps: u32 = 0;
        while (!tree.is_flow(current)) : (steps += 1) {
            assert(steps < tree.count());
            current = tree.parent(current);
        }
        assert(tree.is_flow(current));
        return current;
    }

    pub fn deinit(tree: *Tree, gpa: Allocator) void {
        assert(tree.kinds.len == tree.parents.len);
        assert(tree.kinds.len > 0);
        gpa.free(tree.kinds);
        gpa.free(tree.flags);
        gpa.free(tree.parents);
        gpa.free(tree.nodes);
        gpa.free(tree.children_first);
        gpa.free(tree.children_count);
        gpa.free(tree.children);
        gpa.free(tree.indents);
        tree.* = undefined;
    }
};

/// Where an object starts in the source: its syntax node's first token (the object's
/// parent's, for objects ink synthesizes).
pub fn object_offset(
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    object_initial: ObjectIndex,
) u32 {
    assert(object_initial.to_int() < tree.count());
    assert(tree.nodes.len == tree.kinds.len);
    var object = object_initial;
    while (tree.node(object).is_none()) object = tree.parent(object);
    const ast = &parsed.tree;
    var stack: [64]NodeIndex = undefined;
    var depth: u32 = 1;
    stack[0] = tree.node(object);
    while (depth > 0) {
        depth -= 1;
        const node = stack[depth];
        switch (ast_module.shape(ast.tag(node))) {
            .leaf => if (has_token(ast.tag(node))) {
                return parsed.workspace.token_starts[ast.data[node.to_int()]];
            },
            .fixed => |count| {
                var position: u32 = count;
                while (position > 0 and depth < stack.len) : (depth += 1) {
                    position -= 1;
                    stack[depth] = ast.child(node, position);
                }
            },
            .list => {
                var position = ast.list(node).count;
                while (position > 0 and depth < stack.len) : (depth += 1) {
                    position -= 1;
                    stack[depth] = ast.item(node, position);
                }
            },
        }
    }
    return 0;
}

fn has_token(tag: Tag) bool {
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    assert(ast_module.shape(tag) == .leaf);
    return switch (tag) {
        .none, .missing, .count, .header, .newline, .tag_end => false,
        .empty_divert, .sequence_kind => false,
        else => true,
    };
}

/// Builds the object tree of a parsed story.
pub fn build_tree(gpa: Allocator, parsed: *const grammar.Parsed) !Tree {
    assert(parsed.tree.tags.len == parsed.tree.data.len);
    assert(parsed.tree.tag(parsed.tree.root) == .story);
    var builder: build.Builder = .{ .gpa = gpa, .parsed = parsed };
    defer builder.deinit();
    try builder.run();
    return builder.finish();
}

/// Builds the object tree of a compilation with INCLUDEs (plan P8.2).
pub fn build_space_tree(gpa: Allocator, space: *const source_space.Space) !Tree {
    assert(space.files.len > 0);
    assert(space.parsed.tree.tag(space.parsed.tree.root) == .story);
    var builder: build.Builder = .{ .gpa = gpa, .parsed = &space.parsed, .space = space };
    defer builder.deinit();
    try builder.run();
    return builder.finish();
}

// Tests.

const dump = @import("dump.zig");

/// The tree as one line per object, indented: its kind and the name or text it carries.
fn render(gpa: Allocator, parsed: *const grammar.Parsed, tree: *const Tree) ![]u8 {
    assert(tree.kinds.len == tree.parents.len);
    assert(tree.children.len < tree.kinds.len);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const Entry = struct { object: ObjectIndex, depth: u32 };
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .object = Tree.root, .depth = 0 });
    while (stack.pop()) |entry| {
        try out.writer.splatByteAll(' ', 2 * entry.depth);
        try out.writer.print("{t}", .{tree.kind(entry.object)});
        try render_label(parsed, tree, entry.object, &out.writer);
        try out.writer.writeByte('\n');
        const children = tree.children_of(entry.object);
        var position = children.len;
        while (position > 0) {
            position -= 1;
            try stack.append(gpa, .{ .object = children[position], .depth = entry.depth + 1 });
        }
    }
    return out.toOwnedSlice();
}

fn render_label(
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    object: ObjectIndex,
    out: *std.Io.Writer,
) !void {
    assert(tree.kinds.len == tree.parents.len);
    assert(tree.children.len < tree.kinds.len);
    const node = tree.node(object);
    if (node.is_none()) return;
    const ast = &parsed.tree;
    const token_node: ?NodeIndex = switch (ast.tag(node)) {
        .knot, .function, .stitch, .function_stitch => ast.child(node, 0),
        .text, .text_space, .glue => node,
        .choice, .sticky_choice, .gather => ast.child(node, 1),
        else => null,
    };
    const leaf = token_node orelse return;
    if (ast.tag(leaf) == .none) return;
    const token = ast.data[leaf.to_int()];
    const workspace = &parsed.workspace;
    try out.print(
        " \"{s}\"",
        .{parsed.source[workspace.token_starts[token]..workspace.token_ends[token]]},
    );
}

fn expect_tree(source: []const u8, expected: []const u8) !void {
    assert(source.len < std.math.maxInt(u32));
    assert(expected.len > 0);
    const gpa = std.testing.allocator;
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    var tree = try build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    const text = try render(gpa, &parsed, &tree);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
    _ = dump;
}

test "the story's weave ends with a gather and -> DONE; knots come after it" {
    try expect_tree("Hello.\n-> k\n== k ==\nIn k.\n= s\nIn s.\n",
        \\story
        \\  weave
        \\    text "Hello."
        \\    text
        \\    divert
        \\    gather
        \\    divert
        \\  knot "k"
        \\    weave
        \\      text "In k."
        \\      text
        \\    stitch "s"
        \\      weave
        \\        text "In s."
        \\        text
        \\
    );
}

test "weaves nest by indentation, as ink's ConstructWeaveHierarchyFromIndentation" {
    try expect_tree("* A\n** B\n*** C\n** D\n- (g) G\n",
        \\story
        \\  weave
        \\    choice
        \\      content_list
        \\        text "A"
        \\      content_list
        \\        text
        \\    weave
        \\      choice
        \\        content_list
        \\          text "B"
        \\        content_list
        \\          text
        \\      weave
        \\        choice
        \\          content_list
        \\            text "C"
        \\          content_list
        \\            text
        \\      choice
        \\        content_list
        \\          text "D"
        \\        content_list
        \\          text
        \\    gather "g"
        \\    text "G"
        \\    text
        \\    gather
        \\    divert
        \\
    );
}

test "branch and sequence bodies are weaves; an empty sequence element stays a list" {
    try expect_tree("{x:\n- 1: * c\n- else: e\n}\n{|b}\n",
        \\story
        \\  weave
        \\    content_list
        \\      conditional
        \\        variable_reference
        \\        conditional_branch
        \\          weave
        \\            choice
        \\              content_list
        \\                text "c"
        \\              content_list
        \\                text
        \\          number
        \\        conditional_branch
        \\          weave
        \\            text "e"
        \\            text
        \\    text
        \\    content_list
        \\      sequence
        \\        content_list
        \\        weave
        \\          text "b"
        \\    text
        \\    gather
        \\    divert
        \\
    );
}

test "expressions keep ink's shape: calls hold a proxy divert, {x} is the expression" {
    try expect_tree("~ temp a = f(1) + 2\n{a}\n~ g()\n",
        \\story
        \\  weave
        \\    content_list
        \\      variable_assignment
        \\        binary
        \\          function_call
        \\            divert
        \\              number
        \\          number
        \\      text
        \\    content_list
        \\      variable_reference
        \\    text
        \\    content_list
        \\      function_call
        \\        divert
        \\      text
        \\    gather
        \\    divert
        \\
    );
}

fn expect_space_tree(comptime name: []const u8, expected: []const u8) !void {
    assert(name.len > 0);
    assert(expected.len > 0);
    const gpa = std.testing.allocator;
    var directory = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "test/fixture/original/runtime/misc",
        .{},
    );
    defer directory.close(std.testing.io);
    var space = try source_space.load(gpa, std.testing.io, directory, name, .{});
    defer space.deinit(gpa);
    var tree = try build_space_tree(gpa, &space);
    defer tree.deinit(gpa);
    const text = try render(gpa, &space.parsed, &tree);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "include.ink: each included story's weave and a newline where its INCLUDE was" {
    try expect_space_tree("include.ink",
        \\story
        \\  weave
        \\    weave
        \\      text "This is include 1."
        \\      text
        \\    text
        \\    weave
        \\      text "This is include 2."
        \\      text
        \\    text
        \\    text "This is the main file."
        \\    text
        \\    gather
        \\    divert
        \\
    );
}

test "nested_include.ink: an include's include nests, and its knot moves to the story" {
    const gpa = std.testing.allocator;
    var directory = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "test/fixture/original/runtime/misc",
        .{},
    );
    defer directory.close(std.testing.io);
    var space = try source_space.load(gpa, std.testing.io, directory, "nested_include.ink", .{});
    defer space.deinit(gpa);
    var tree = try build_space_tree(gpa, &space);
    defer tree.deinit(gpa);
    const text = try render(gpa, &space.parsed, &tree);
    defer gpa.free(text);
    // The included knot is a child of the story, after its weave.
    try std.testing.expect(std.mem.indexOf(u8, text, "\n  knot \"knot_in_2\"\n") != null);
}
