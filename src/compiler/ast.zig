//! The compiler's syntax tree. A node is a one-byte tag and one
//! `u32` word, stored as two arrays: 5 bytes per node. Every tag has a shape:
//! - `leaf`: the word is a token index (a name, a text run, a number);
//! - `fixed(n)`: the word is the first of `n` contiguous child nodes;
//! - `list`: the word is the first of the children, and the first child is a `count` node
//!   whose word is how many items follow it.
//! Children are contiguous because the parser builds nodes with zirp's scratch stack and
//! `wrap` (as in the spike, docs/compiler_spike.md). `none` and `missing` fill optional
//! and absent required slots, so fixed shapes stay fixed.
//!
//! `shape` is one switch with no `else`, so a new tag can't be added without deciding its
//! shape.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");

pub const NodeIndex = index.Index("node");
pub const TokenIndex = index.Index("token");

pub const Tag = enum(u8) {
    // Slots.
    /// An optional child that isn't there.
    none,
    /// A required child the parser couldn't find (a diagnostic was recorded).
    missing,
    /// A list's length.
    count,
    /// A choice's or gather's indentation depth (the word's low 16 bits); for choices, bit 16
    /// says it has weave-style `[` brackets and bit 17 that it is an invisible default.
    header,

    // Files and flows (ink's Story, Knot, Stitch, FlowBase).
    /// The whole story: its top-level statements.
    story,
    /// `INCLUDE path`: the path's token.
    include,
    /// `== name(params) ==` and its body: name, parameters, statements.
    knot,
    /// `== function name(params) ==`: name, parameters, statements.
    function,
    /// `= name(params)`: name, parameters, statements; `function_stitch` is `= function name`.
    stitch,
    function_stitch,
    /// A name token: knot, stitch, label, variable, parameter or list member (`a.b`).
    identifier,
    /// A parameter's name; `ref name` and `-> name` have their own tags.
    parameter,
    reference_parameter,
    divert_parameter,
    parameters,
    statements,

    // Weave (ink's Choice and Gather; nesting is built later, from the depths).
    /// `*`: header, label, condition, start content, choice-only content, inner content.
    choice,
    /// `+`: the same.
    sticky_choice,
    /// `-`: header, label.
    gather,

    // Content.
    /// ink's ContentList. A `statements` item in it (a multiline branch's body) is spliced.
    content_list,
    /// A text run: the token's text with `\` escapes still in it.
    text,
    /// A text run with one space appended (ink's TrimEndWhitespace before a divert).
    text_space,
    /// The "\n" ink appends to lines and choices.
    newline,
    /// ink's "<ERROR IN FLOW>" recovery text.
    error_text,
    glue,
    /// `#` starts a tag; the end marker comes from ink's EndTagIfNecessary.
    tag_start,
    tag_end,
    /// `{expression}`: the expression, output when complete.
    inline_value,
    /// `{condition: ...}` over lines (`conditional`) or on one line (`inline_conditional`):
    /// the initial expression (or none) and the branches.
    conditional,
    inline_conditional,
    /// A branch: its own expression (or none) and its content.
    conditional_branch,
    /// `- else:`: its content.
    else_branch,
    branches,
    /// `{&a|b}` and the other kinds: the kind, and the elements (`branches` of content lists).
    sequence,
    /// A sequence's kind: ink's SequenceType flags in the word.
    sequence_kind,

    // Diverts.
    /// `-> target(arguments)`, `-> target ->` (a tunnel) and `<- target(arguments)`: the path
    /// and the arguments (or none).
    divert,
    tunnel,
    thread,
    /// A bare `->` on a choice.
    empty_divert,
    /// `->->`: the divert after it, or none.
    tunnel_onwards,
    /// Dotted path components: identifiers.
    path,
    arguments,

    // Logic.
    /// `~ temp name = expression`, `~ name = expression`, `+=`, `-=`: name and expression.
    temp_declaration,
    assignment,
    add_assignment,
    subtract_assignment,
    /// `~ return expression` (or none).
    @"return",
    /// `~ f()` on its own: the call, whose result is dropped.
    call_statement,
    /// `VAR name = expression`, `CONST name = expression`: name and expression.
    variable_declaration,
    const_declaration,
    /// `LIST name = items`: name and items.
    list_declaration,
    /// A LIST item: name and value (or none); `selected_list_item` is in parentheses.
    list_item,
    selected_list_item,
    list_items,
    /// `EXTERNAL name(params)`: name and parameters.
    external_declaration,
    /// `TODO: text`: the text token.
    author_warning,

    // Expressions.
    integer,
    float,
    true,
    false,
    /// `"text {logic}"`: content.
    string,
    /// A name or a dotted path read as a variable: the path.
    variable_reference,
    /// `name(arguments)`: name and arguments.
    function_call,
    /// `-> target` as a value: the divert.
    divert_target,
    /// `(a, b.c)`: identifiers.
    list_literal,
    /// Several choice conditions `{a} {b}` (ink's MultipleConditionExpression).
    conditions,
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    @"and",
    @"or",
    has,
    hasnt,
    intersect,
    negate,
    not,
    /// `name++` and `name--`: the name.
    increment,
    decrement,
};

pub const Shape = union(enum) {
    leaf,
    fixed: u8,
    list,
};

/// Every tag's shape. No `else`: adding a tag forces a decision here.
pub fn shape(tag: Tag) Shape {
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    assert(@sizeOf(Shape) <= 2);
    return switch (tag) {
        .none, .missing, .count, .header, .include, .identifier => .leaf,
        .parameter, .reference_parameter, .divert_parameter => .leaf,
        .text, .text_space, .newline, .error_text, .glue, .tag_start, .tag_end => .leaf,
        .sequence_kind, .empty_divert, .author_warning => .leaf,
        .integer, .float, .true, .false => .leaf,
        .story, .parameters, .statements, .content_list, .branches, .path => .list,
        .arguments, .list_items, .string, .list_literal, .conditions => .list,
        .knot, .function, .stitch, .function_stitch => .{ .fixed = 3 },
        .choice, .sticky_choice => .{ .fixed = 6 },
        .gather, .conditional, .inline_conditional, .conditional_branch => .{ .fixed = 2 },
        .sequence => .{ .fixed = 2 },
        .divert, .tunnel, .thread, .function_call => .{ .fixed = 2 },
        .temp_declaration, .assignment, .add_assignment, .subtract_assignment => .{ .fixed = 2 },
        .variable_declaration, .const_declaration, .list_declaration => .{ .fixed = 2 },
        .list_item, .selected_list_item, .external_declaration => .{ .fixed = 2 },
        .add, .subtract, .multiply, .divide, .modulo, .equal, .not_equal => .{ .fixed = 2 },
        .less, .greater, .less_equal, .greater_equal, .@"and", .@"or" => .{ .fixed = 2 },
        .has, .hasnt, .intersect => .{ .fixed = 2 },
        .inline_value, .else_branch, .tunnel_onwards, .@"return" => .{ .fixed = 1 },
        .call_statement => .{ .fixed = 1 },
        .variable_reference, .divert_target, .negate, .not => .{ .fixed = 1 },
        .increment, .decrement => .{ .fixed = 1 },
    };
}

pub const Ast = struct {
    tags: []const Tag,
    data: []const u32,
    root: NodeIndex,

    pub fn tag(ast: *const Ast, node: NodeIndex) Tag {
        assert(node.to_int() < ast.tags.len);
        assert(ast.tags.len == ast.data.len);
        return ast.tags[node.to_int()];
    }

    /// The token of a leaf.
    pub fn token(ast: *const Ast, node: NodeIndex) TokenIndex {
        assert(shape(ast.tag(node)) == .leaf);
        assert(node.to_int() < ast.data.len);
        return .from_int(ast.data[node.to_int()]);
    }

    /// Child `position` of a fixed-shape node.
    pub fn child(ast: *const Ast, node: NodeIndex, position: u32) NodeIndex {
        const node_shape = shape(ast.tag(node));
        assert(node_shape == .fixed and position < node_shape.fixed);
        const result: NodeIndex = .from_int(ast.data[node.to_int()] + position);
        assert(result.to_int() < ast.tags.len);
        return result;
    }

    /// How many items a list node has, and its first item.
    pub fn list(ast: *const Ast, node: NodeIndex) struct { first: NodeIndex, count: u32 } {
        assert(shape(ast.tag(node)) == .list);
        const counter = ast.data[node.to_int()];
        assert(ast.tags[counter] == .count);
        const count = ast.data[counter];
        assert(counter + 1 + count <= ast.tags.len);
        return .{ .first = .from_int(counter + 1), .count = count };
    }

    /// Item `position` of a list node.
    pub fn item(ast: *const Ast, node: NodeIndex, position: usize) NodeIndex {
        const items = ast.list(node);
        assert(position < items.count);
        return .from_int(items.first.to_int() + @as(u32, @intCast(position)));
    }
};

comptime {
    // Size guards: 5 bytes per node across the two arrays.
    assert(@sizeOf(Tag) == 1);
    assert(@sizeOf(u32) + @sizeOf(Tag) == 5);
    assert(@typeInfo(Tag).@"enum".field_names.len < 256);
    // Every fixed shape has at least one child, and no node has more than a choice.
    for (@typeInfo(Tag).@"enum".field_names) |name| {
        const tag_shape = shape(@field(Tag, name));
        if (tag_shape == .fixed) assert(tag_shape.fixed >= 1 and tag_shape.fixed <= 6);
    }
}

test "accessors follow each tag's shape" {
    // A tiny tree by hand. Nodes: 0 count(2), 1 text, 2 text, 3 content_list (list at 0),
    // then the choice's six children 4..9 and the choice 10.
    const tags = [_]Tag{
        .count,        .text,   .text, .content_list, .header, .none, .none, .content_list, .none,
        .content_list, .choice,
    };
    const data = [_]u32{ 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4 };
    const ast: Ast = .{ .tags = &tags, .data = &data, .root = .from_int(10) };
    try std.testing.expectEqual(Tag.none, ast.tag(ast.child(ast.root, 2)));
    try std.testing.expectEqual(Tag.content_list, ast.tag(ast.child(ast.root, 3)));
    const line = ast.list(.from_int(3));
    try std.testing.expectEqual(@as(u32, 2), line.count);
    try std.testing.expectEqual(@as(u32, 1), ast.token(ast.item(.from_int(3), 1)).to_int());
}
