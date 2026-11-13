//! Expressions into a container (ink's Expression.GenerateIntoContainer for each expression
//! class), without recursion: a frame stack where each frame emits its object's items around
//! its sub-expressions, one sub-expression at a time.

const std = @import("std");
const assert = std.debug.assert;
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const values = @import("values.zig");
const ast_module = @import("ast.zig");
const ir_module = @import("lower_ir.zig");
const logic = @import("lower_logic.zig");
const Lowering = lower.Lowering;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const ContainerId = ir_module.ContainerId;
const Item = ir_module.Item;
const Tag = ast_module.Tag;

const Frame = struct { object: ObjectIndex, stage: u32 = 0 };
const frames_max = 256;

/// Emits `expression` into `container`.
pub fn emit(lowering: *Lowering, container: ContainerId, expression: ObjectIndex) !void {
    assert(!container.is_none());
    assert(lower.is_expression(lowering.tree.kind(expression)));
    var frames: [frames_max]Frame = undefined;
    var depth: u32 = 1;
    frames[0] = .{ .object = expression };
    var steps: u32 = 0;
    while (depth > 0) : (steps += 1) {
        assert(steps < 64 * lowering.tree.count() + 64);
        const frame = &frames[depth - 1];
        const next = try step(lowering, container, frame);
        if (next) |child| {
            if (depth == frames_max) return error.ExpressionTooDeep;
            frames[depth] = .{ .object = child };
            depth += 1;
        } else if (frame.stage == done) depth -= 1;
    }
    assert(depth == 0);
}

/// A frame's stage once it has emitted everything.
const done = std.math.maxInt(u32);

/// Emits the frame's next items; returns a sub-expression to emit next, or null.
fn step(lowering: *Lowering, container: ContainerId, frame: *Frame) !?ObjectIndex {
    const tree = lowering.tree;
    const object = frame.object;
    // A finished frame is popped before the next step.
    assert(frame.stage != done);
    const children = tree.children_of(object);
    switch (tree.kind(object)) {
        .binary => return binary(lowering, container, frame, children),
        .multiple_condition => {
            // Each condition after the first is joined with && once it is emitted.
            if (frame.stage >= 2) _ = try lowering.ir.add(container, .{ .native = "&&" });
            if (frame.stage == children.len) {
                frame.stage = done;
                return null;
            }
            frame.stage += 1;
            return children[frame.stage - 1];
        },
        .unary => {
            if (frame.stage == 0) {
                if (try values.literal(lowering.parsed, tree, object)) |value| {
                    _ = try lowering.ir.add(container, literal_item(value));
                    frame.stage = done;
                    return null;
                }
                frame.stage = 1;
                return children[0];
            }
            const negate = lowering.ast().tag(tree.node(object)) == .negate;
            _ = try lowering.ir.add(container, .{ .native = if (negate) "_" else "!" });
            frame.stage = done;
            return null;
        },
        .variable_reference => return variable_reference(lowering, container, frame),
        .function_call => return function_call(lowering, container, frame),
        .increment => return increment(lowering, container, frame),
        else => {
            try leaf(lowering, container, object);
            frame.stage = done;
            return null;
        },
    }
}

fn binary(
    lowering: *Lowering,
    container: ContainerId,
    frame: *Frame,
    children: []const ObjectIndex,
) !?ObjectIndex {
    assert(children.len == 2);
    if (frame.stage < 2) {
        frame.stage += 1;
        return children[frame.stage - 1];
    }
    _ = try lowering.ir.add(container, .{
        .native = native_name(lowering.ast().tag(lowering.tree.node(frame.object))),
    });
    frame.stage = done;
    return null;
}

/// BinaryExpression's NativeNameForOp.
fn native_name(tag: Tag) []const u8 {
    assert(ast_module.shape(tag) != .leaf);
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    return switch (tag) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .modulo => "%",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .@"and" => "&&",
        .@"or" => "||",
        .has => "?",
        .hasnt => "!?",
        .intersect => "^",
        else => unreachable,
    };
}

fn literal_item(value: values.Literal) Item {
    assert(value != .string and value != .divert_target);
    assert(@backingInt(std.meta.activeTag(value)) < 5);
    return switch (value) {
        .integer => |integer| .{ .integer = integer },
        .float => |float| .{ .float = float },
        .bool => |boolean| .{ .boolean = boolean },
        .string => unreachable,
        .divert_target => unreachable,
    };
}

/// The expressions with no sub-expression frames of their own.
fn leaf(lowering: *Lowering, container: ContainerId, object: ObjectIndex) !void {
    const tree = lowering.tree;
    const ir = &lowering.ir;
    switch (tree.kind(object)) {
        .number => {
            const value = (try values.literal(lowering.parsed, tree, object)).?;
            _ = try ir.add(container, literal_item(value));
        },
        .string_expression => {
            _ = try ir.add_command(container, .begin_string);
            for (tree.children_of(object)) |child| try lowering.add_result(container, child);
            _ = try ir.add_command(container, .end_string);
        },
        .divert_target => {
            const divert = tree.children_of(object)[0];
            _ = try ir.add(container, .{
                .divert_target = logic.divert_item(lowering, divert).target,
            });
        },
        .list_literal => _ = try ir.add(container, try list_literal(lowering, object)),
        else => unreachable,
    }
}

/// A variable reference's name: its path joined with dots (ink's VariableReference.name).
pub fn reference_name(lowering: *const Lowering, reference: ObjectIndex) []const u8 {
    const ast = lowering.ast();
    assert(ast.tag(lowering.tree.node(reference)) == .variable_reference);
    const path = ast.child(lowering.tree.node(reference), 0);
    const first = lowering.parsed.leaf_text(ast.item(path, 0));
    const last = lowering.parsed.leaf_text(ast.item(path, ast.list(path).count - 1));
    // The components are one run of the source (`a.b`), so the name is that range.
    const start = @intFromPtr(first.ptr) - @intFromPtr(lowering.parsed.source.ptr);
    const end = @intFromPtr(last.ptr) + last.len - @intFromPtr(lowering.parsed.source.ptr);
    assert(start <= end and end <= lowering.parsed.source.len);
    return lowering.parsed.source[start..end];
}

/// VariableReference.GenerateIntoContainer. A constant is its value, copied in
/// (GenerateConstantIntoContainer): the constant's expression is the next frame.
fn variable_reference(lowering: *Lowering, container: ContainerId, frame: *Frame) !?ObjectIndex {
    const reference = frame.object;
    assert(lowering.tree.kind(reference) == .variable_reference);
    const target = lowering.resolution.targets[reference.to_int()];
    if (frame.stage == 1) {
        frame.stage = done;
        return null;
    }
    frame.stage = done;
    switch (lowering.resolution.references[reference.to_int()]) {
        .constant => {
            assert(lowering.tree.kind(target) == .constant_declaration);
            frame.stage = 1;
            return lowering.tree.children_of(target)[0];
        },
        .read_count => {
            assert(!target.is_none());
            _ = try lowering.ir.add(container, .{ .read_count = .{ .object = target } });
            return null;
        },
        else => {},
    }
    const name = reference_name(lowering, reference);
    _ = try lowering.ir.add(container, .{ .variable_reference = name });
    return null;
}

/// IncDecExpression.GenerateIntoContainer: `VAR? x`, the amount (an expression, or 1), the
/// operator and the assignment.
fn increment(lowering: *Lowering, container: ContainerId, frame: *Frame) !?ObjectIndex {
    const tree = lowering.tree;
    const ir = &lowering.ir;
    const object = frame.object;
    assert(tree.kind(object) == .increment);
    const node = tree.node(object);
    const name = if (tree.has(object, Flags.by_expression))
        lowering.parsed.child_text(node, 0)
    else
        reference_name_of_node(lowering, lowering.ast().child(node, 0));
    const children = tree.children_of(object);
    if (frame.stage == 0) {
        _ = try ir.add(container, .{ .variable_reference = name });
        frame.stage = 1;
        if (children.len > 0) return children[0];
        _ = try ir.add(container, .{ .integer = 1 });
    }
    _ = try ir.add(container, .{ .native = if (tree.has(object, Flags.decrement)) "-" else "+" });
    const global = lowering.resolution.references[object.to_int()] == .global;
    _ = try ir.add(container, .{ .assignment = .{ .name = name, .global = global, .new = false } });
    frame.stage = done;
    return null;
}

fn reference_name_of_node(lowering: *const Lowering, reference: ast_module.NodeIndex) []const u8 {
    const ast = lowering.ast();
    assert(ast.tag(reference) == .variable_reference);
    return lowering.parsed.leaf_text(ast.item(ast.child(reference, 0), 0));
}

/// FunctionCall.GenerateIntoContainer: a built-in's arguments then its command or native
/// function, a list's name making a list, or the proxy divert; then `pop` if the value is
/// dropped. Stage n means n arguments are done.
fn function_call(lowering: *Lowering, container: ContainerId, frame: *Frame) !?ObjectIndex {
    const tree = lowering.tree;
    const ir = &lowering.ir;
    const call = frame.object;
    const name = lowering.child_name(call, 0);
    const proxy = tree.children_of(call)[0];
    // A call's first child is the proxy divert that holds its arguments.
    assert(tree.kind(proxy) == .divert);
    const arguments = tree.children_of(proxy);
    const is_list = !lowering.resolution.targets[call.to_int()].is_none();
    if (is_builtin_call(name) or (is_list and arguments.len == 1)) {
        if (frame.stage == 0 and is_list) _ = try ir.add(container, .{ .text = name });
        if (frame.stage < arguments.len) {
            frame.stage += 1;
            return arguments[frame.stage - 1];
        }
        if (is_list) {
            _ = try ir.add_command(container, .list_from_int);
        } else if (builtin_command(name)) |command| {
            _ = try ir.add_command(container, command);
        } else _ = try ir.add(container, .{ .native = name });
    } else if (is_list) {
        const origins = try ir.arena.allocator().dupe([]const u8, &.{name});
        _ = try ir.add(container, .{ .list = .{ .items = &.{}, .origins = origins } });
    } else try lowering.add_result(container, proxy);
    if (tree.has(call, Flags.pop_result)) _ = try ir.add_command(container, .pop);
    frame.stage = done;
    return null;
}

/// Whether a call is to a built-in (a control command or a native function).
pub fn is_builtin_call(name: []const u8) bool {
    assert(name.len == 0 or name[0] != ' ');
    return builtin_command(name) != null or is_native(name);
}

/// The built-ins that are control commands (their arguments come first).
fn builtin_command(name: []const u8) ?ir_module.Command {
    assert(name.len == 0 or name[0] != '.');
    const names = [_][]const u8{
        "CHOICE_COUNT", "TURNS",       "TURNS_SINCE", "READ_COUNT",
        "RANDOM",       "SEED_RANDOM", "LIST_RANGE",  "LIST_RANDOM",
    };
    const commands = [_]ir_module.Command{
        .choice_count, .turns,       .turns_since, .read_count,
        .random,       .seed_random, .list_range,  .list_random,
    };
    for (names, commands) |builtin, command| {
        if (std.mem.eql(u8, name, builtin)) return command;
    }
    return null;
}

/// Runtime.NativeFunctionCall.CallExistsWithName, for names written as calls.
fn is_native(name: []const u8) bool {
    assert(name.len == 0 or name[0] != '.');
    const names = [_][]const u8{
        "MIN",      "MAX",      "POW",        "FLOOR",      "CEILING",     "INT",      "FLOAT",
        "LIST_MIN", "LIST_MAX", "LIST_COUNT", "LIST_VALUE", "LIST_INVERT", "LIST_ALL",
    };
    for (names) |native| {
        if (std.mem.eql(u8, name, native)) return true;
    }
    return false;
}

/// List.GenerateIntoContainer: each item by its list and value.
fn list_literal(lowering: *Lowering, literal: ObjectIndex) !Item {
    const ast = lowering.ast();
    const node = lowering.tree.node(literal);
    assert(ast.tag(node) == .list_literal);
    const arena = lowering.ir.arena.allocator();
    var items: std.ArrayList(ir_module.ListItem) = .empty;
    for (0..ast.list(node).count) |position| {
        const text = lowering.parsed.leaf_text(ast.item(node, position));
        const dot = std.mem.indexOfScalar(u8, text, '.');
        const list_name: ?[]const u8 = if (dot) |at| text[0..at] else null;
        const item_name = if (dot) |at| text[at + 1 ..] else text;
        const found = find_list_item(lowering, list_name, item_name) orelse continue;
        const origin = lowering.child_name(lowering.tree.parent(found.definition), 0);
        // ink warns about a duplicate item and keeps the first.
        if (contains_item(items.items, origin, item_name)) continue;
        const value = lowering.resolution.item_values[found.element.to_int()];
        try items.append(arena, .{ .origin = origin, .name = item_name, .value = value });
    }
    return .{ .list = .{ .items = items.items, .origins = &.{} } };
}

fn contains_item(items: []const ir_module.ListItem, origin: []const u8, name: []const u8) bool {
    assert(origin.len > 0);
    for (items) |item| {
        if (std.mem.eql(u8, item.origin, origin) and std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

const Found = struct { definition: ObjectIndex, element: ObjectIndex };

/// Story.ResolveListItem (its ambiguity error was reported when resolving).
fn find_list_item(lowering: *const Lowering, list_name: ?[]const u8, item: []const u8) ?Found {
    assert(item.len > 0);
    for (lowering.resolution.lists) |definition| {
        if (list_name) |name| {
            const own = lowering.child_name(lowering.tree.parent(definition), 0);
            if (!std.mem.eql(u8, name, own)) continue;
        }
        for (lowering.tree.children_of(definition)) |element| {
            if (!std.mem.eql(u8, item, lowering.child_name(element, 0))) continue;
            return .{ .definition = definition, .element = element };
        }
    }
    return null;
}

/// ListDefinition.GenerateRuntimeObject: the list's initial value (its selected items).
pub fn list_definition_value(
    lowering: *Lowering,
    definition: ObjectIndex,
    origin: []const u8,
) !Item {
    assert(lowering.tree.kind(definition) == .list_definition);
    assert(origin.len > 0);
    const ast = lowering.ast();
    const arena = lowering.ir.arena.allocator();
    var items: std.ArrayList(ir_module.ListItem) = .empty;
    for (lowering.tree.children_of(definition)) |element| {
        if (ast.tag(lowering.tree.node(element)) != .selected_list_item) continue;
        const name = lowering.child_name(element, 0);
        try items.append(arena, .{
            .origin = origin,
            .name = name,
            .value = lowering.resolution.item_values[element.to_int()],
        });
    }
    const origins = try arena.dupe([]const u8, &.{origin});
    return .{ .list = .{ .items = items.items, .origins = origins } };
}
