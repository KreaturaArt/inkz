//! INCLUDE in the object tree, as ink's Story.PreProcessTopLevelObjects does it:
//! at a story's top level, an INCLUDE becomes the included story's weave (if it has one)
//! and a "\n", and the included story's flows (its own, then those of its includes) go to
//! the end of the including story's flows. An INCLUDE that failed is dropped; one below the
//! top level stays an inert IncludedFile. The walks over include chains use explicit stacks.

const std = @import("std");
const assert = std.debug.assert;
const ast_module = @import("ast.zig");
const source_space = @import("source_space.zig");
const Ast = ast_module.Ast;
const NodeIndex = ast_module.NodeIndex;
const Tag = ast_module.Tag;

/// What a story-level INCLUDE contributes.
pub const Contribution = enum { nothing, newline, weave_and_newline };

/// A story's statements list.
pub fn statements_of(tree: *const Ast, story: NodeIndex) NodeIndex {
    assert(tree.tag(story) == .story);
    const statements = tree.item(story, 0);
    assert(tree.tag(statements) == .statements);
    return statements;
}

fn is_flow_tag(tag: Tag) bool {
    assert(@sizeOf(Tag) == 1);
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    return tag == .knot or tag == .function or tag == .stitch or tag == .function_stitch;
}

/// ink's `subStory.content != null`: whether the included story has anything at all, its
/// own statements or content from its includes.
fn has_content(space: *const source_space.Space, story: NodeIndex) bool {
    assert(space.files.len > 0);
    assert(space.parsed.roots.len == space.files.len);
    const tree = &space.parsed.tree;
    var stack: [64]NodeIndex = undefined;
    var depth: u32 = 1;
    stack[0] = story;
    while (depth > 0) {
        depth -= 1;
        const statements = statements_of(tree, stack[depth]);
        for (0..tree.list(statements).count) |position| {
            const item = tree.item(statements, position);
            if (tree.tag(item) != .include) return true;
            const included = space.included_story(item) orelse continue;
            if (depth == stack.len) return true;
            stack[depth] = included;
            depth += 1;
        }
    }
    return false;
}

/// What an INCLUDE at a story's top level contributes to that story's weave.
pub fn contribution(space: *const source_space.Space, include: NodeIndex) Contribution {
    assert(space.files.len > 0);
    const tree = &space.parsed.tree;
    assert(tree.tag(include) == .include);
    const story = space.included_story(include) orelse return .nothing;
    if (!has_content(space, story)) return .nothing;
    // The included story has a weave if it has non-flow content, its own or an include's.
    const statements = statements_of(tree, story);
    for (0..tree.list(statements).count) |position| {
        const item = tree.item(statements, position);
        const tag = tree.tag(item);
        if (tag == .include) {
            const inner = space.included_story(item) orelse continue;
            if (has_content(space, inner)) return .weave_and_newline;
        } else if (!is_flow_tag(tag)) return .weave_and_newline;
    }
    return .newline;
}

/// The flows a story brings in through its top-level INCLUDEs, in ink's order: for each
/// INCLUDE, the included story's own flows, then (depth first) its includes' flows.
pub fn hoisted_flows(
    gpa: std.mem.Allocator,
    space: *const source_space.Space,
    story: NodeIndex,
    out: *std.ArrayList(NodeIndex),
) !void {
    assert(space.files.len > 0);
    const tree = &space.parsed.tree;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(gpa);
    try push_included(gpa, space, story, &stack);
    while (stack.pop()) |included| {
        const statements = statements_of(tree, included);
        for (0..tree.list(statements).count) |position| {
            const item = tree.item(statements, position);
            if (is_flow_tag(tree.tag(item))) try out.append(gpa, item);
        }
        try push_included(gpa, space, included, &stack);
    }
    assert(stack.items.len == 0);
}

/// Pushes a story's included stories so that they pop in order.
fn push_included(
    gpa: std.mem.Allocator,
    space: *const source_space.Space,
    story: NodeIndex,
    stack: *std.ArrayList(NodeIndex),
) !void {
    assert(space.files.len > 0);
    const tree = &space.parsed.tree;
    const statements = statements_of(tree, story);
    var position = tree.list(statements).count;
    const before = stack.items.len;
    while (position > 0) {
        position -= 1;
        const item = tree.item(statements, position);
        if (tree.tag(item) != .include) continue;
        if (space.included_story(item)) |included| try stack.append(gpa, included);
    }
    assert(stack.items.len >= before);
}
