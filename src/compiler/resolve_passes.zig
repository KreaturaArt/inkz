//! resolve.zig's two passes over the object tree, in ink's order: the generation pass
//! (pre-order, as ink generates runtime objects) and the references pass (ResolveReferences:
//! children first, then the object).

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const lookups = @import("resolve_lookups.zig");
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
    return context.child_name(object, 0);
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
        path.components[0] = context.parsed.child_text(node, 0);
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
    var objects = context.tree.walk(context.gpa, Tree.root, .pre);
    defer objects.deinit();
    while (try objects.next()) |object| try generate(context, object);
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
            const name = context.child_name(object, 0);
            const entry = try context.externals.getOrPut(context.gpa, .{
                .scope = Tree.root,
                .name = name,
            });
            if (entry.found_existing) return context.report(.duplicate_external, object);
            entry.value_ptr.* = object;
        },
        .function_call => {
            const name = context.child_name(object, 0);
            const is_list = context.lookup(&context.lists, Tree.root, name) != null;
            // A built-in's proxy divert is never generated, so never resolved.
            const proxy = tree.children_of(object)[0];
            if (is_builtin(name) or is_list) context.skipped.set(proxy.to_int());
        },
        .divert => try generate_divert(context, object),
        .knot, .stitch => try check_flow(context, object),
        else => {},
    }
}

/// FlowBase.GenerateRuntimeObject's checks: a function's CheckForDisallowedFunctionFlowControl
/// (no stitches, diverts or choices), and a knot's or stitch's first `return` otherwise.
fn check_flow(context: *Context, flow: ObjectIndex) !void {
    assert(context.tree.is_flow(flow));
    assert(context.tree.kind(flow) != .story);
    const tree = context.tree;
    if (!tree.has(flow, Flags.function)) {
        const found = try tree.find(context.gpa, flow, Tree.is_return) orelse return;
        return context.report(.return_outside_function, found);
    }
    if (tree.kind(flow) == .stitch) try context.report(.function_is_stitch, flow);
    const children = tree.children_of(flow);
    for (children) |child| {
        if (tree.is_flow(child)) try context.report(.function_has_stitch, child);
    }
    // A flow's root weave is its first child; a function without one has nothing more.
    if (children.len == 0 or tree.kind(children[0]) != .weave) return;
    var found: std.ArrayList(ObjectIndex) = .empty;
    defer found.deinit(context.gpa);
    try tree.find_all(context.gpa, children[0], is_disallowed_divert, &found);
    for (found.items) |divert| try context.report(.function_has_divert, divert);
    found.clearRetainingCapacity();
    try tree.find_all(context.gpa, children[0], Tree.is_choice, &found);
    for (found.items) |choice| try context.report(.function_has_choice, choice);
}

/// A divert a function may not contain: not a function call's, not a divert target's.
fn is_disallowed_divert(tree: *const Tree, object: ObjectIndex) bool {
    assert(object.to_int() < tree.count());
    assert(tree.count() > 0);
    if (tree.kind(object) != .divert or tree.has(object, Flags.function_call)) return false;
    return tree.kind(tree.parent(object)) != .divert_target;
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
    var objects = context.tree.walk(context.gpa, Tree.root, .post);
    defer objects.deinit();
    while (try objects.next()) |object| try check(context, object);
}

fn check(context: *Context, object: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    switch (context.tree.kind(object)) {
        .divert => try check_divert(context, object),
        .variable_reference => try check_variable_reference(context, object),
        .list_literal => try check_list_literal(context, object),
        .function_call => {
            // A list's name called as a function makes a list (ink's ResolveList).
            const name = context.child_name(object, 0);
            const list = context.lookup(&context.lists, Tree.root, name);
            context.targets[object.to_int()] = list orelse .none;
        },
        .variable_assignment => try check_assignment(context, object),
        .increment => try check_increment(context, object),
        .story, .knot, .stitch => try collisions.check_flow(context, object),
        .weave => try collisions.check_weave(context, object),
        .choice, .gather => {
            try collisions.check(context, object, context.label(object), .sub_flow_and_weave);
        },
        .constant_declaration, .list_element => {
            const name = context.child_name(object, 0);
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
                context.parsed.child_text(declaration, 0),
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
    if (path.count == 1) {
        if (context.lookup(&context.constants, Tree.root, path.first())) |constant| {
            references[reference.to_int()] = .constant;
            context.targets[reference.to_int()] = constant;
            return;
        }
    }
    if (path.count <= 2) {
        const list_name: ?[]const u8 = if (path.count == 2) path.components[0] else null;
        const item = path.components[path.count - 1];
        if (try lookups.resolve_list_item(context, list_name, item, reference)) |element| {
            references[reference.to_int()] = .list_item;
            context.targets[reference.to_int()] = element;
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

/// List.GenerateIntoContainer's lookups: each item of a list literal must exist.
fn check_list_literal(context: *Context, literal: ObjectIndex) !void {
    assert(context.tree.count() > 0);
    const ast = context.ast();
    const node = context.tree.node(literal);
    for (0..ast.list(node).count) |position| {
        const text = context.parsed.leaf_text(ast.item(node, position));
        const dot = std.mem.indexOfScalar(u8, text, '.');
        const list_name: ?[]const u8 = if (dot) |at| text[0..at] else null;
        const item = if (dot) |at| text[at + 1 ..] else text;
        if (try lookups.resolve_list_item(context, list_name, item, literal) == null) {
            try context.report(.list_item_not_found, literal);
        }
    }
    assert(context.tree.kind(literal) == .list_literal);
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
        context.parsed.child_text(node, 0)
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
