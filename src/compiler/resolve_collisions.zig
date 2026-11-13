//! ink's naming checks in ResolveReferences: Story.CheckForNamingCollisions for flows,
//! parameters, labels, variables, constants and lists, FlowBase's duplicate-argument check,
//! and Weave.CheckForWeavePointNamingCollisions.

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const lookups = @import("resolve_passes.zig");
const order = @import("resolve_order.zig");
const sema = @import("sema.zig");
const grammar = @import("grammar.zig");
const Context = resolve.Context;
const Path = resolve.Path;
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;

/// Story.SymbolType, in ink's order (the checks compare them).
pub const Symbol = enum(u8) {
    knot,
    list,
    list_item,
    variable,
    sub_flow_and_weave,
    argument,
    temporary,
};

/// Story.CheckForNamingCollisions for `name` on `object`.
pub fn check(context: *Context, object: ObjectIndex, name: []const u8, symbol: Symbol) !void {
    assert(context.tree.count() > 0);
    assert(object.to_int() < context.tree.count());
    if (name.len == 0) return;
    if (grammar.is_reserved_keyword(name)) return context.report(.reserved_name, object);
    if (order.is_builtin(name)) return context.report(.builtin_name, object);
    const found = try lookups.content_with_name_at_level(context, Tree.root, name, .knot, false);
    if (found) |knot| {
        if (knot != object or symbol == .argument) return context.report(.name_conflict, object);
    }
    if (@backingInt(symbol) < @backingInt(Symbol.list)) return;
    try check_lists(context, object, name);
    if (@backingInt(symbol) <= @backingInt(Symbol.variable)) return;
    if (context.lookup(&context.declarations, Tree.root, name)) |declaration| {
        const tree = context.tree;
        const is_global = tree.has(declaration, Flags.global) and !tree.has(
            declaration,
            Flags.list,
        );
        if (declaration != object and is_global) try context.report(.name_conflict, object);
    }
    if (@backingInt(symbol) < @backingInt(Symbol.sub_flow_and_weave)) return;
    var path: Path = .{ .count = 1 };
    path.components[0] = name;
    if (try lookups.resolve_path(context, &path, object)) |target| {
        if (target != object) return context.report(.name_conflict, object);
    }
    if (@backingInt(symbol) < @backingInt(Symbol.argument) or symbol == .argument) return;
    const flow = context.tree.closest_flow(object);
    for (0..context.parameters(flow).len) |position| {
        if (std.mem.eql(u8, name, context.parameter_name(flow, @intCast(position)))) {
            return context.report(.name_conflict, object);
        }
    }
}

/// The list part: a list's name, and (except for list items) the names of every item.
fn check_lists(context: *Context, object: ObjectIndex, name: []const u8) !void {
    assert(context.tree.count() > 0);
    const tree = context.tree;
    assert(name.len > 0);
    for (context.list_order.items) |definition| {
        const declaration = tree.parent(definition);
        const list_name = context.child_name(declaration, 0);
        const is_own = object == definition or object == declaration;
        if (std.mem.eql(u8, name, list_name) and !is_own) try context.report(
            .name_conflict,
            object,
        );
        if (tree.kind(object) == .list_element) continue;
        for (tree.children_of(definition)) |element| {
            const item = context.child_name(element, 0);
            if (std.mem.eql(u8, name, item)) try context.report(.name_conflict, object);
        }
    }
}

/// A flow's checks: its parameters, duplicate parameters, then its own name.
pub fn check_flow(context: *Context, flow: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.tree.is_flow(flow));
    const count = context.parameters(flow).len;
    for (0..count) |position| {
        try check(context, flow, context.parameter_name(flow, @intCast(position)), .argument);
    }
    for (0..count) |first| {
        for (first + 1..count) |second| {
            const a = context.parameter_name(flow, @intCast(first));
            const b = context.parameter_name(flow, @intCast(second));
            if (std.mem.eql(u8, a, b)) try context.report(.duplicate_argument, flow);
        }
    }
    const level = context.level(flow);
    if (level == .story) return;
    const symbol: Symbol = if (level == .knot) .knot else .sub_flow_and_weave;
    try check(context, flow, context.flow_name(flow), symbol);
}

/// Weave.CheckForWeavePointNamingCollisions: a root weave's labels (in tree order) against
/// the names its enclosing flows (from the story down) can see.
pub fn check_weave(context: *Context, weave: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const tree = context.tree;
    const owner = tree.parent(weave);
    if (!tree.is_flow(owner) or context.root_weaves[owner.to_int()] != weave) return;
    var flows: [3]ObjectIndex = undefined;
    var flows_count: u32 = 0;
    var flow = owner;
    while (!flow.is_none()) : (flow = tree.parent(flow)) {
        assert(flows_count < flows.len);
        flows[flows_count] = flow;
        flows_count += 1;
    }
    var objects = tree.walk(context.gpa, weave, .pre);
    defer objects.deinit();
    while (try objects.next()) |object| {
        try check_label(context, object, weave, flows[0..flows_count]);
    }
}

fn check_label(
    context: *Context,
    object: ObjectIndex,
    weave: ObjectIndex,
    flows: []const ObjectIndex,
) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const kind = context.tree.kind(object);
    if (kind != .choice and kind != .gather) return;
    const name = context.label(object);
    if (name.len == 0) return;
    // Only the label ink kept for the name (the last one).
    if (context.lookup(&context.labels, weave, name) != object) return;
    var position = flows.len;
    while (position > 0) {
        position -= 1;
        const other = try lookups.content_with_name_at_level(
            context,
            flows[position],
            name,
            null,
            false,
        );
        if (other != null and other.? != object) try context.report(.name_conflict, object);
    }
}
