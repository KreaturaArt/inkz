//! resolve.zig's two passes over the object tree, in ink's order: the generation pass
//! (pre-order, as ink generates runtime objects) and the references pass (ResolveReferences:
//! children first, then the object).

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const lookups = @import("resolve_lookups.zig");
const collisions = @import("resolve_collisions.zig");
const argument_checks = @import("resolve_arguments.zig");
const sema = @import("sema.zig");
const values = @import("values.zig");
const ast_module = @import("ast.zig");
const ir = @import("lower_ir.zig");
const Context = resolve.Context;
const Path = resolve.Path;
const Reference = resolve.Reference;
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const NodeIndex = ast_module.NodeIndex;

/// FunctionCall.IsBuiltIn for names: the built-ins, and `_` (ink's negation, which
/// lowering generates as an ordinary call).
pub fn is_builtin(name: []const u8) bool {
    return ir.builtin(name) != null or std.mem.eql(u8, name, "_");
}

/// The name a variable assignment or declaration assigns.
fn assigned_name(context: *const Context, object: ObjectIndex) []const u8 {
    assert(context.tree.kind(object) == .variable_assignment);
    return context.slot_name(object, .name);
}

/// A divert's target path: the `path` child, or a call's name.
fn divert_path(context: *const Context, divert: ObjectIndex) ?Path {
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    const node = tree.node(divert);
    if (node.is_none() or tree.has(divert, Flags.empty)) return null;
    const ast = context.ast();
    if (ast.tag(node) == .function_call) {
        var path: Path = .{ .count = 1 };
        path.components[0] = context.parsed.slot_text(node, .name);
        return path;
    }
    const path_node = ast.slot(node, .path);
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
    // Declarations are registered by this pass alone, once.
    assert(context.declarations.count() == 0);
    var objects = context.tree.walk(context.gpa, Tree.root, .pre);
    defer objects.deinit();
    while (try objects.next()) |object| try generate(context, object);
}

fn generate(context: *Context, object: ObjectIndex) !void {
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
            const name = context.slot_name(object, .name);
            const entry = try context.externals.getOrPut(context.gpa, .{
                .scope = Tree.root,
                .name = name,
            });
            if (entry.found_existing) return context.report(.duplicate_external, object);
            entry.value_ptr.* = object;
        },
        .function_call => {
            const name = context.slot_name(object, .name);
            const is_list = context.lookup(&context.lists, Tree.root, name) != null;
            // A built-in's proxy divert is never generated, so never resolved.
            assert(tree.children_of(object).len > 0);
            const proxy = tree.children_of(object)[0];
            assert(tree.kind(proxy) == .divert);
            if (is_builtin(name) or is_list) {
                context.skipped.set(proxy.to_int());
                try argument_checks.check_call(context, object, is_list);
            }
        },
        .divert => try generate_divert(context, object),
        .knot, .stitch => {
            try check_flow(context, object);
            try check_duplicate_flow(context, object);
        },
        else => {},
    }
}

/// FlowBase.GenerateRuntimeObject's named content: a flow named like an earlier sibling.
fn check_duplicate_flow(context: *Context, flow: ObjectIndex) !void {
    const tree = context.tree;
    assert(tree.is_flow(flow));
    const name = context.flow_name(flow);
    for (tree.children_of(tree.parent(flow))) |sibling| {
        if (sibling == flow) return;
        if (!tree.is_flow(sibling)) continue;
        if (std.mem.eql(u8, name, context.flow_name(sibling))) {
            return context.report_with(.duplicate_flow, flow, sibling);
        }
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
        return context.report_with(.return_outside_function, found, flow);
    }
    if (tree.kind(flow) == .stitch) try context.report(.function_is_stitch, flow);
    const children = tree.children_of(flow);
    for (children) |child| {
        if (tree.is_flow(child)) try context.report_with(.function_has_stitch, child, flow);
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
    assert(context.tree.is_flow(scope));
    const entry = try table.getOrPut(context.gpa, .{ .scope = scope, .name = name });
    if (entry.found_existing) {
        return context.report_with(.duplicate_declaration, object, entry.value_ptr.*);
    }
    entry.value_ptr.* = object;
}

/// Divert.ResolveTargetContent: a variable target, or ink's path lookup.
fn generate_divert(context: *Context, divert: ObjectIndex) !void {
    // Each divert is generated once.
    assert(context.targets[divert.to_int()].is_none());
    if (context.skipped.isSet(divert.to_int())) return;
    const path = divert_path(context, divert) orelse return;
    if (is_end_or_done(&path)) return;
    if (lookups.resolve_variable(context, path.first(), divert)) |found| {
        if (found == .argument) {
            try argument_checks.check_divert_parameter(context, divert, path.first());
        }
        context.variable_diverts.set(divert.to_int());
        return;
    }
    const target = try lookups.resolve_path(context, &path, divert);
    context.targets[divert.to_int()] = target orelse .none;
    try argument_checks.check_divert(context, divert);
}

// The references pass.

pub fn references_pass(context: *Context) !void {
    var objects = context.tree.walk(context.gpa, Tree.root, .post);
    defer objects.deinit();
    while (try objects.next()) |object| try check(context, object);
}

/// ink's `not A ? B` check: a negated left operand of `?` (or `has`). ink's parser folds
/// `not` of a number or bool literal into a Number (WithInner), so that one isn't negated.
fn negates_has_operand(context: *const Context, object: ObjectIndex) bool {
    assert(context.tree.kind(object) == .binary);
    const ast = context.ast();
    const node = context.tree.node(object);
    if (ast.tag(node) != .has or ast.tag(ast.slot(node, .left)) != .not) return false;
    const left = context.tree.children_of(object)[0];
    assert(context.tree.kind(left) == .unary);
    // A fold ink throws on (`not -true`) is reported where the expression is generated.
    const folded = values.literal(context.parsed, context.tree, left) catch return false;
    return folded == null;
}

fn check(context: *Context, object: ObjectIndex) !void {
    switch (context.tree.kind(object)) {
        .divert => try check_divert(context, object),
        .variable_reference => try check_variable_reference(context, object),
        .list_literal => try check_list_literal(context, object),
        .binary => if (negates_has_operand(context, object)) {
            try context.report(.negated_has_operand, object);
        },
        .function_call => {
            // A list's name called as a function makes a list (ink's ResolveList).
            const name = context.slot_name(object, .name);
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
            const name = context.slot_name(object, .name);
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
                context.parsed.slot_text(declaration, .name),
                .list,
            );
        },
        else => {},
    }
    assert(object.to_int() < context.tree.count());
}

/// Whether an object is one of ink's Expressions (the usage walk climbs through those).
fn is_expression(kind: sema.Kind) bool {
    return switch (kind) {
        .binary, .unary, .number, .string_expression, .variable_reference => true,
        .function_call, .divert_target, .list_literal, .multiple_condition, .increment => true,
        else => false,
    };
}

/// DivertTarget.ResolveReferences' usage check: from the value up through the expressions
/// around it, the first user decides. `==` and `!=` between divert targets or variables,
/// TURNS_SINCE and READ_COUNT are fine; any other expression, a choice's condition or a
/// conditional is ink's "Can't use a divert target like that".
fn check_divert_target_usage(context: *Context, target: ObjectIndex) !void {
    const tree = context.tree;
    const ast = context.ast();
    var usage = target;
    while (is_expression(tree.kind(usage))) {
        // A call's arguments are its proxy divert's, as in ink: the walk stops there.
        const parent = tree.parent(usage);
        if (parent.is_none()) return;
        const kind = tree.kind(parent);
        const verdict: enum { fine, bad, climb } = switch (kind) {
            .binary => binary: {
                const tag = ast.tag(tree.node(parent));
                if (tag != .equal and tag != .not_equal) break :binary .bad;
                for (tree.children_of(parent)) |operand| {
                    const operand_kind = tree.kind(operand);
                    if (operand_kind != .divert_target and operand_kind != .variable_reference) {
                        break :binary .bad;
                    }
                }
                break :binary .fine;
            },
            .function_call => call: {
                const name = context.slot_name(parent, .name);
                const counts = std.mem.eql(u8, name, "TURNS_SINCE") or
                    std.mem.eql(u8, name, "READ_COUNT");
                break :call if (counts) .fine else .bad;
            },
            .choice => choice: {
                const condition = ast.slot(tree.node(parent), .condition);
                break :choice if (tree.node(usage) == condition) .bad else .climb;
            },
            .conditional, .conditional_branch => .bad,
            else => if (is_expression(kind)) .bad else .climb,
        };
        switch (verdict) {
            .fine => return,
            .bad => return context.report(.divert_target_misused, target),
            .climb => usage = parent,
        }
    }
}

/// Divert.ResolveReferences, then (ink resolves children first) the checks of the
/// divert-target value and the TURNS_SINCE or READ_COUNT call around it.
fn check_divert(context: *Context, divert: ObjectIndex) !void {
    const tree = context.tree;
    if (context.skipped.isSet(divert.to_int())) return;
    const path = divert_path(context, divert) orelse return;
    try check_divert_itself(context, divert, &path);
    const parent = tree.parent(divert);
    if (tree.kind(parent) != .divert_target) return;
    try check_target_value(context, parent, divert, &path);
    const call = counting_call(context, parent) orelse return;
    if (context.variable_diverts.isSet(divert.to_int())) {
        try context.report(.turns_since_variable_target, call);
    } else if (!is_end_or_done(&path) and context.targets[divert.to_int()].is_none()) {
        try context.report_with(.turns_since_target_not_found, call, divert);
    }
}

/// The TURNS_SINCE or READ_COUNT call whose argument `argument` is: its proxy divert (a
/// call is a divert flagged as one), or null. ink counts both targets alike
/// (`_divertTargetToCount`, `_variableReferenceToCount`).
fn counting_call(context: *const Context, argument: ObjectIndex) ?ObjectIndex {
    const tree = context.tree;
    const call = tree.parent(argument);
    if (call.is_none()) return null;
    if (tree.kind(call) != .divert or !tree.has(call, Flags.function_call)) return null;
    const call_path = divert_path(context, call) orelse return null;
    if (call_path.count != 1) return null;
    const name = call_path.first();
    const counts = std.mem.eql(u8, name, "TURNS_SINCE") or std.mem.eql(u8, name, "READ_COUNT");
    return if (counts) call else null;
}

/// DivertTarget.ResolveReferences, on the value `target` around `divert`: DONE and END
/// first, then the usage, a variable's name, and a flow with `ref` parameters. Each is an
/// error on the value, which keeps one.
fn check_target_value(
    context: *Context,
    target: ObjectIndex,
    divert: ObjectIndex,
    path: *const Path,
) !void {
    assert(context.tree.kind(target) == .divert_target);
    // DONE and END are instructions, not content a divert-target value can point at.
    if (is_end_or_done(path)) return context.report(.done_or_end_as_value, target);
    try check_divert_target_usage(context, target);
    if (context.variable_diverts.isSet(divert.to_int())) {
        try context.report(.variable_divert_target, target);
    }
    // A stored divert target can't know to pass a variable by reference (ink issue 538).
    const flow = context.targets[divert.to_int()];
    if (flow.is_none() or !context.tree.is_flow(flow)) return;
    for (context.parameters(flow), 0..) |parameter, position| {
        if (parameter != .reference_parameter) continue;
        try context.report_details(.divert_target_to_reference_flow, target, .{
            .other = flow,
            .name = context.parameter_name(flow, @intCast(position)),
        });
    }
}

/// Divert.ResolveReferences' own checks.
fn check_divert_itself(context: *Context, divert: ObjectIndex, path: *const Path) !void {
    const tree = context.tree;
    if (is_end_or_done(path)) {
        // A tunnel can't return onwards to DONE or END: there is no container to return to.
        if (tree.kind(tree.parent(divert)) == .tunnel_onwards) {
            try context.report(.tunnel_onwards_to_end_or_done, divert);
        }
        return;
    }
    const is_call = tree.has(divert, Flags.function_call);
    const target = context.targets[divert.to_int()];
    // The generation pass gave the divert a variable target or a path target, not both.
    if (!target.is_none()) assert(!context.variable_diverts.isSet(divert.to_int()));
    if (!target.is_none() and tree.is_flow(target)) {
        const is_function = tree.has(target, Flags.function);
        const in_divert_target = tree.kind(tree.parent(divert)) == .divert_target;
        if (!is_function and is_call) try context.report_with(.not_a_function, divert, target);
        if (is_function and !is_call and !in_divert_target) try context.report_with(
            .function_diverted_to,
            divert,
            target,
        );
    }
    if (path.count == 1) {
        const name = path.first();
        const external = context.lookup(&context.externals, Tree.root, name);
        if (is_builtin(name) or external != null) {
            if (!is_call) try context.report(.builtin_not_called, divert);
            if (external) |declaration| {
                try argument_checks.check_external(context, divert, declaration);
            }
            return;
        }
    }
    // A variable divert's checks are its divert-target value's (check_target_value).
    if (context.variable_diverts.isSet(divert.to_int())) return;
    if (target.is_none()) try context.report(.target_not_found, divert);
}

/// VariableReference: a constant, a list item, a read count, or a variable.
fn check_variable_reference(context: *Context, reference: ObjectIndex) !void {
    assert(context.tree.kind(reference) == .variable_reference);
    const node = context.tree.node(reference);
    const path = context.path_of(context.ast().slot(node, .path));
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
        // TURNS_SINCE(k) and READ_COUNT(k) count a variable's target, not k's own count.
        if (counting_call(context, reference)) |call| {
            try context.report_with(.count_without_arrow, call, reference);
        }
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

/// List.GenerateIntoContainer's lookups: each item of a list literal must exist, and once.
fn check_list_literal(context: *Context, literal: ObjectIndex) !void {
    const ast = context.ast();
    const node = context.tree.node(literal);
    const count = ast.list(node).count;
    for (0..count) |position| {
        const text = context.parsed.leaf_text(ast.item(node, position));
        const dot = std.mem.indexOfScalar(u8, text, '.');
        const list_name: ?[]const u8 = if (dot) |at| text[0..at] else null;
        const item = if (dot) |at| text[at + 1 ..] else text;
        const found = try lookups.resolve_list_item(context, list_name, item, literal) orelse {
            try context.report_details(.list_item_not_found, literal, .{ .name = text });
            continue;
        };
        // An item an earlier position already named (quadratic, as literals are short).
        for (0..position) |earlier| {
            const earlier_text = context.parsed.leaf_text(ast.item(node, earlier));
            const earlier_dot = std.mem.indexOfScalar(u8, earlier_text, '.');
            const earlier_list: ?[]const u8 = if (earlier_dot) |at| earlier_text[0..at] else null;
            const earlier_item = if (earlier_dot) |at| earlier_text[at + 1 ..] else earlier_text;
            const element = lookups.find_list_item(context, earlier_list, earlier_item);
            if (element != found) continue;
            try context.report_details(.duplicate_list_literal_item, literal, .{ .name = text });
            break;
        }
    }
    assert(context.tree.kind(literal) == .list_literal);
}

/// VariableAssignment.ResolveReferences.
fn check_assignment(context: *Context, assignment: ObjectIndex) !void {
    const tree = context.tree;
    assert(tree.kind(assignment) == .variable_assignment);
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
    const tree = context.tree;
    assert(tree.kind(increment) == .increment);
    const ast = context.ast();
    const node = tree.node(increment);
    const name = if (tree.has(increment, Flags.by_expression))
        context.parsed.slot_text(node, .name)
    else
        joined_first(context, ast.slot(ast.slot(node, .name), .path));
    const found = lookups.resolve_variable(context, name, increment);
    context.references[increment.to_int()] = found orelse .unresolved;
    if (found == null) {
        try context.report_details(.increment_target_not_found, increment, .{ .name = name });
    }
    // An increment is a statement: on a line of its own, not inside an expression.
    switch (tree.kind(tree.parent(increment))) {
        .weave, .story, .knot, .stitch, .content_list => {},
        else => try context.report(.increment_as_sub_expression, increment),
    }
}

/// A variable reference's name: ink joins the path with dots; only a one-component path
/// can name a variable.
fn joined_first(context: *const Context, path_node: NodeIndex) []const u8 {
    const path = context.path_of(path_node);
    assert(path.count > 0);
    if (path.count > 1) return "";
    return path.first();
}
