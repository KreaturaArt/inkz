//! The argument checks ink makes while it generates runtime objects:
//! Divert.CheckArgumentValidity (the count, and divert-target parameters), the by-reference
//! checks of Divert.GenerateRuntimeObject, the divert parameter marker of
//! Divert.ResolveTargetContent, Divert.CheckExternalArgumentValidity, and the built-ins'
//! checks in FunctionCall.GenerateIntoContainer.

const std = @import("std");
const assert = std.debug.assert;
const resolve = @import("resolve.zig");
const lookups = @import("resolve_lookups.zig");
const values = @import("values.zig");
const sema = @import("sema.zig");
const ast_module = @import("ast.zig");
const Context = resolve.Context;
const ObjectIndex = sema.ObjectIndex;
const Tag = ast_module.Tag;

/// Whether a flow was declared with a parameter list, even an empty one (ink's
/// `arguments != null`).
fn has_parameter_list(context: *const Context, flow: ObjectIndex) bool {
    assert(context.tree.is_flow(flow));
    if (context.tree.kind(flow) == .story) return false;
    const ast = context.ast();
    return ast.tag(ast.slot(context.tree.node(flow), .parameters)) != .none;
}

/// Divert.CheckArgumentValidity and the by-reference checks, for a divert whose target the
/// generation pass found (ink checks nothing without target content).
pub fn check_divert(context: *Context, divert: ObjectIndex) !void {
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    const target = context.targets[divert.to_int()];
    if (target.is_none()) return;
    const arguments = tree.children_of(divert);
    const is_flow = tree.is_flow(target);
    const parameters: []const Tag = if (is_flow) context.parameters(target) else &.{};
    if (arguments.len == 0 and parameters.len == 0) return;
    // From here on, a target that isn't a flow, or has no parameter list, got arguments.
    if (!is_flow) return context.report(.arguments_to_non_flow, divert);
    if (!has_parameter_list(context, target)) {
        return context.report_with(.flow_takes_no_parameters, divert, target);
    }
    if (tree.kind(tree.parent(divert)) == .divert_target) {
        if (arguments.len > 0) try context.report(.arguments_in_divert_target, divert);
        return;
    }
    if (parameters.len != arguments.len) return context.report_details(
        .wrong_argument_count,
        divert,
        .{ .other = target, .numbers = .{ @intCast(parameters.len), @intCast(arguments.len) } },
    );
    for (arguments, parameters, 0..) |argument, parameter, position| {
        if (parameter != .divert_parameter) continue;
        try check_divert_target(context, divert, argument, @intCast(position));
    }
    for (arguments, parameters, 0..) |argument, parameter, position| {
        if (parameter != .reference_parameter) continue;
        if (!try check_reference(context, divert, argument, @intCast(position))) break;
    }
}

/// An argument for a `-> x` parameter: a divert target, or a variable that holds one (not
/// the name of a knot, stitch or label: that would pass its read count).
fn check_divert_target(
    context: *Context,
    divert: ObjectIndex,
    argument: ObjectIndex,
    position: u32,
) !void {
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    assert(tree.parent(argument) == divert);
    const target = context.targets[divert.to_int()];
    switch (tree.kind(argument)) {
        .divert_target => {},
        .variable_reference => {
            const path = context.path_of(context.ast().slot(tree.node(argument), .path));
            if (try lookups.resolve_path(context, &path, argument) != null) {
                try context.report_with(.read_count_instead_of_divert_target, divert, argument);
            }
        },
        // ink reports this one on the argument, naming the target and the parameter.
        else => try context.report_details(.divert_target_argument_expected, argument, .{
            .other = target,
            .name = context.parameter_name(target, position),
        }),
    }
}

/// An argument for a `ref x` parameter: a variable's name, not a read count's. False if it
/// isn't (ink stops checking at the first).
fn check_reference(
    context: *Context,
    divert: ObjectIndex,
    argument: ObjectIndex,
    position: u32,
) !bool {
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    assert(tree.parent(argument) == divert);
    if (tree.kind(argument) != .variable_reference) {
        try context.report_details(.reference_argument_not_variable, divert, .{
            .other = argument,
            .name = context.parameter_name(context.targets[divert.to_int()], position),
        });
        return false;
    }
    const path = context.path_of(context.ast().slot(tree.node(argument), .path));
    if (try lookups.resolve_path(context, &path, divert) != null) {
        try context.report_with(.read_count_by_reference, divert, argument);
        return false;
    }
    return true;
}

/// Divert.ResolveTargetContent: a divert to a parameter's value needs the parameter marked
/// `-> name`; the error is on the parameter's flow.
pub fn check_divert_parameter(context: *Context, divert: ObjectIndex, name: []const u8) !void {
    assert(context.tree.kind(divert) == .divert);
    assert(name.len > 0);
    const owner = context.tree.closest_flow(divert);
    const parameters = context.parameters(owner);
    for (parameters, 0..) |parameter, position| {
        if (!std.mem.eql(u8, name, context.parameter_name(owner, @intCast(position)))) continue;
        if (parameter != .divert_parameter) try context.report_details(
            .divert_parameter_unmarked,
            owner,
            .{ .other = divert, .name = name },
        );
        return;
    }
}

/// Divert.CheckExternalArgumentValidity: a call to an EXTERNAL passes as many arguments as
/// it declares.
pub fn check_external(context: *Context, divert: ObjectIndex, external: ObjectIndex) !void {
    const tree = context.tree;
    assert(tree.kind(divert) == .divert);
    assert(tree.kind(external) == .external_declaration);
    const ast = context.ast();
    const declared = ast.list(ast.slot(tree.node(external), .parameters)).count;
    const given: u32 = @intCast(tree.children_of(divert).len);
    if (declared != given) try context.report_details(.external_argument_count, divert, .{
        .numbers = .{ declared, given },
    });
}

/// The number of parameters of Runtime.NativeFunctionCall's functions that can be called
/// by name.
fn native_parameters(name: []const u8) ?u32 {
    assert(name.len == 0 or name[0] != ' ');
    const binary = [_][]const u8{ "MIN", "MAX", "POW" };
    const unary = [_][]const u8{
        "FLOOR",    "CEILING",  "INT",        "FLOAT",      "LIST_MIN",
        "LIST_MAX", "LIST_ALL", "LIST_COUNT", "LIST_VALUE", "LIST_INVERT",
    };
    for (binary) |native| {
        if (std.mem.eql(u8, name, native)) return 2;
    }
    for (unary) |native| {
        if (std.mem.eql(u8, name, native)) return 1;
    }
    return null;
}

/// The number of arguments a built-in control command takes.
fn command_parameters(name: []const u8) ?u32 {
    assert(name.len == 0 or name[0] != ' ');
    const names = [_][]const u8{
        "CHOICE_COUNT", "TURNS",       "TURNS_SINCE", "READ_COUNT",
        "RANDOM",       "SEED_RANDOM", "LIST_RANGE",  "LIST_RANDOM",
    };
    const counts = [_]u32{ 0, 0, 1, 1, 2, 1, 3, 1 };
    for (names, counts) |command, count| {
        if (std.mem.eql(u8, name, command)) return count;
    }
    return null;
}

/// FunctionCall.GenerateIntoContainer's checks of a built-in's arguments, or of a list's
/// name called to make a list.
pub fn check_call(context: *Context, call: ObjectIndex, is_list: bool) !void {
    const tree = context.tree;
    assert(tree.kind(call) == .function_call);
    const name = context.slot_name(call, .name);
    const arguments = tree.children_of(tree.children_of(call)[0]);
    const expected = command_parameters(name) orelse native_parameters(name) orelse {
        if (is_list and arguments.len > 1) {
            try context.report(.list_from_more_than_one_value, call);
        }
        return;
    };
    // `numbers`: the parameters it takes, for the message.
    const count_error: resolve.Details = .{ .numbers = .{ expected, 0 } };
    if (arguments.len != expected) {
        return context.report_details(.builtin_argument_count, call, count_error);
    }
    const is_count = std.mem.eql(u8, name, "TURNS_SINCE") or std.mem.eql(u8, name, "READ_COUNT");
    if (is_count) {
        const kind = tree.kind(arguments[0]);
        if (kind != .divert_target and kind != .variable_reference) {
            try context.report_details(.builtin_argument_count, call, count_error);
        }
        return;
    }
    if (std.mem.eql(u8, name, "RANDOM") or std.mem.eql(u8, name, "SEED_RANDOM")) {
        // `numbers`: which argument (RANDOM's minimum or maximum).
        for (arguments, 0..) |argument, position| {
            if (is_non_integer_number(context, argument)) {
                return context.report_details(.builtin_argument_not_integer, call, .{
                    .numbers = .{ @intCast(position), 0 },
                });
            }
        }
    }
}

/// Whether an argument is ink's Number (a literal, folded through unary operators as ink's
/// parser folds it) holding a float or a bool.
fn is_non_integer_number(context: *const Context, argument: ObjectIndex) bool {
    const kind = context.tree.kind(argument);
    assert(argument.to_int() < context.tree.count());
    if (kind != .number and kind != .unary) return false;
    // A fold ink can't do is reported where the expression is generated.
    const value = values.literal(context.parsed, context.tree, argument) catch return false;
    const literal = value orelse return false;
    return literal != .integer;
}
