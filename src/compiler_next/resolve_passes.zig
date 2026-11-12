//! The passes of resolve.zig, and ink's lookups: Path.ResolveFromContext,
//! FlowBase.ContentWithNameAtLevel (with its deep search), FlowBase.ResolveVariableWithName
//! and Story.ResolveListItem, all without recursion.

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const sema = @import("sema.zig");
const ast_module = @import("ast.zig");
const Context = resolve.Context;
const Path = resolve.Path;
const FlowLevel = resolve.FlowLevel;
const Reference = resolve.Reference;
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const NodeIndex = ast_module.NodeIndex;

// Preparation: ink's ExportRuntime prelude and ResolveWeavePointNaming.

pub fn prepare(context: *Context) !void {
    assert(context.tree.count() > 0);
    const gpa = context.gpa;
    const count = context.tree.count();
    context.targets = try gpa.alloc(ObjectIndex, count);
    @memset(context.targets, .none);
    context.references = try gpa.alloc(Reference, count);
    @memset(context.references, .none);
    context.root_weaves = try gpa.alloc(ObjectIndex, count);
    @memset(context.root_weaves, .none);
    context.variable_diverts = try .initEmpty(gpa, count);
    context.skipped = try .initEmpty(gpa, count);
    context.had_error = try .initEmpty(gpa, count);
    // ink's FindAll order: pre-order (objects are numbered breadth-first).
    var stack: std.ArrayList(ObjectIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, Tree.root);
    while (stack.pop()) |object| {
        try prepare_object(context, object);
        try push_reversed(context, &stack, object);
    }
    assert(context.targets.len == count);
}

fn prepare_object(context: *Context, object: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const tree = context.tree;
    switch (tree.kind(object)) {
        .story, .knot, .stitch => {
            for (tree.children_of(object)) |child| {
                if (tree.kind(child) == .weave) {
                    context.root_weaves[object.to_int()] = child;
                    try name_weave_points(context, child);
                } else if (tree.is_flow(child)) {
                    const name = context.flow_name(child);
                    try context.subflows.put(
                        context.gpa,
                        .{ .scope = object, .name = name },
                        child,
                    );
                }
            }
        },
        .constant_declaration => {
            const name = context.leaf_text(context.ast().child(tree.node(object), 0));
            try context.constants.put(context.gpa, .{ .scope = Tree.root, .name = name }, object);
        },
        .list_definition => {
            // The name is the LIST declaration's.
            const declaration = tree.node(tree.parent(object));
            const name = context.leaf_text(context.ast().child(declaration, 0));
            try context.lists.put(context.gpa, .{ .scope = Tree.root, .name = name }, object);
            try context.list_order.append(context.gpa, object);
        },
        else => {},
    }
    assert(object.to_int() < tree.count());
}

/// Weave.ResolveWeavePointNaming: every labelled choice and gather under a root weave.
fn name_weave_points(context: *Context, weave: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const gpa = context.gpa;
    var stack: std.ArrayList(ObjectIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, weave);
    while (stack.pop()) |object| {
        const kind = context.tree.kind(object);
        if (kind == .choice or kind == .gather) {
            const name = context.label(object);
            if (name.len > 0) {
                const entry = try context.labels.getOrPut(gpa, .{ .scope = weave, .name = name });
                if (entry.found_existing) try context.report(.duplicate_label, object);
                entry.value_ptr.* = object;
            }
        }
        try push_reversed(context, &stack, object);
    }
    assert(stack.items.len == 0);
}

/// Pushes an object's children so that they pop in order (pre-order traversal).
fn push_reversed(context: *Context, stack: *std.ArrayList(ObjectIndex), object: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const children = context.tree.children_of(object);
    var position = children.len;
    while (position > 0) {
        position -= 1;
        try stack.append(context.gpa, children[position]);
    }
    assert(stack.items.len >= children.len);
}

// ink's lookups.

/// FlowBase.ContentWithNameAtLevel.
pub fn content_with_name_at_level(
    context: *Context,
    flow: ObjectIndex,
    name: []const u8,
    level: ?FlowLevel,
    deep: bool,
) !?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const own = context.level(flow);
    if ((level == null or level.? == own) and own != .story) {
        if (std.mem.eql(u8, name, context.flow_name(flow))) return flow;
    }
    if (level == null or level.? == .weave_point) {
        if (weave_point_named(context, flow, name)) |point| return point;
        if (level != null) return if (deep) try deep_search(context, flow, name) else null;
    }
    if (level != null and @backingInt(level.?) < @backingInt(own)) return null;
    if (context.lookup(&context.subflows, flow, name)) |sub_flow| {
        if (level == null or level.? == context.level(sub_flow)) return sub_flow;
    }
    return if (deep) try deep_search(context, flow, name) else null;
}

fn weave_point_named(context: *const Context, flow: ObjectIndex, name: []const u8) ?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.tree.is_flow(flow));
    const weave = context.root_weaves[flow.to_int()];
    if (weave.is_none()) return null;
    return context.lookup(&context.labels, weave, name);
}

/// DeepSearchForAnyLevelContent: the flow's labels, then each sub-flow (its name, labels and
/// sub-flows, then deeper), depth first.
fn deep_search(context: *Context, flow: ObjectIndex, name: []const u8) !?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    if (weave_point_named(context, flow, name)) |point| return point;
    const gpa = context.gpa;
    var stack: std.ArrayList(ObjectIndex) = .empty;
    defer stack.deinit(gpa);
    try push_sub_flows(context, &stack, flow);
    while (stack.pop()) |sub_flow| {
        if (std.mem.eql(u8, name, context.flow_name(sub_flow))) return sub_flow;
        if (weave_point_named(context, sub_flow, name)) |point| return point;
        if (context.lookup(&context.subflows, sub_flow, name)) |found| return found;
        try push_sub_flows(context, &stack, sub_flow);
    }
    return null;
}

fn push_sub_flows(context: *Context, stack: *std.ArrayList(ObjectIndex), flow: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const children = context.tree.children_of(flow);
    var position = children.len;
    while (position > 0) {
        position -= 1;
        const child = children[position];
        if (context.tree.is_flow(child)) try stack.append(context.gpa, child);
    }
    assert(context.tree.is_flow(flow));
}

/// Path.TryGetChildFromContext.
fn child_from_context(
    context: *Context,
    scope: ObjectIndex,
    name: []const u8,
    minimum: ?FlowLevel,
    force_deep: bool,
) !?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const tree = context.tree;
    if (tree.kind(scope) == .weave and (minimum == null or minimum.? == .weave_point)) {
        // Only a flow's root weave has its labels named.
        const owner = tree.parent(scope);
        if (!tree.is_flow(owner) or context.root_weaves[owner.to_int()] != scope) return null;
        return context.lookup(&context.labels, scope, name);
    }
    if (tree.is_flow(scope)) {
        const deep = force_deep or context.level(scope) == .knot;
        return content_with_name_at_level(context, scope, name, minimum, deep);
    }
    return null;
}

/// Path.ResolveFromContext.
pub fn resolve_path(context: *Context, path: *const Path, from: ObjectIndex) !?ObjectIndex {
    assert(context.tree.count() > 0);
    if (path.count == 0) return null;
    var ancestor = from;
    var base: ?ObjectIndex = null;
    var steps: u32 = 0;
    while (!ancestor.is_none()) : (steps += 1) {
        assert(steps < context.tree.count());
        base = try child_from_context(context, ancestor, path.first(), null, ancestor == from);
        if (base != null) break;
        ancestor = context.tree.parent(ancestor);
    }
    var found = base orelse return null;
    for (path.components[1..path.count]) |component| {
        const minimum: FlowLevel = if (context.tree.is_flow(found))
            @fromBackingInt(@intCast(@backingInt(context.level(found)) + 1))
        else
            .weave_point;
        const next = try child_from_context(context, found, component, minimum, false);
        found = next orelse return null;
    }
    return found;
}

/// FlowBase.ResolveVariableWithName, with the declarations registered so far.
pub fn resolve_variable(context: *const Context, name: []const u8, from: ObjectIndex) ?Reference {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const owner = context.tree.closest_flow(from);
    const parameters = context.parameters(owner);
    for (0..parameters.len) |position| {
        const parameter = context.parameter_name(owner, @intCast(position));
        if (std.mem.eql(u8, name, parameter)) return .argument;
    }
    if (owner != Tree.root and context.lookup(&context.declarations, owner, name) != null) {
        return .temporary;
    }
    if (context.lookup(&context.declarations, Tree.root, name) != null) return .global;
    return null;
}

/// Story.ResolveListItem: `list.item`, or an item of any list (ambiguity is an error).
pub fn resolve_list_item(
    context: *Context,
    list_name: ?[]const u8,
    item: []const u8,
    from: ObjectIndex,
) !?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    if (list_name) |name| {
        const definition = context.lookup(&context.lists, Tree.root, name) orelse return null;
        return list_item_named(context, definition, item);
    }
    var found: ?ObjectIndex = null;
    for (context.list_order.items) |definition| {
        if (list_item_named(context, definition, item)) |element| {
            if (found != null) {
                try context.report(.ambiguous_list_item, from);
            } else found = element;
        }
    }
    return found;
}

fn list_item_named(
    context: *const Context,
    definition: ObjectIndex,
    item: []const u8,
) ?ObjectIndex {
    assert(context.tree.count() > 0);
    assert(context.tree.kind(definition) == .list_definition);
    for (context.tree.children_of(definition)) |element| {
        const name = context.leaf_text(context.ast().child(context.tree.node(element), 0));
        if (std.mem.eql(u8, name, item)) return element;
    }
    return null;
}

// The two passes are in resolve_order.zig, which uses these lookups.
pub const generation_pass = @import("resolve_order.zig").generation_pass;
pub const references_pass = @import("resolve_order.zig").references_pass;
