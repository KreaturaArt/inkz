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
    assert(ir.containers.items.len < std.math.maxInt(u32));
    const container = ir.container(id);
    if (container.name != null or container.named.items.len > 0) return false;
    for (container.content.items) |item_id| {
        const value = ir.item(item_id);
        if (value == .container and ir.container(value.container).name != null) return false;
    }
    return true;
}

/// FlattenContainersIn from the root: every flattenable container's content moves into its
/// nearest unflattened ancestor, in place.
pub fn flatten(lowering: *Lowering) !void {
    assert(lowering.results.len == lowering.tree.count());
    const gpa = lowering.gpa;
    const ir = &lowering.ir;
    var pending: std.ArrayList(ContainerId) = .empty;
    defer pending.deinit(gpa);
    var expanded: std.ArrayList(ItemId) = .empty;
    defer expanded.deinit(gpa);
    var work: std.ArrayList(ItemId) = .empty;
    defer work.deinit(gpa);
    try pending.append(gpa, lowering.root);
    while (pending.pop()) |id| {
        expanded.clearRetainingCapacity();
        work.clearRetainingCapacity();
        try push_reversed(gpa, &work, ir.container(id).content.items);
        while (work.pop()) |item_id| {
            const value = ir.item(item_id);
            if (value == .container and flattenable(ir, value.container)) {
                try push_reversed(gpa, &work, ir.container(value.container).content.items);
                continue;
            }
            try expanded.append(gpa, item_id);
            if (value == .container) try pending.append(gpa, value.container);
        }
        const content = &ir.container(id).content;
        content.clearRetainingCapacity();
        try content.appendSlice(gpa, expanded.items);
        for (ir.container(id).named.items) |named| try pending.append(gpa, named);
    }
    assert(pending.items.len == 0);
}

fn push_reversed(gpa: Allocator, stack: *std.ArrayList(ItemId), items: []const ItemId) !void {
    assert(items.len < std.math.maxInt(u32));
    var position = items.len;
    while (position > 0) {
        position -= 1;
        try stack.append(gpa, items[position]);
    }
    assert(stack.items.len >= items.len);
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
pub fn lay_out(lowering: *Lowering) !Layout {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const gpa = lowering.gpa;
    const ir = &lowering.ir;
    var layout: Layout = .{
        .gpa = gpa,
        .item_container = try gpa.alloc(ContainerId, ir.items.items.len),
        .item_position = try gpa.alloc(u32, ir.items.items.len),
        .container_position = try gpa.alloc(u32, ir.containers.items.len),
    };
    @memset(layout.item_container, .none);
    @memset(layout.item_position, 0);
    @memset(layout.container_position, 0);
    var pending: std.ArrayList(ContainerId) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, lowering.root);
    while (pending.pop()) |id| {
        for (ir.container(id).content.items, 0..) |item_id, position| {
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

/// A target's absolute runtime path.
pub fn target_path(
    lowering: *Lowering,
    layout: *const Layout,
    target: Target,
    out: *std.ArrayList(u8),
) !void {
    assert(lowering.results.len == lowering.tree.count());
    const ir = &lowering.ir;
    switch (target) {
        .none => {},
        .container => |id| try layout.container_path(ir, id, out),
        .object => |object| {
            const container = lowering.runtime_containers[object.to_int()];
            if (!container.is_none()) try layout.container_path(ir, container, out);
        },
        .item => |item_id| {
            const holder = layout.item_container[item_id.to_int()];
            assert(!holder.is_none());
            try layout.container_path(ir, holder, out);
            if (out.items.len > 0) try out.append(layout.gpa, '.');
            try out.print(layout.gpa, "{d}", .{layout.item_position[item_id.to_int()]});
        },
    }
}

/// The components of a target's runtime path.
fn target_components(
    lowering: *Lowering,
    layout: *const Layout,
    target: Target,
    out: *std.ArrayList([]const u8),
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(layout.gpa);
    try target_path(lowering, layout, target, &text);
    if (text.items.len == 0) return;
    const arena = lowering.ir.arena.allocator();
    var parts = std.mem.splitScalar(u8, try arena.dupe(u8, text.items), '.');
    while (parts.next()) |part| try out.append(layout.gpa, part);
}

/// Object.CompactPathString: the path from the item `from` to `target`, relative when that
/// is shorter (as ink writes diverts, choices and read counts).
pub fn compact_path(
    lowering: *Lowering,
    layout: *const Layout,
    from: ItemId,
    target: Target,
    out: *std.ArrayList(u8),
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const gpa = layout.gpa;
    var own: std.ArrayList([]const u8) = .empty;
    defer own.deinit(gpa);
    try target_components(lowering, layout, .{ .item = from }, &own);
    var other: std.ArrayList([]const u8) = .empty;
    defer other.deinit(gpa);
    try target_components(lowering, layout, target, &other);
    var global: std.ArrayList(u8) = .empty;
    defer global.deinit(gpa);
    for (other.items, 0..) |component, position| {
        if (position > 0) try global.append(gpa, '.');
        try global.appendSlice(gpa, component);
    }
    var shared: ?usize = null;
    for (0..@min(own.items.len, other.items.len)) |position| {
        if (!std.mem.eql(u8, own.items[position], other.items[position])) break;
        shared = position;
    }
    const last_shared = shared orelse return out.appendSlice(gpa, global.items);
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(gpa);
    for (0..own.items.len - 1 - last_shared) |_| try relative.appendSlice(gpa, ".^");
    for (other.items[last_shared + 1 ..]) |component| {
        try relative.append(gpa, '.');
        try relative.appendSlice(gpa, component);
    }
    const shorter = if (relative.items.len < global.items.len) relative.items else global.items;
    try out.appendSlice(gpa, shorter);
}
