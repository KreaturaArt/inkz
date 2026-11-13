//! Weave, Choice and Gather generation (ink's Weave.GenerateRuntimeObject and its helpers):
//! gathers named `g-N` and auto-entered or named-only, choices' inner content `c-N`, loose
//! ends diverted to the next gather, and loose ends passed to an ancestor weave.
//!
//! ink generates a nested weave while the enclosing weave is adding the item that holds it,
//! so the loose ends it passes up arrive in the ancestor's list at that point. Generation here
//! is children first, so passed loose ends are queued by the weave they came from, and an
//! ancestor takes them when its loop reaches the item holding that weave.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const ir_module = @import("lower_ir.zig");
const expressions = @import("lower_expressions.zig");
const termination = @import("lower_termination.zig");
const Lowering = lower.Lowering;
const Result = lower.Result;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const ContainerId = ir_module.ContainerId;

const Passed = struct { ancestor: ObjectIndex, from: ObjectIndex, loose_end: ObjectIndex };
const Kept = struct { weave: ObjectIndex, loose_end: ObjectIndex };

pub const States = struct {
    gpa: Allocator,
    /// Loose ends passed up by finished weaves, in the order ink passes them.
    passed: std.ArrayList(Passed) = .empty,
    /// A flow's root weave's final loose ends, for the flow's termination check.
    kept: std.ArrayList(Kept) = .empty,

    pub fn init(gpa: Allocator) States {
        assert(@sizeOf(Generation) > 0);
        assert(@sizeOf(Passed) > 0);
        return .{ .gpa = gpa };
    }

    pub fn deinit(states: *States) void {
        assert(states.passed.capacity >= states.passed.items.len);
        states.passed.deinit(states.gpa);
        states.kept.deinit(states.gpa);
    }
};

/// One weave's generation state (the fields of ink's Weave used while generating).
const Generation = struct {
    root: ContainerId,
    current: ContainerId,
    loose_ends: std.ArrayList(ObjectIndex) = .empty,
    previous: ObjectIndex = .none,
    add_to_previous: bool = false,
    seen_choice_in_section: bool = false,
    unnamed_gathers: u32 = 0,
    choices: u32 = 0,
};

/// Weave.GenerateRuntimeObject.
pub fn generate_weave(lowering: *Lowering, weave: ObjectIndex) !Result {
    assert(lowering.tree.kind(weave) == .weave);
    const ir = &lowering.ir;
    const root = try ir.new_container();
    var generation: Generation = .{ .root = root, .current = root };
    defer generation.loose_ends.deinit(lowering.gpa);
    for (lowering.tree.children_of(weave)) |child| {
        try take_passed(lowering, &generation, weave, child);
        if (lowering.tree.is_weave_point(child)) {
            try add_weave_point(lowering, &generation, child);
        } else if (lowering.tree.kind(child) == .weave) {
            try add_general(lowering, &generation, lowering.result(child));
            if (!generation.previous.is_none()) {
                remove(&generation.loose_ends, generation.previous);
                generation.add_to_previous = false;
            }
        } else {
            try add_general(lowering, &generation, try lowering.content_result(child));
        }
    }
    try pass_to_ancestors(lowering, &generation, weave);
    try termination.check_nested(lowering, weave, generation.loose_ends.items);
    if (lowering.tree.is_flow(lowering.tree.parent(weave))) {
        for (generation.loose_ends.items) |loose_end| {
            const kept: Kept = .{ .weave = weave, .loose_end = loose_end };
            try lowering.weaves.kept.append(lowering.gpa, kept);
        }
    }
    return .{ .container = root };
}

/// FlowBase's check of its root weave's final loose ends (taken from `kept`).
pub fn check_flow_termination(lowering: *Lowering, flow: ObjectIndex) !void {
    assert(lowering.tree.is_flow(flow));
    const kept = &lowering.weaves.kept;
    const children = lowering.tree.children_of(flow);
    const weave = if (children.len > 0) children[0] else ObjectIndex.none;
    var loose_ends: std.ArrayList(ObjectIndex) = .empty;
    defer loose_ends.deinit(lowering.gpa);
    var position: usize = 0;
    while (position < kept.items.len) {
        if (kept.items[position].weave != weave) {
            position += 1;
            continue;
        }
        try loose_ends.append(lowering.gpa, kept.orderedRemove(position).loose_end);
    }
    try termination.check_flow(lowering, flow, loose_ends.items);
    assert(position == kept.items.len);
}

/// Adds the loose ends that weaves under `item` passed to this weave, in their order.
fn take_passed(
    lowering: *Lowering,
    generation: *Generation,
    weave: ObjectIndex,
    item: ObjectIndex,
) !void {
    const states = &lowering.weaves;
    var position: usize = 0;
    while (position < states.passed.items.len) {
        const entry = states.passed.items[position];
        if (entry.ancestor == weave and is_under(lowering, entry.from, item)) {
            try generation.loose_ends.append(lowering.gpa, entry.loose_end);
            _ = states.passed.orderedRemove(position);
        } else position += 1;
    }
    assert(position <= states.passed.items.len);
}

fn is_under(lowering: *const Lowering, object: ObjectIndex, ancestor: ObjectIndex) bool {
    var current = object;
    var steps: u32 = 0;
    while (!current.is_none()) : (steps += 1) {
        assert(steps <= lowering.tree.count());
        if (current == ancestor) return true;
        current = lowering.tree.parent(current);
    }
    return false;
}

fn remove(list: *std.ArrayList(ObjectIndex), object: ObjectIndex) void {
    assert(!object.is_none());
    for (list.items, 0..) |entry, position| {
        if (entry != object) continue;
        _ = list.orderedRemove(position);
        return;
    }
}

/// AddGeneralRuntimeContent.
fn add_general(lowering: *Lowering, generation: *Generation, content: Result) !void {
    const into = if (generation.add_to_previous)
        lowering.runtime_containers[generation.previous.to_int()]
    else
        generation.current;
    assert(!into.is_none());
    switch (content) {
        .none => {},
        .item => |id| try lowering.ir.attach_or_copy(into, id),
        .container => |child| _ = try lowering.ir.add_container(into, child),
    }
}

/// AddRuntimeForWeavePoint.
fn add_weave_point(lowering: *Lowering, generation: *Generation, point: ObjectIndex) !void {
    const tree = lowering.tree;
    const ir = &lowering.ir;
    assert(tree.is_weave_point(point));
    if (tree.kind(point) == .gather) {
        try add_gather(lowering, generation, point);
    } else {
        if (!generation.previous.is_none() and tree.kind(generation.previous) == .gather) {
            remove(&generation.loose_ends, generation.previous);
        }
        try lowering.add_result(generation.current, point);
        // The choice, generated before its weave, set its inner content container.
        const inner = lowering.runtime_containers[point.to_int()];
        assert(!inner.is_none());
        ir.container(inner).name = try std.fmt.allocPrint(
            ir.arena.allocator(),
            "c-{d}",
            .{generation.choices},
        );
        try ir.add_named(generation.current, inner);
        generation.choices += 1;
        generation.seen_choice_in_section = true;
    }
    generation.add_to_previous = false;
    // WeavePointHasLooseEnd: a weave point's content is content lists (and a condition),
    // never a divert, so every weave point is a loose end.
    try generation.loose_ends.append(lowering.gpa, point);
    if (tree.kind(point) == .choice) generation.add_to_previous = true;
    generation.previous = point;
}

/// AddRuntimeForGather.
fn add_gather(lowering: *Lowering, generation: *Generation, gather: ObjectIndex) !void {
    assert(lowering.tree.kind(gather) == .gather);
    const ir = &lowering.ir;
    const auto_enter = !generation.seen_choice_in_section;
    generation.seen_choice_in_section = false;
    const container = lowering.runtime_containers[gather.to_int()];
    assert(!container.is_none());
    if (ir.container(container).name == null) {
        ir.container(container).name = try std.fmt.allocPrint(
            ir.arena.allocator(),
            "g-{d}",
            .{generation.unnamed_gathers},
        );
        generation.unnamed_gathers += 1;
    }
    if (auto_enter) {
        _ = try ir.add_container(generation.current, container);
    } else try ir.add_named(generation.root, container);
    const depth = gather_depth(lowering, gather);
    for (generation.loose_ends.items) |loose_end| {
        const is_gather = lowering.tree.kind(loose_end) == .gather;
        if (is_gather and gather_depth(lowering, loose_end) == depth) continue;
        const holder = lowering.runtime_containers[loose_end.to_int()];
        assert(!holder.is_none());
        _ = try ir.add(holder, .{ .divert = .{ .target = .{ .container = container } } });
    }
    generation.loose_ends.clearRetainingCapacity();
    generation.current = container;
}

/// A weave point's indentation depth (the story's synthesized gather has depth 1).
fn gather_depth(lowering: *const Lowering, point: ObjectIndex) u32 {
    assert(lowering.tree.is_weave_point(point));
    const node = lowering.tree.node(point);
    if (node.is_none()) return 1;
    const header = lowering.ast().data[lowering.ast().child(node, 0).to_int()];
    assert(header & 0xffff > 0);
    return header & 0xffff;
}

/// PassLooseEndsToAncestors: queued for the receiving weave (see the file comment).
fn pass_to_ancestors(lowering: *Lowering, generation: *Generation, weave: ObjectIndex) !void {
    assert(lowering.tree.kind(weave) == .weave);
    if (generation.loose_ends.items.len == 0) return;
    const tree = lowering.tree;
    var inner: ObjectIndex = .none;
    var outer: ObjectIndex = .none;
    var nested = false;
    var ancestor = tree.parent(weave);
    while (!ancestor.is_none()) : (ancestor = tree.parent(ancestor)) {
        if (tree.kind(ancestor) == .weave) {
            if (!nested and inner.is_none()) inner = ancestor;
            if (nested and outer.is_none()) outer = ancestor;
        }
        const kind = tree.kind(ancestor);
        if (kind == .sequence or kind == .conditional) nested = true;
    }
    if (inner.is_none() and outer.is_none()) return;
    var position = generation.loose_ends.items.len;
    while (position > 0) {
        position -= 1;
        const loose_end = generation.loose_ends.items[position];
        const is_choice = tree.kind(loose_end) == .choice;
        const receiver = if (!nested or is_choice or !inner.is_none()) inner else outer;
        if (receiver.is_none()) continue;
        try lowering.weaves.passed.append(lowering.gpa, .{
            .ancestor = receiver,
            .from = weave,
            .loose_end = loose_end,
        });
        _ = generation.loose_ends.orderedRemove(position);
    }
}

/// Gather.GenerateRuntimeObject: named by its label (or later `g-N`), counted from its start.
pub fn generate_gather(lowering: *Lowering, gather: ObjectIndex) !Result {
    assert(lowering.tree.kind(gather) == .gather);
    assert(lowering.runtime_containers[gather.to_int()].is_none());
    const ir = &lowering.ir;
    const container = try ir.new_container();
    const node = lowering.tree.node(gather);
    if (!node.is_none()) {
        const label = lowering.parsed.child_text(node, 1);
        if (label.len > 0) ir.container(container).name = label;
    }
    ir.container(container).flags |= ir_module.count_start_only;
    if (lowering.count_all_visits) ir.container(container).flags |= ir_module.count_visits;
    lowering.runtime_containers[gather.to_int()] = container;
    return .{ .container = container };
}

/// ink's ChoicePoint flags.
const has_condition: u8 = 1;
const has_start_content: u8 = 2;
const has_choice_only_content: u8 = 4;
const invisible_default: u8 = 8;
const once_only: u8 = 16;

/// Choice.GenerateRuntimeObject: the outer container (with the choice point) is the result;
/// the inner content container is the weave point's runtime container.
pub fn generate_choice(lowering: *Lowering, choice: ObjectIndex) !Result {
    assert(lowering.runtime_containers[choice.to_int()].is_none());
    const parts = choice_parts(lowering, choice);
    const ir = &lowering.ir;
    const outer = try ir.new_container();
    const inner = try ir.new_container();
    lowering.runtime_containers[choice.to_int()] = inner;
    var flags: u8 = 0;
    const evaluates = parts.start != null or parts.choice_only != null or parts.condition != null;
    if (evaluates) _ = try ir.add_command(outer, .eval_start);
    var start_container: ContainerId = .none;
    if (parts.start) |start| {
        start_container = lowering.result(start).container;
        try add_start_content(lowering, outer, start_container);
        flags |= has_start_content;
    }
    if (parts.choice_only) |choice_only| {
        _ = try ir.add_command(outer, .begin_string);
        try ir.add_contents_of(outer, lowering.result(choice_only).container);
        _ = try ir.add_command(outer, .end_string);
        flags |= has_choice_only_content;
    }
    if (parts.condition) |condition| {
        try expressions.emit(lowering, outer, condition);
        flags |= has_condition;
    }
    if (evaluates) _ = try ir.add_command(outer, .eval_end);
    const header_leaf = lowering.ast().child(lowering.tree.node(choice), 0);
    const header = lowering.ast().data[header_leaf.to_int()];
    if (header & (1 << 17) != 0) flags |= invisible_default;
    if (!lowering.tree.has(choice, Flags.sticky)) flags |= once_only;
    _ = try ir.add(
        outer,
        .{ .choice_point = .{ .target = .{ .container = inner }, .flags = flags } },
    );
    if (parts.start != null) try add_return_to_start(lowering, inner, start_container);
    try ir.add_contents_of(inner, lowering.result(parts.inner).container);
    ir.container(inner).flags |= ir_module.count_start_only;
    const counted = flags & once_only != 0 or lowering.count_all_visits;
    if (counted) ir.container(inner).flags |= ir_module.count_visits;
    return .{ .container = outer };
}

const Parts = struct {
    start: ?ObjectIndex = null,
    choice_only: ?ObjectIndex = null,
    inner: ObjectIndex = .none,
    condition: ?ObjectIndex = null,
};

/// A choice's children by role (sema adds start, choice-only and inner content as present,
/// then the condition).
fn choice_parts(lowering: *const Lowering, choice: ObjectIndex) Parts {
    // The children are read by position, in the order sema created them.
    assert(lowering.tree.kind(choice) == .choice);
    const ast = lowering.ast();
    const node = lowering.tree.node(choice);
    const children = lowering.tree.children_of(choice);
    var parts: Parts = .{};
    var position: usize = 0;
    if (ast.tag(ast.child(node, 3)) != .none) {
        parts.start = children[position];
        position += 1;
    }
    if (ast.tag(ast.child(node, 4)) != .none) {
        parts.choice_only = children[position];
        position += 1;
    }
    parts.inner = children[position];
    position += 1;
    if (position < children.len) parts.condition = children[position];
    assert(lowering.tree.kind(parts.inner) == .content_list);
    return parts;
}

/// The start content's round trip: `$r` holds where to come back (`$r1`), the content is
/// the named container `s`, which diverts back through `$r`.
fn add_start_content(lowering: *Lowering, outer: ContainerId, start: ContainerId) !void {
    const ir = &lowering.ir;
    // A content list's container, unnamed until it becomes `s` here.
    assert(ir.container(start).name == null);
    const r1 = try ir.new_container();
    ir.container(r1).name = "$r1";
    _ = try ir.add(outer, .{ .divert_target = .{ .container = r1 } });
    _ = try ir.add(outer, .{ .assignment = .{ .name = "$r", .global = false, .new = true } });
    _ = try ir.add_command(outer, .begin_string);
    _ = try ir.add(outer, .{ .divert = .{ .target = .{ .container = start } } });
    ir.container(start).name = "s";
    _ = try ir.add(start, .{ .divert = .{ .variable = "$r" } });
    try ir.add_named(outer, start);
    _ = try ir.add_container(outer, r1);
    _ = try ir.add_command(outer, .end_string);
}

/// The inner content's start: `$r` set to `$r2`, then the start content again.
fn add_return_to_start(lowering: *Lowering, inner: ContainerId, start: ContainerId) !void {
    const ir = &lowering.ir;
    // add_start_content has made it the named container `s` diverted back to.
    assert(ir.container(start).name != null);
    const r2 = try ir.new_container();
    ir.container(r2).name = "$r2";
    _ = try ir.add_command(inner, .eval_start);
    _ = try ir.add(inner, .{ .divert_target = .{ .container = r2 } });
    _ = try ir.add_command(inner, .eval_end);
    _ = try ir.add(inner, .{ .assignment = .{ .name = "$r", .global = false, .new = true } });
    _ = try ir.add(inner, .{ .divert = .{ .target = .{ .container = start } } });
    _ = try ir.add_container(inner, r2);
}
