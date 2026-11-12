//! The compiler's syntax tree (plan §4.11, P7.2, T3, T6). A node is a one-byte tag and one
//! `u32` word, stored as two arrays: 5 bytes per node. Every tag has a shape:
//! - `leaf`: the word is a token index (a name, a text run, a number);
//! - `fixed(n)`: the word is the first of `n` contiguous child nodes;
//! - `list`: the word is the first of the children, and the first child is a `count` node
//!   whose word is how many items follow it.
//! Children are contiguous because the parser builds nodes with zirp's scratch stack and
//! `wrap` (see the P7.0 spike). `none` and `missing` fill optional and absent required
//! slots, so fixed shapes stay fixed.
//!
//! `shape` is one switch with no `else`, so a new tag can't be added without deciding its
//! shape, and `to_typed` turns a node into a view generated from that shape at compile time.

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

    // Files and flows.
    /// The whole story: its top-level statements.
    story,
    /// `INCLUDE path`: the path's token.
    include,
    /// `== name(params) ==` and its body: name, parameters, body.
    knot,
    /// `== function name(params) ==`: name, parameters, body.
    function,
    /// `= name(params)`: name, parameters, body.
    stitch,
    /// A name token: knot, stitch, label, variable or parameter.
    identifier,
    /// A parameter: its name; `reference_parameter` is `ref name`; a divert parameter is
    /// `-> name`.
    parameter,
    reference_parameter,
    divert_parameter,
    /// Parameters, arguments, statements: a list.
    parameters,
    statements,

    // Weave.
    /// Statements at one weave level.
    weave,
    /// `*` or `+`: label, condition, start content, choice-only content, inner content, body.
    choice,
    sticky_choice,
    /// `-`: label, content.
    gather,
    /// `(name)` before a choice's or gather's content: the name.
    label,

    // Content.
    /// A line of text and logic.
    line,
    /// A text run token.
    text,
    /// `\x`: the escape token.
    escape,
    glue,
    /// `#` and the tag's content (text and logic) until the next tag or the line's end.
    tag,
    /// `{expression}` printed inline.
    inline_value,
    /// `{condition: then|else}`: condition, then, else.
    inline_conditional,
    /// `{&a|b}` and the other kinds: the kind's token, then the branches as a list.
    sequence,
    /// A branch of an inline construct or a sequence: content.
    branch,
    /// `{ condition: ... }` or `{ value: - case: ... }` over lines: the initial expression
    /// (or none) and the branches as a list.
    block_conditional,
    /// `- condition:` in a block: condition and body. `else_branch`: body only.
    block_branch,
    else_branch,

    // Diverts.
    /// `-> target(arguments)`: target and arguments.
    divert,
    /// `-> target ->`: target and arguments.
    tunnel,
    /// `<- target(arguments)`: target and arguments.
    thread,
    /// `->->`, optionally followed by a divert: the divert or none.
    tunnel_onwards,
    /// A dotted path of identifiers: a list.
    path,

    // Logic.
    /// `~ expression` on its own line.
    logic_line,
    /// `~ temp name = expression`: name and expression.
    temp_declaration,
    /// `~ name = expression`, `+=`, `-=`: name and expression.
    assignment,
    add_assignment,
    subtract_assignment,
    /// `~ return expression` (or none).
    @"return",
    /// `VAR name = expression`: name and expression.
    variable_declaration,
    /// `CONST name = expression`: name and expression.
    const_declaration,
    /// `LIST name = items`: name and items (a list of list_item).
    list_declaration,
    /// An item of a LIST declaration: name, value (or none); `selected_list_item` is in
    /// parentheses.
    list_item,
    selected_list_item,
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
    /// `name(arguments)`: path and arguments.
    function_call,
    /// `-> target` as a value: the path.
    divert_target,
    /// `(a, b.c)`: items (a list of paths).
    list_literal,
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
    /// `name++` and `name--`: the path.
    increment,
    decrement,
};

pub const Shape = union(enum) {
    leaf,
    fixed: u8,
    list,
};

/// Every tag's shape. No `else`: adding a tag forces a decision here (T6).
pub fn shape(tag: Tag) Shape {
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    assert(@sizeOf(Shape) <= 2);
    return switch (tag) {
        .none, .missing, .count => .leaf,
        .include, .identifier, .parameter, .reference_parameter, .divert_parameter => .leaf,
        .label, .text, .escape, .glue, .author_warning => .leaf,
        .integer, .float, .true, .false => .leaf,
        .story, .parameters, .statements, .weave, .line, .tag, .branch, .path => .list,
        .string, .list_literal => .list,
        .knot, .function, .stitch => .{ .fixed = 3 },
        .choice, .sticky_choice => .{ .fixed = 6 },
        .gather, .inline_conditional => .{ .fixed = if (tag == .gather) 2 else 3 },
        .sequence, .block_conditional, .block_branch, .divert, .tunnel, .thread => .{ .fixed = 2 },
        .variable_declaration, .const_declaration, .list_declaration => .{ .fixed = 2 },
        .temp_declaration, .assignment, .add_assignment, .subtract_assignment => .{ .fixed = 2 },
        .list_item, .selected_list_item, .external_declaration, .function_call => .{ .fixed = 2 },
        .add, .subtract, .multiply, .divide, .modulo, .equal, .not_equal => .{ .fixed = 2 },
        .less, .greater, .less_equal, .greater_equal, .@"and", .@"or" => .{ .fixed = 2 },
        .has, .hasnt, .intersect => .{ .fixed = 2 },
        .inline_value, .else_branch, .tunnel_onwards, .logic_line, .@"return" => .{ .fixed = 1 },
        .variable_reference, .divert_target, .negate, .not => .{ .fixed = 1 },
        .increment, .decrement => .{ .fixed = 1 },
    };
}

/// The typed view of a node with tag `tag` (T6): a token for leaves, the child nodes for
/// fixed shapes, the items for lists.
pub fn View(comptime tag: Tag) type {
    comptime assert(@backingInt(tag) < 256);
    comptime assert(@sizeOf(TokenIndex) == 4);
    return switch (comptime shape(tag)) {
        .leaf => struct { token: TokenIndex },
        .fixed => |count| struct { children: [count]NodeIndex },
        .list => struct { items: []const Tag, first: NodeIndex },
    };
}

/// A view of any node.
pub const Typed = blk: {
    const tags = @typeInfo(Tag).@"enum".field_names;
    var types: [tags.len]type = undefined;
    for (tags, 0..) |name, position| types[position] = View(@field(Tag, name));
    break :blk @Union(.auto, Tag, tags, &types, &@splat(.{}));
};

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

    /// The node as its typed view (T6).
    pub fn to_typed(ast: *const Ast, node: NodeIndex) Typed {
        const node_tag = ast.tag(node);
        assert(node.to_int() < ast.data.len);
        assert(ast.root.to_int() < ast.tags.len);
        switch (node_tag) {
            inline else => |comptime_tag| {
                const value: View(comptime_tag) = switch (comptime shape(comptime_tag)) {
                    .leaf => .{ .token = ast.token(node) },
                    .fixed => |count| fixed: {
                        var children: [count]NodeIndex = undefined;
                        for (&children, 0..) |*slot, position| slot.* = ast.child(
                            node,
                            @intCast(position),
                        );
                        break :fixed .{ .children = children };
                    },
                    .list => list: {
                        const items = ast.list(node);
                        const first = items.first.to_int();
                        const tags = ast.tags[first..][0..items.count];
                        break :list .{ .items = tags, .first = items.first };
                    },
                };
                return @unionInit(Typed, @tagName(comptime_tag), value);
            },
        }
    }
};

comptime {
    // T14 size guards: 5 bytes per node across the two arrays.
    assert(@sizeOf(Tag) == 1);
    assert(@sizeOf(u32) + @sizeOf(Tag) == 5);
    assert(@typeInfo(Tag).@"enum".field_names.len < 256);
    // Every fixed shape has at least one child, and no node has more than a choice.
    for (@typeInfo(Tag).@"enum".field_names) |name| {
        const tag_shape = shape(@field(Tag, name));
        if (tag_shape == .fixed) assert(tag_shape.fixed >= 1 and tag_shape.fixed <= 6);
    }
}

test "views follow each tag's shape" {
    // Goal: P7.2 coverage check: every tag has a typed view of its shape. Method: build a
    // tiny tree by hand (a choice with a list child) and read it back typed.
    // Nodes: 0 count(2), 1 text, 2 text, 3 line(list at 0), then the choice's six children
    // 4..9 and the choice 10.
    const tags = [_]Tag{
        .count, .text, .text, .line, .none, .none, .line, .none, .none, .weave, .choice,
    };
    const data = [_]u32{ 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4 };
    const ast: Ast = .{ .tags = &tags, .data = &data, .root = .from_int(10) };
    const choice = ast.to_typed(ast.root).choice;
    try std.testing.expectEqual(@as(u32, 6), @as(u32, @intCast(choice.children.len)));
    try std.testing.expectEqual(Tag.line, ast.tag(choice.children[2]));
    const line = ast.to_typed(.from_int(3)).line;
    try std.testing.expectEqual(@as(usize, 2), line.items.len);
    try std.testing.expectEqual(@as(u32, 1), ast.to_typed(.from_int(2)).text.token.to_int());
    inline for (@typeInfo(Tag).@"enum".field_names) |name| {
        // Every tag has a view type of its shape.
        _ = View(@field(Tag, name));
    }
}
