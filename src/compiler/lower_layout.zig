//! The end of ink's ExportRuntime on the lowering's IR: the count flags ResolveReferences
//! sets (read counts, divert targets, TURNS_SINCE), FlattenContainersIn (an unnamed container
//! without named content is spliced into its parent), the runtime paths of every target,
//! and the emission through ProgramBuilder (in the order ink_json's loader would make the
//! same calls).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const ir_module = @import("lower_ir.zig");
const ink_json = @import("../core/ink_json.zig");
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const Lowering = lower.Lowering;
const Lowered = lower.Lowered;
const ObjectIndex = sema.ObjectIndex;
const Ir = ir_module.Ir;
const ContainerId = ir_module.ContainerId;
const ItemId = ir_module.ItemId;
const Item = ir_module.Item;
const Target = ir_module.Target;

/// The count flags ink's ResolveReferences sets on the containers it counts.
pub fn set_count_flags(lowering: *Lowering) void {
    assert(lowering.results.len == lowering.tree.count());
    const tree = lowering.tree;
    for (0..tree.count()) |position| {
        const object: ObjectIndex = .from_int(@intCast(position));
        const target = lowering.resolution.targets[object.to_int()];
        switch (tree.kind(object)) {
            .variable_reference => {
                if (lowering.resolution.references[object.to_int()] != .read_count) continue;
                flag(lowering, target, ir_module.count_visits);
            },
            .divert_target => {
                const divert = tree.children_of(object)[0];
                const counted = lowering.resolution.targets[divert.to_int()];
                // ink moves a TURNS_SINCE argument under the call (out of its proxy divert).
                var parent = tree.parent(object);
                if (tree.kind(parent) == .divert and tree.has(parent, sema.Flags.function_call)) {
                    parent = tree.parent(parent);
                }
                const turns_only = tree.kind(parent) == .function_call and
                    std.mem.eql(u8, lowering.child_name(parent, 0), "TURNS_SINCE");
                const both = ir_module.count_visits | ir_module.count_turns;
                const flags = if (turns_only) ir_module.count_turns else both;
                flag(lowering, counted, flags);
            },
            else => {},
        }
    }
    assert(lowering.runtime_containers.len == tree.count());
}

fn flag(lowering: *Lowering, object: ObjectIndex, flags: u8) void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    if (object.is_none()) return;
    const container = lowering.runtime_containers[object.to_int()];
    if (container.is_none()) return;
    lowering.ir.container(container).flags |= flags;
}

/// TryFlattenContainer's test: no name and no named content (named-only or in content).
fn flattenable(ir: *Ir, id: ContainerId) bool {
    assert(ir.items.items.len < std.math.maxInt(u32));
    const container = ir.container(id);
    if (container.name != null or container.named.items.len > 0) return false;
    var item_id = container.first;
    while (!item_id.is_none()) : (item_id = ir.next.items[item_id.to_int()]) {
        const value = ir.item(item_id);
        if (value == .container and ir.container(value.container).name != null) return false;
    }
    return true;
}

/// FlattenContainersIn from the root: every flattenable container's content moves into its
/// nearest unflattened ancestor, in place. Each kept container's final content becomes one
/// run of `Ir.flat`.
pub fn flatten(lowering: *Lowering) !void {
    assert(lowering.results.len == lowering.tree.count());
    const gpa = lowering.gpa;
    const ir = &lowering.ir;
    var pending: std.ArrayList(ContainerId) = .empty;
    defer pending.deinit(gpa);
    // Cursors into the linked contents being expanded, innermost last.
    var cursors: std.ArrayList(ItemId) = .empty;
    defer cursors.deinit(gpa);
    try ir.flat.ensureTotalCapacityPrecise(gpa, ir.items.items.len);
    try pending.append(gpa, lowering.root);
    while (pending.pop()) |id| {
        const first: u32 = @intCast(ir.flat.items.len);
        try cursors.append(gpa, ir.container(id).first);
        while (cursors.items.len > 0) {
            const top = &cursors.items[cursors.items.len - 1];
            const item_id = top.*;
            if (item_id.is_none()) {
                _ = cursors.pop();
                continue;
            }
            top.* = ir.next.items[item_id.to_int()];
            const value = ir.item(item_id);
            if (value == .container and flattenable(ir, value.container)) {
                try cursors.append(gpa, ir.container(value.container).first);
                continue;
            }
            try ir.flat.append(gpa, item_id);
            if (value == .container) try pending.append(gpa, value.container);
        }
        ir.container(id).flat_first = first;
        ir.container(id).flat_count = @as(u32, @intCast(ir.flat.items.len)) - first;
        for (ir.container(id).named.items) |named| try pending.append(gpa, named);
    }
    assert(pending.items.len == 0);
}

/// Where each item and container ended up, for paths.
pub const Layout = struct {
    gpa: Allocator,
    item_container: []ContainerId,
    item_position: []u32,
    container_position: []u32,

    pub fn deinit(layout: *Layout) void {
        assert(layout.container_position.len > 0);
        assert(layout.item_container.len == layout.item_position.len);
        layout.gpa.free(layout.item_container);
        layout.gpa.free(layout.item_position);
        layout.gpa.free(layout.container_position);
    }

    /// The runtime path of a container: names, or positions for unnamed ones.
    pub fn container_path(
        layout: *const Layout,
        ir: *Ir,
        id: ContainerId,
        out: *std.ArrayList(u8),
    ) !void {
        assert(ir.items.items.len < std.math.maxInt(u32));
        assert(ir.containers.items.len < std.math.maxInt(u32));
        var chain: [64]ContainerId = undefined;
        var depth: u32 = 0;
        var current = id;
        while (!ir.container(current).parent.is_none()) : (current = ir.container(current).parent) {
            if (depth == chain.len) return error.PathTooDeep;
            chain[depth] = current;
            depth += 1;
        }
        while (depth > 0) {
            depth -= 1;
            const component = chain[depth];
            if (out.items.len > 0) try out.append(layout.gpa, '.');
            if (ir.container(component).name) |name| {
                try out.appendSlice(layout.gpa, name);
            } else try out.print(
                layout.gpa,
                "{d}",
                .{layout.container_position[component.to_int()]},
            );
        }
    }
};

/// Sets each container's parent and records every position.
pub fn lay_out(lowered: *Lowered) !Layout {
    assert(!lowered.root.is_none());
    assert(lowered.ir.flat.items.len <= lowered.ir.items.items.len);
    const ir = &lowered.ir;
    const gpa = ir.gpa;
    var layout: Layout = .{
        .gpa = gpa,
        .item_container = try gpa.alloc(ContainerId, ir.items.items.len),
        .item_position = try gpa.alloc(u32, ir.items.items.len),
        .container_position = try gpa.alloc(u32, ir.containers.items.len),
    };
    errdefer layout.deinit();
    @memset(layout.item_container, .none);
    @memset(layout.item_position, 0);
    @memset(layout.container_position, 0);
    var pending: std.ArrayList(ContainerId) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, lowered.root);
    while (pending.pop()) |id| {
        for (ir.content_of(id), 0..) |item_id, position| {
            layout.item_container[item_id.to_int()] = id;
            layout.item_position[item_id.to_int()] = @intCast(position);
            const value = ir.item(item_id);
            if (value != .container) continue;
            ir.container(value.container).parent = id;
            layout.container_position[value.container.to_int()] = @intCast(position);
            try pending.append(gpa, value.container);
        }
        for (ir.container(id).named.items) |named| {
            ir.container(named).parent = id;
            try pending.append(gpa, named);
        }
    }
    return layout;
}

/// A target's absolute runtime path (object targets are resolved to containers by now).
pub fn target_path(ir: *Ir, layout: *const Layout, target: Target, out: *std.ArrayList(u8)) !void {
    assert(ir.items.items.len == layout.item_container.len);
    assert(target != .object);
    switch (target) {
        .none => {},
        .container => |id| try layout.container_path(ir, id, out),
        .object => unreachable,
        .item => |item_id| {
            const holder = layout.item_container[item_id.to_int()];
            assert(!holder.is_none());
            try layout.container_path(ir, holder, out);
            if (out.items.len > 0) try out.append(layout.gpa, '.');
            try out.print(layout.gpa, "{d}", .{layout.item_position[item_id.to_int()]});
        },
    }
}

/// The components of a target's runtime path, slices of its text (written to `text`).
fn target_components(
    ir: *Ir,
    layout: *const Layout,
    target: Target,
    text: *std.ArrayList(u8),
    out: *std.ArrayList([]const u8),
) !void {
    assert(ir.items.items.len == layout.item_container.len);
    assert(out.items.len == 0 and text.items.len == 0);
    try target_path(ir, layout, target, text);
    if (text.items.len == 0) return;
    var parts = std.mem.splitScalar(u8, text.items, '.');
    while (parts.next()) |part| try out.append(layout.gpa, part);
}

/// Object.CompactPathString: the path from the item `from` to `target`, relative when that
/// is shorter (as ink writes diverts, choices and read counts).
pub fn compact_path(
    ir: *Ir,
    layout: *const Layout,
    from: ItemId,
    target: Target,
    out: *std.ArrayList(u8),
) !void {
    assert(ir.items.items.len == layout.item_container.len);
    assert(from.to_int() < ir.items.items.len);
    const gpa = layout.gpa;
    var own_text: std.ArrayList(u8) = .empty;
    defer own_text.deinit(gpa);
    var own: std.ArrayList([]const u8) = .empty;
    defer own.deinit(gpa);
    try target_components(ir, layout, .{ .item = from }, &own_text, &own);
    var other_text: std.ArrayList(u8) = .empty;
    defer other_text.deinit(gpa);
    var other: std.ArrayList([]const u8) = .empty;
    defer other.deinit(gpa);
    try target_components(ir, layout, target, &other_text, &other);
    const global = other_text.items;
    var shared: ?usize = null;
    for (0..@min(own.items.len, other.items.len)) |position| {
        if (!std.mem.eql(u8, own.items[position], other.items[position])) break;
        shared = position;
    }
    const last_shared = shared orelse return out.appendSlice(gpa, global);
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(gpa);
    for (0..own.items.len - 1 - last_shared) |_| try relative.appendSlice(gpa, ".^");
    for (other.items[last_shared + 1 ..]) |component| {
        try relative.append(gpa, '.');
        try relative.appendSlice(gpa, component);
    }
    const shorter = if (relative.items.len < global.len) relative.items else global;
    try out.appendSlice(gpa, shorter);
}
