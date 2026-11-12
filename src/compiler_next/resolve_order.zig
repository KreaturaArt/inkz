//! resolve.zig's two passes over the object tree, in ink's order: the generation pass
//! (pre-order, as ink generates runtime objects) and the references pass (ResolveReferences:
//! children first, then the object).

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const lookups = @import("resolve_passes.zig");
const collisions = @import("resolve_collisions.zig");
const sema = @import("sema.zig");
const ast_module = @import("ast.zig");
const Context = resolve.Context;
const Path = resolve.Path;
const Reference = resolve.Reference;
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const NodeIndex = ast_module.NodeIndex;

/// FunctionCall.IsBuiltIn: ink's native functions and its other built-ins.
pub fn is_builtin(name: []const u8) bool {
    assert(name.len == 0 or name[0] != ' ');
    assert(name.len < std.math.maxInt(u32));
    const names = [_][]const u8{
        "+",           "-",            "/",           "*",        "%",          "_",
        "==",          ">",            "<",           ">=",       "<=",         "!=",
        "!",           "&&",           "||",          "MIN",      "MAX",        "POW",
        "FLOOR",       "CEILING",      "INT",         "FLOAT",    "?",          "!?",
        "^",           "LIST_MIN",     "LIST_MAX",    "LIST_ALL", "LIST_COUNT", "LIST_VALUE",
        "LIST_INVERT", "CHOICE_COUNT", "TURNS_SINCE", "TURNS",    "RANDOM",     "SEED_RANDOM",
        "LIST_RANDOM", "READ_COUNT",   "LIST_RANGE",
    };
    for (names) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

/// The name a variable assignment or declaration assigns.
fn assigned_name(context: *const Context, object: ObjectIndex) []const u8 {
    assert(context.tree.count() > 0);
    assert(context.tree.kind(object) == .variable_assignment);
    return context.leaf_text(context.ast().child(context.tree.node(object), 0));
}

/// A divert's target path: the `path` child, or a call's name.
fn divert_path(context: *const Context, divert: ObjectIndex) ?Path {
    assert(context.tree.count() > 0);
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    const node = tree.node(divert);
    if (node.is_none() or tree.has(divert, Flags.empty)) return null;
    const ast = context.ast();
    if (ast.tag(node) == .function_call) {
        var path: Path = .{ .count = 1 };
        path.components[0] = context.leaf_text(ast.child(node, 0));
        return path;
    }
    const path_node = ast.child(node, 0);
    if (ast.tag(path_node) != .path) return null;
    return context.path_of(path_node);
}

fn is_end_or_done(path: *const Path) bool {
    assert(path.count == 0 or path.components[0].len < std.math.maxInt(u32));
    assert(path.count <= resolve.path_components_max);
    return path.is_single("END") or path.is_single("DONE");
}

// The generation pass.

pub fn generation_pass(context: *Context) !void {
    assert(context.tree.count() > 0);
    const gpa = context.gpa;
    var stack: std.ArrayList(ObjectIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, Tree.root);
    while (stack.pop()) |object| {
        try generate(context, object);
        const children = context.tree.children_of(object);
        var position = children.len;
        while (position > 0) {
            position -= 1;
            try stack.append(gpa, children[position]);
        }
    }
    assert(stack.items.len == 0);
}

fn generate(context: *Context, object: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const tree = context.tree;
    switch (tree.kind(object)) {
        .variable_assignment => {
            const scope = if (tree.has(object, Flags.global))
                Tree.root
            else if (tree.has(object, Flags.new_temporary))
                tree.closest_flow(object)
            else
                return;
            try declare(
                context,
                &context.declarations,
                scope,
                assigned_name(context, object),
                object,
            );
        },
        .external_declaration => {
            const name = context.leaf_text(context.ast().child(tree.node(object), 0));
            const entry = try context.externals.getOrPut(context.gpa, .{
                .scope = Tree.root,
                .name = name,
            });
            if (entry.found_existing) return context.report(.duplicate_external, object);
            entry.value_ptr.* = object;
        },
        .function_call => {
            const name = context.leaf_text(context.ast().child(tree.node(object), 0));
            const is_list = context.lookup(&context.lists, Tree.root, name) != null;
            // A built-in's proxy divert is never generated, so never resolved.
            const proxy = tree.children_of(object)[0];
            if (is_builtin(name) or is_list) context.skipped.set(proxy.to_int());
        },
        .divert => try generate_divert(context, object),
        else => {},
    }
}

/// FlowBase.TryAddNewVariableDeclaration.
fn declare(
    context: *Context,
    table: *resolve.Table,
    scope: ObjectIndex,
    name: []const u8,
    object: ObjectIndex,
) !void {
    assert(context.tree.count() > 0);
    assert(name.len < std.math.maxInt(u32));
    const entry = try table.getOrPut(context.gpa, .{ .scope = scope, .name = name });
    if (entry.found_existing) return context.report(.duplicate_declaration, object);
    entry.value_ptr.* = object;
}

/// Divert.ResolveTargetContent: a variable target, or ink's path lookup.
fn generate_divert(context: *Context, divert: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    if (context.skipped.isSet(divert.to_int())) return;
    const path = divert_path(context, divert) orelse return;
    if (is_end_or_done(&path)) return;
    if (lookups.resolve_variable(context, path.first(), divert) != null) {
        context.variable_diverts.set(divert.to_int());
        return;
    }
    const target = try lookups.resolve_path(context, &path, divert);
    context.targets[divert.to_int()] = target orelse .none;
}

// The references pass.

pub fn references_pass(context: *Context) !void {
    assert(context.tree.count() > 0);
    const gpa = context.gpa;
    const Entry = struct { object: ObjectIndex, visited: bool };
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .object = Tree.root, .visited = false });
    while (stack.pop()) |entry| {
        if (entry.visited) {
            try check(context, entry.object);
            continue;
        }
        try stack.append(gpa, .{ .object = entry.object, .visited = true });
        const children = context.tree.children_of(entry.object);
        var position = children.len;
        while (position > 0) {
            position -= 1;
            try stack.append(gpa, .{ .object = children[position], .visited = false });
        }
    }
    assert(stack.items.len == 0);
}

fn check(context: *Context, object: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    switch (context.tree.kind(object)) {
        .divert => try check_divert(context, object),
        .variable_reference => try check_variable_reference(context, object),
        .variable_assignment => try check_assignment(context, object),
        .increment => try check_increment(context, object),
        .story, .knot, .stitch => try collisions.check_flow(context, object),
        .weave => try collisions.check_weave(context, object),
        .choice, .gather => {
            try collisions.check(context, object, context.label(object), .sub_flow_and_weave);
        },
        .constant_declaration, .list_element => {
            const name = context.leaf_text(context.ast().child(context.tree.node(object), 0));
            const kind = context.tree.kind(object);
            try collisions.check(
                context,
                object,
                name,
                if (kind == .list_element) .list_item else .variable,
            );
        },
        .list_definition => {
            const declaration = context.tree.node(context.tree.parent(object));
            try collisions.check(
                context,
                object,
                context.leaf_text(context.ast().child(declaration, 0)),
                .list,
            );
        },
        else => {},
    }
    assert(object.to_int() < context.tree.count());
}

/// Divert.ResolveReferences.
fn check_divert(context: *Context, divert: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const tree = context.tree;
    if (context.skipped.isSet(divert.to_int())) return;
    const path = divert_path(context, divert) orelse return;
    if (is_end_or_done(&path)) return;
    const is_call = tree.has(divert, Flags.function_call);
    const target = context.targets[divert.to_int()];
    if (!target.is_none() and tree.is_flow(target)) {
        const is_function = tree.has(target, Flags.function);
        const in_divert_target = tree.kind(tree.parent(divert)) == .divert_target;
        if (!is_function and is_call) try context.report(.not_a_function, divert);
        if (is_function and !is_call and !in_divert_target) try context.report(
            .function_diverted_to,
            divert,
        );
    }
    if (path.count == 1) {
        const name = path.first();
        const is_external = context.lookup(&context.externals, Tree.root, name) != null;
        if (is_builtin(name) or is_external) {
            if (!is_call) try context.report(.builtin_not_called, divert);
            return;
        }
    }
    if (context.variable_diverts.isSet(divert.to_int())) return;
    if (target.is_none()) try context.report(.target_not_found, divert);
}

/// VariableReference: a constant, a list item, a read count, or a variable.
fn check_variable_reference(context: *Context, reference: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const node = context.tree.node(reference);
    const path = context.path_of(context.ast().child(node, 0));
    assert(path.count > 0);
    const references = context.references;
    if (path.count == 1 and context.lookup(&context.constants, Tree.root, path.first()) != null) {
        references[reference.to_int()] = .constant;
        return;
    }
    if (path.count <= 2) {
        const list_name: ?[]const u8 = if (path.count == 2) path.components[0] else null;
        const item = path.components[path.count - 1];
        if (try lookups.resolve_list_item(context, list_name, item, reference) != null) {
            references[reference.to_int()] = .list_item;
            return;
        }
    }
    if (try lookups.resolve_path(context, &path, reference)) |target| {
        references[reference.to_int()] = .read_count;
        context.targets[reference.to_int()] = target;
        return;
    }
    if (path.count > 1) {
        references[reference.to_int()] = .unresolved;
        return context.report(.read_count_target_not_found, reference);
    }
    const found = lookups.resolve_variable(context, path.first(), reference);
    references[reference.to_int()] = found orelse .unresolved;
    if (found == null) try context.report(.unresolved_variable, reference);
}

/// VariableAssignment.ResolveReferences.
fn check_assignment(context: *Context, assignment: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const tree = context.tree;
    const references = context.references;
    const is_global = tree.has(assignment, Flags.global);
    const declares = is_global or tree.has(assignment, Flags.new_temporary);
    if (declares and !tree.has(assignment, Flags.list)) {
        const symbol: collisions.Symbol = if (is_global) .variable else .temporary;
        try collisions.check(context, assignment, assigned_name(context, assignment), symbol);
    }
    if (is_global) {
        references[assignment.to_int()] = .global;
        const children = tree.children_of(assignment);
        if (children.len == 1 and tree.kind(children[0]) == .variable_reference) {
            const value = references[children[0].to_int()];
            if (value != .constant and value != .list_item) {
                try context.report(.global_refers_to_variable, assignment);
            }
        }
        return;
    }
    if (tree.has(assignment, Flags.new_temporary)) {
        references[assignment.to_int()] = .temporary;
        return;
    }
    const name = assigned_name(context, assignment);
    const found = lookups.resolve_variable(context, name, assignment);
    references[assignment.to_int()] = found orelse .unresolved;
    if (found != null) return;
    const constant = context.lookup(&context.constants, Tree.root, name) != null;
    try context.report(
        if (constant) .assignment_to_constant else .assignment_target_not_found,
        assignment,
    );
}

/// IncDecExpression.ResolveReferences.
fn check_increment(context: *Context, increment: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    assert(context.targets.len == 0 or context.targets.len == context.tree.count());
    const tree = context.tree;
    const ast = context.ast();
    const node = tree.node(increment);
    const name = if (tree.has(increment, Flags.by_expression))
        context.leaf_text(ast.child(node, 0))
    else
        joined_first(context, ast.child(ast.child(node, 0), 0));
    const found = lookups.resolve_variable(context, name, increment);
    context.references[increment.to_int()] = found orelse .unresolved;
    if (found == null) try context.report(.increment_target_not_found, increment);
}

/// A variable reference's name: ink joins the path with dots; only a one-component path
/// can name a variable.
fn joined_first(context: *const Context, path_node: NodeIndex) []const u8 {
    assert(context.tree.count() > 0);
    const path = context.path_of(path_node);
    assert(path.count > 0);
    if (path.count > 1) return "";
    return path.first();
}
