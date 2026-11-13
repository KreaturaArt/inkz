//! The parsed-object tree: ink's ParsedHierarchy, built from the syntax
//! tree the way ink's constructors build it. A flow's statements are split into its weave and
//! its sub-flows (FlowBase.SplitWeaveAndSubFlowContent; the story's weave ends with a gather
//! and `-> DONE`), a weave nests its choices and gathers by indentation
//! (Weave.ConstructWeaveHierarchyFromIndentation), and conditional branches and sequence
//! elements hold their content in weaves. Names are resolved on this tree (resolve.zig), and
//! the lowering generates from it.
//!
//! An object is a row of parallel arrays: its kind, kind-specific flags, its parent, the syntax
//! node it came from (or none for the objects ink synthesizes), and its children, a contiguous
//! run of `children`. The tree is built with a work list, without recursion: expanding an
//! object creates all its children (shallowly) at once, so each child run is final as soon as
//! it is written. Objects are numbered in creation order, which is not tree order; passes that
//! need ink's order walk the tree.

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

    pub fn is_return(tree: *const Tree, object: ObjectIndex) bool {
        return tree.kind(object) == .@"return";
    }

    pub fn is_choice(tree: *const Tree, object: ObjectIndex) bool {
        return tree.kind(object) == .choice;
    }

    /// ink's IWeavePoint: a choice or a gather.
    pub fn is_weave_point(tree: *const Tree, object: ObjectIndex) bool {
        const object_kind = tree.kind(object);
        return object_kind == .choice or object_kind == .gather;
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

    /// A walk of `root_object`'s subtree (itself included); `deinit` it.
    pub fn walk(
        tree: *const Tree,
        gpa: Allocator,
        root_object: ObjectIndex,
        order: Walk.Order,
    ) Walk {
        assert(root_object.to_int() < tree.count());
        return .{ .tree = tree, .gpa = gpa, .order = order, .start = root_object };
    }

    /// ink's Object.FindAll: every object of `root`'s subtree (itself included) that `query`
    /// accepts, in pre-order (so the first is ink's Object.Find).
    pub fn find_all(
        tree: *const Tree,
        gpa: Allocator,
        root_object: ObjectIndex,
        comptime query: fn (*const Tree, ObjectIndex) bool,
        found: *std.ArrayList(ObjectIndex),
    ) !void {
        var objects = tree.walk(gpa, root_object, .pre);
        defer objects.deinit();
        while (try objects.next()) |object| {
            if (query(tree, object)) try found.append(gpa, object);
        }
    }

    /// ink's Object.Find: the first object of `root`'s subtree that `query` accepts.
    pub fn find(
        tree: *const Tree,
        gpa: Allocator,
        root_object: ObjectIndex,
        comptime query: fn (*const Tree, ObjectIndex) bool,
    ) !?ObjectIndex {
        var objects = tree.walk(gpa, root_object, .pre);
        defer objects.deinit();
        while (try objects.next()) |object| {
            if (query(tree, object)) return object;
        }
        return null;
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

/// A walk of a subtree without recursion, in pre-order (an object, then its children) or
/// post-order (the children, then the object). The stack holds one frame per level, not the
/// pending siblings, so it grows to the subtree's depth once and nothing is allocated per
/// object.
pub const Walk = struct {
    tree: *const Tree,
    gpa: Allocator,
    order: Order,
    /// The subtree's root, until the first `next`.
    start: ?ObjectIndex,
    frames: std.ArrayList(Frame) = .empty,

    pub const Order = enum { pre, post };
    const Frame = struct { object: ObjectIndex, next_child: u32 = 0 };

    pub fn deinit(walk: *Walk) void {
        assert(walk.frames.items.len <= walk.tree.count());
        walk.frames.deinit(walk.gpa);
    }

    pub fn next(walk: *Walk) Allocator.Error!?ObjectIndex {
        if (walk.start) |root| {
            walk.start = null;
            try walk.frames.append(walk.gpa, .{ .object = root });
            if (walk.order == .pre) return root;
        }
        while (walk.frames.items.len > 0) {
            const top = &walk.frames.items[walk.frames.items.len - 1];
            const children = walk.tree.children_of(top.object);
            if (top.next_child == children.len) {
                const done = walk.frames.pop().?;
                if (walk.order == .post) return done.object;
                continue;
            }
            const child = children[top.next_child];
            top.next_child += 1;
            try walk.frames.append(walk.gpa, .{ .object = child });
            if (walk.order == .pre) return child;
        }
        return null;
    }

    /// The depth below the subtree's root of the object `next` returned last (pre-order).
    pub fn depth(walk: *const Walk) u32 {
        assert(walk.order == .pre);
        assert(walk.frames.items.len > 0);
        return @intCast(walk.frames.items.len - 1);
    }
};

/// Where an object starts in the source: its syntax node's first token, or as ink's
/// debugMetadata, its parent's (for objects ink synthesizes, or with no text of their own).
pub fn object_offset(
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    object_initial: ObjectIndex,
) u32 {
    assert(object_initial.to_int() < tree.count());
    assert(tree.nodes.len == tree.kinds.len);
    var object = object_initial;
    while (!object.is_none()) : (object = tree.parent(object)) {
        // The "\n" ink ends a line with has the line's position: its content's.
        if (tree.kind(object) == .text and tree.has(object, Flags.newline)) {
            if (line_start(parsed, tree, object)) |offset| return offset;
        }
        if (tree.node(object).is_none()) continue;
        if (first_token(parsed, tree.node(object))) |token| {
            return parsed.workspace.token_starts[token];
        }
    }
    return 0;
}

/// Where the content before a newline starts: its nearest earlier sibling with a token.
fn line_start(parsed: *const grammar.Parsed, tree: *const Tree, newline: ObjectIndex) ?u32 {
    assert(tree.kind(newline) == .text);
    const siblings = tree.children_of(tree.parent(newline));
    var position = std.mem.indexOfScalar(ObjectIndex, siblings, newline).?;
    assert(position < siblings.len);
    while (position > 0) {
        position -= 1;
        const sibling = siblings[position];
        if (tree.kind(sibling) == .text and tree.has(sibling, Flags.newline)) return null;
        if (tree.node(sibling).is_none()) continue;
        const token = first_token(parsed, tree.node(sibling)) orelse continue;
        return parsed.workspace.token_starts[token];
    }
    return null;
}

/// The first token under a syntax node, if any.
fn first_token(parsed: *const grammar.Parsed, root: NodeIndex) ?u32 {
    assert(!root.is_none());
    const ast = &parsed.tree;
    assert(root.to_int() < ast.tags.len);
    var stack: [64]NodeIndex = undefined;
    var depth: u32 = 1;
    stack[0] = root;
    while (depth > 0) {
        depth -= 1;
        const node = stack[depth];
        switch (ast_module.shape(ast.tag(node))) {
            .leaf => if (has_token(ast.tag(node))) return ast.data[node.to_int()],
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
    return null;
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

/// Builds the object tree of a compilation with INCLUDEs.
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
    var objects = tree.walk(gpa, Tree.root, .pre);
    defer objects.deinit();
    while (try objects.next()) |object| {
        try out.writer.splatByteAll(' ', 2 * objects.depth());
        try out.writer.print("{t}", .{tree.kind(object)});
        try render_label(parsed, tree, object, &out.writer);
        try out.writer.writeByte('\n');
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
    try out.print(" \"{s}\"", .{parsed.leaf_text(leaf)});
}

fn expect_tree(source: []const u8, expected: []const u8) !void {
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

test "walks visit a subtree in pre-order and post-order" {
    // The walker's orders: a nested story's walks against the definitions:
    // every object once; pre-order puts each object right before its children's subtrees,
    // post-order is the mirror image of pre-order over reversed children.
    const gpa = std.testing.allocator;
    const source = "A\n* B\n  ** C\n- D {x: E|F}\n== k ==\nG\n= s\nH\n";
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    var tree = try build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    var pre: std.ArrayList(ObjectIndex) = .empty;
    defer pre.deinit(gpa);
    var post: std.ArrayList(ObjectIndex) = .empty;
    defer post.deinit(gpa);
    inline for (.{ .pre, .post }, .{ &pre, &post }) |order, list| {
        var objects = tree.walk(gpa, Tree.root, order);
        defer objects.deinit();
        while (try objects.next()) |object| try list.append(gpa, object);
        try std.testing.expectEqual(tree.count(), list.items.len);
    }
    try std.testing.expectEqual(Tree.root, pre.items[0]);
    try std.testing.expectEqual(Tree.root, post.items[post.items.len - 1]);
    // Pre-order: the object after a parent is its first child; post-order: before it, its
    // last child.
    for (pre.items, 0..) |object, position| {
        const children = tree.children_of(object);
        if (children.len > 0) try std.testing.expectEqual(children[0], pre.items[position + 1]);
    }
    for (post.items, 0..) |object, position| {
        const children = tree.children_of(object);
        if (children.len == 0) continue;
        try std.testing.expectEqual(children[children.len - 1], post.items[position - 1]);
    }
    // A walk of a subtree stays in it.
    const weave = tree.children_of(Tree.root)[0];
    var objects = tree.walk(gpa, weave, .pre);
    defer objects.deinit();
    while (try objects.next()) |object| {
        var ancestor = object;
        while (ancestor != weave) ancestor = tree.parent(ancestor);
        if (object != weave) try std.testing.expect(objects.depth() > 0);
    }
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
