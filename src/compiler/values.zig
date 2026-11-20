//! Literal values: ink's Number with UnaryExpression.WithInner folding, single-text
//! strings and divert targets, as constants and global initial values use them; and list
//! item values, numbered as ink's ListDefinition numbers them (from 1; an explicit value
//! sets the count, and the next item continues from it).

const std = @import("std");
const assert = std.debug.assert;
const sema = @import("sema.zig");
const grammar = @import("grammar.zig");
const ast_module = @import("ast.zig");
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const NodeIndex = ast_module.NodeIndex;

pub const Literal = union(enum) {
    integer: i32,
    float: f32,
    bool: bool,
    /// A string expression of one text: the text token's range (escapes kept).
    string: []const u8,
    /// A divert target: the divert inside it.
    divert_target: ObjectIndex,
};

pub const Error = error{
    /// ink's WithInner throws for `-` on a bool.
    UnsupportedFold,
};

fn token_text(parsed: *const grammar.Parsed, leaf: NodeIndex) []const u8 {
    assert(leaf.to_int() < parsed.tree.tags.len);
    const tree = &parsed.tree;
    assert(ast_module.shape(tree.tag(leaf)) == .leaf);
    const token = tree.data[leaf.to_int()];
    const workspace = &parsed.workspace;
    return parsed.source[workspace.token_starts[token]..workspace.token_ends[token]];
}

/// The value of a number token: an integer may be written `- 5` (ink's ParseInt).
fn number(parsed: *const grammar.Parsed, leaf: NodeIndex) Literal {
    assert(leaf.to_int() < parsed.tree.tags.len);
    const text = token_text(parsed, leaf);
    assert(text.len > 0);
    switch (parsed.tree.tag(leaf)) {
        .true => return .{ .bool = true },
        .false => return .{ .bool = false },
        .float => return .{ .float = std.fmt.parseFloat(f32, text) catch 0 },
        .integer => {
            const negative = text[0] == '-';
            const digits = std.mem.trimStart(u8, text[@intFromBool(negative)..], " \t");
            // The parser checked the range (ink's ParseInt), so this fits.
            const magnitude = std.fmt.parseInt(i64, digits, 10) catch 0;
            const value: i64 = if (negative) -magnitude else magnitude;
            const clamped = std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32));
            return .{ .integer = @intCast(clamped) };
        },
        else => unreachable,
    }
}

/// UnaryExpression.WithInner on a number.
fn fold(operator: ast_module.Tag, inner: Literal) Error!Literal {
    assert(@backingInt(std.meta.activeTag(inner)) < 5);
    assert(operator == .negate or operator == .not);
    if (operator == .negate) return switch (inner) {
        .integer => |value| .{ .integer = -%value },
        .float => |value| .{ .float = -value },
        else => error.UnsupportedFold,
    };
    return switch (inner) {
        .integer => |value| .{ .bool = value == 0 },
        .float => |value| .{ .bool = value == 0.0 },
        .bool => |value| .{ .bool = !value },
        else => error.UnsupportedFold,
    };
}

/// The literal an expression object is, or null if it isn't one (a variable, a call, ...).
pub fn literal(
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    object: ObjectIndex,
) Error!?Literal {
    assert(object.to_int() < tree.count());
    assert(parsed.tree.tags.len > 0);
    const ast = &parsed.tree;
    switch (tree.kind(object)) {
        .number => return number(parsed, tree.node(object)),
        .string_expression => {
            const children = tree.children_of(object);
            if (children.len != 1 or tree.kind(children[0]) != .text) return null;
            return .{ .string = token_text(parsed, tree.node(children[0])) };
        },
        .divert_target => return .{ .divert_target = tree.children_of(object)[0] },
        .unary => {
            // Fold from the innermost number out, as each WithInner did when parsed.
            var operators: [64]ast_module.Tag = undefined;
            var count: u32 = 0;
            var current = object;
            while (tree.kind(current) == .unary) : (count += 1) {
                if (count == operators.len) return null;
                operators[count] = ast.tag(tree.node(current));
                current = tree.children_of(current)[0];
            }
            if (tree.kind(current) != .number) return null;
            var value = number(parsed, tree.node(current));
            while (count > 0) {
                count -= 1;
                value = try fold(operators[count], value);
            }
            return value;
        },
        else => return null,
    }
}

/// ink's Expression.Equals for constants: the same literal.
pub fn equal(a: Literal, b: Literal) bool {
    assert(@backingInt(std.meta.activeTag(b)) < 5);
    assert(@backingInt(std.meta.activeTag(a)) < 5);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .bool => |value| value == b.bool,
        .string => |text| std.mem.eql(u8, text, b.string),
        .divert_target => |divert| divert == b.divert_target,
    };
}

/// ink's ListDefinition numbering: each item's series value, by item object.
pub fn number_list(
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    definition: ObjectIndex,
    values: []i32,
) void {
    assert(tree.kind(definition) == .list_definition);
    assert(values.len == tree.count());
    const ast = &parsed.tree;
    var current: i32 = 1;
    for (tree.children_of(definition)) |element| {
        const explicit = ast.child(tree.node(element), 1);
        if (ast.tag(explicit) == .integer) current = number(parsed, explicit).integer;
        values[element.to_int()] = current;
        current +%= 1;
    }
}

test "list items number from 1, and an explicit value sets the count" {
    // The auto-numbering the old compiler got wrong (test/known_bugs.zon,
    // audit/list_auto_numbering: ink prints 6 10 11). Number two lists.
    const gpa = std.testing.allocator;
    var parsed = try grammar.parse(
        gpa,
        "LIST levels = low = 5, mid, (high = 10), top\nLIST plain = a, b, c\n",
        .{},
    );
    defer parsed.deinit(gpa);
    var tree = try sema.build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    const values = try gpa.alloc(i32, tree.count());
    defer gpa.free(values);
    @memset(values, 0);
    var found: [2]ObjectIndex = undefined;
    var count: u32 = 0;
    for (0..tree.count()) |position| {
        const object: ObjectIndex = .from_int(@intCast(position));
        if (tree.kind(object) != .list_definition) continue;
        found[count] = object;
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
    // Objects are numbered in creation order, not source order: tell the lists by size.
    if (tree.children_of(found[0]).len == 3) std.mem.swap(ObjectIndex, &found[0], &found[1]);
    const expected = [_][]const i32{ &.{ 5, 6, 10, 11 }, &.{ 1, 2, 3 } };
    for (found, expected) |definition, numbers| {
        number_list(&parsed, &tree, definition, values);
        for (tree.children_of(definition), numbers) |element, value| {
            try std.testing.expectEqual(value, values[element.to_int()]);
        }
    }
}

test "literals fold unary operators as ink's WithInner" {
    const gpa = std.testing.allocator;
    var parsed = try grammar.parse(
        gpa,
        "CONST a = - -5\nCONST b = not 0\nCONST c = !true\nCONST d = -1.5\nCONST e = \"s\"\n",
        .{},
    );
    defer parsed.deinit(gpa);
    var tree = try sema.build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    const expected = [_]Literal{
        .{ .integer = 5 },
        .{ .bool = true },
        .{ .bool = false },
        .{ .float = -1.5 },
        .{ .string = "s" },
    };
    var seen: u32 = 0;
    for (0..tree.count()) |position| {
        const object: ObjectIndex = .from_int(@intCast(position));
        if (tree.kind(object) != .constant_declaration) continue;
        const value = (try literal(&parsed, &tree, tree.children_of(object)[0])).?;
        try std.testing.expect(equal(expected[seen], value));
        seen += 1;
    }
    try std.testing.expectEqual(@as(u32, expected.len), seen);
}
