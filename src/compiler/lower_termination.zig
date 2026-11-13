//! ink's termination checks (Weave.ValidateTermination) on a weave's final loose ends:
//! an error for a weave nested in a conditional or sequence that keeps loose ends (from
//! Weave.ResolveReferences, BadNestedTerminationHandler), and a warning for a knot's or
//! stitch's root weave whose flow runs out (from FlowBase.GenerateRuntimeObject,
//! WarningInTermination). Functions don't need to terminate, and a flow with a `return`
//! already has an error for it.

const std = @import("std");
const assert = std.debug.assert;
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const Lowering = lower.Lowering;
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;

const Handler = enum { nested, flow };

/// Weave.ResolveReferences' check: a weave nested in a conditional or sequence must not
/// keep loose ends that run out.
pub fn check_nested(
    lowering: *Lowering,
    weave: ObjectIndex,
    loose_ends: []const ObjectIndex,
) !void {
    assert(lowering.tree.kind(weave) == .weave);
    assert(loose_ends.len < lowering.tree.count());
    if (loose_ends.len == 0) return;
    const tree = lowering.tree;
    var ancestor = tree.parent(weave);
    while (!ancestor.is_none()) : (ancestor = tree.parent(ancestor)) {
        const kind = tree.kind(ancestor);
        if (kind == .sequence or kind == .conditional) break;
    } else return;
    try validate(lowering, weave, loose_ends, .nested);
}

/// FlowBase.GenerateRuntimeObject's check of a knot's or stitch's root weave.
pub fn check_flow(lowering: *Lowering, flow: ObjectIndex, loose_ends: []const ObjectIndex) !void {
    assert(lowering.tree.is_flow(flow));
    assert(loose_ends.len < lowering.tree.count());
    const tree = lowering.tree;
    if (tree.kind(flow) == .story or tree.has(flow, Flags.function)) return;
    const children = tree.children_of(flow);
    if (children.len == 0 or tree.kind(children[0]) != .weave) return;
    if (try tree.find(lowering.gpa, flow, Tree.is_return) != null) return;
    try validate(lowering, children[0], loose_ends, .flow);
}

/// Weave.ValidateTermination.
fn validate(
    lowering: *Lowering,
    weave: ObjectIndex,
    loose_ends: []const ObjectIndex,
    handler: Handler,
) !void {
    assert(lowering.tree.kind(weave) == .weave);
    assert(loose_ends.len < lowering.tree.count());
    const tree = lowering.tree;
    // A final TODO means the author knows.
    if (last_significant(tree, weave)) |last| {
        if (tree.kind(last) == .author_warning) return;
    }
    if (loose_ends.len > 0) {
        for (loose_ends) |loose_end| {
            var flow: Following = .after_point(tree, loose_end);
            try validate_flow(lowering, &flow, loose_end, handler);
        }
        return;
    }
    // Any weaving would have left a loose end: only a linear flow is checked.
    for (tree.children_of(weave)) |child| {
        if (tree.is_weave_point(child)) return;
    }
    var flow: Following = .linear(tree, weave);
    try validate_flow(lowering, &flow, weave, handler);
}

/// Weave.lastParsedSignificantObject: the last object that isn't a newline or a global
/// declaration, looking into a final nested weave.
fn last_significant(tree: *const Tree, weave_initial: ObjectIndex) ?ObjectIndex {
    assert(tree.kind(weave_initial) == .weave);
    var weave = weave_initial;
    var steps: u32 = 0;
    while (steps < tree.count()) : (steps += 1) {
        const children = tree.children_of(weave);
        if (children.len == 0) return null;
        var position = children.len;
        var last = children[0];
        while (position > 0) {
            position -= 1;
            last = children[position];
            const newline = tree.kind(last) == .text and tree.has(last, Flags.newline);
            if (!newline and !is_global_declaration(tree, last)) break;
        }
        if (tree.kind(last) != .weave) return last;
        weave = last;
    }
    unreachable;
}

/// ContentThatFollowsWeavePoint (after a weave point) or a weave's whole content.
const Following = struct {
    tree: *const Tree,
    /// The weave point's content, then its weave's content after it.
    inner: []const ObjectIndex,
    outer: []const ObjectIndex,
    /// For a weave point, the outer content stops at the next weave point or weave.
    stops: bool,

    fn after_point(tree: *const Tree, point: ObjectIndex) Following {
        assert(tree.is_weave_point(point));
        const weave = tree.parent(point);
        assert(tree.kind(weave) == .weave);
        const siblings = tree.children_of(weave);
        const position = std.mem.indexOfScalar(ObjectIndex, siblings, point).?;
        return .{
            .tree = tree,
            .inner = tree.children_of(point),
            .outer = siblings[position + 1 ..],
            .stops = true,
        };
    }

    fn linear(tree: *const Tree, weave: ObjectIndex) Following {
        assert(tree.kind(weave) == .weave);
        assert(tree.count() > 0);
        return .{ .tree = tree, .inner = &.{}, .outer = tree.children_of(weave), .stops = false };
    }

    fn next(following: *Following) ?ObjectIndex {
        assert(following.inner.len < following.tree.count());
        assert(following.stops or following.inner.len == 0);
        assert(following.outer.len < following.tree.count());
        const tree = following.tree;
        while (following.inner.len > 0) {
            const object = following.inner[0];
            following.inner = following.inner[1..];
            if (!is_global_declaration(tree, object)) return object;
        }
        while (following.outer.len > 0) {
            const object = following.outer[0];
            following.outer = following.outer[1..];
            if (following.stops and is_global_declaration(tree, object)) continue;
            const ends = tree.is_weave_point(object) or tree.kind(object) == .weave;
            if (following.stops and ends) {
                following.outer = &.{};
                return null;
            }
            return object;
        }
        return null;
    }
};

/// ValidateFlowOfObjectsTerminates.
fn validate_flow(
    lowering: *Lowering,
    flow: *Following,
    default: ObjectIndex,
    handler: Handler,
) !void {
    assert(default.to_int() < lowering.tree.count());
    assert(flow.tree == lowering.tree);
    const tree = lowering.tree;
    assert(handler == .flow or handler == .nested);
    var terminated = false;
    var terminating = default;
    while (flow.next()) |object| {
        if (try tree.find(lowering.gpa, object, is_terminating_divert) != null) terminated = true;
        if (try tree.find(lowering.gpa, object, is_tunnel_onwards) != null) {
            terminated = true;
            break;
        }
        terminating = object;
    }
    if (terminated or tree.kind(terminating) == .author_warning) return;
    switch (handler) {
        .flow => try lowering.report(.loose_end, terminating),
        .nested => try report_nested(lowering, terminating),
    }
}

/// BadNestedTerminationHandler: with one choice in the conditional, ink suggests a
/// conditional choice instead.
fn report_nested(lowering: *Lowering, terminating: ObjectIndex) !void {
    assert(terminating.to_int() < lowering.tree.count());
    const tree = lowering.tree;
    var ancestor = tree.parent(terminating);
    while (!ancestor.is_none()) : (ancestor = tree.parent(ancestor)) {
        const kind = tree.kind(ancestor);
        if (kind == .sequence or kind == .conditional) break;
    }
    assert(!ancestor.is_none());
    if (tree.kind(ancestor) == .conditional) {
        var choices: std.ArrayList(ObjectIndex) = .empty;
        defer choices.deinit(lowering.gpa);
        try tree.find_all(lowering.gpa, ancestor, Tree.is_choice, &choices);
        if (choices.items.len == 1) return lowering.report(.conditional_choice_syntax, terminating);
    }
    try lowering.report(.nested_choice_needs_divert, terminating);
}

/// Weave.IsGlobalDeclaration: VAR and CONST are outside the flow.
fn is_global_declaration(tree: *const Tree, object: ObjectIndex) bool {
    assert(object.to_int() < tree.count());
    const kind = tree.kind(object);
    assert(tree.count() > 0);
    if (kind == .constant_declaration) return true;
    return kind == .variable_assignment and tree.has(object, Flags.global);
}

/// A divert that leaves the flow (not a thread, tunnel or function call's, nor a target).
fn is_terminating_divert(tree: *const Tree, object: ObjectIndex) bool {
    assert(object.to_int() < tree.count());
    assert(tree.count() > 0);
    if (tree.kind(object) != .divert) return false;
    const returns = Flags.thread | Flags.tunnel | Flags.function_call;
    if (tree.flags[object.to_int()] & returns != 0) return false;
    return tree.kind(tree.parent(object)) != .divert_target;
}

fn is_tunnel_onwards(tree: *const Tree, object: ObjectIndex) bool {
    assert(object.to_int() < tree.count());
    assert(tree.count() > 0);
    return tree.kind(object) == .tunnel_onwards;
}
