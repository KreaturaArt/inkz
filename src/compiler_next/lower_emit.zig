//! The laid-out IR as a Program (ProgramBuilder, making the calls ink_json's loader makes for
//! the same JSON) and as ink's JSON (ink's JsonSerialisation, with CompactPathString's
//! relative paths), which tests compare with inklecate's output.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const ir_module = @import("lower_ir.zig");
const ink_json = @import("../core/ink_json.zig");
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const Lowering = lower.Lowering;
const Layout = layout_module.Layout;
const ContainerId = ir_module.ContainerId;
const ItemId = ir_module.ItemId;
const Item = ir_module.Item;
const Target = ir_module.Target;

/// Container.countFlags: start-only alone serves no purpose, so it is dropped.
fn count_flags(flags: u8) u8 {
    assert(flags & 0xf8 == 0);
    assert(flags <= 7);
    return if (flags == ir_module.count_start_only) 0 else flags;
}

/// ink writes NativeFunctionCall "^" as "L^".
fn native_word(name: []const u8) []const u8 {
    assert(name.len < 16);
    assert(name.len > 0);
    return if (std.mem.eql(u8, name, "^")) "L^" else name;
}

const Frame = struct { container: ContainerId, next: u32 = 0, next_named: ?u32 = null };

/// The program, through ProgramBuilder.
pub fn emit_program(lowering: *Lowering, layout: *const Layout) !Program {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const gpa = lowering.gpa;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    builder.ink_version = 21;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    _ = try builder.begin_container(.{});
    try frames.append(gpa, .{ .container = lowering.root });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        const child = try step(lowering, layout, &builder, frame, &path) orelse {
            try builder.end_container();
            _ = frames.pop();
            continue;
        };
        try frames.append(gpa, .{ .container = child });
    }
    try add_lists(lowering, &builder);
    return builder.finish();
}

/// The frame's next content item or named child; returns a container begun (to fill next).
fn step(
    lowering: *Lowering,
    layout: *const Layout,
    builder: *ProgramBuilder,
    frame: *Frame,
    path: *std.ArrayList(u8),
) !?ContainerId {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const container = ir.container(frame.container);
    if (frame.next_named == null) {
        while (frame.next < container.content.items.len) {
            const item_id = container.content.items[frame.next];
            frame.next += 1;
            const value = ir.item(item_id);
            if (value == .container) {
                _ = try builder.begin_container(.{});
                return value.container;
            }
            try add_item(lowering, layout, builder, value, path);
        }
        if (container.name) |name| {
            if (!is_named_only(lowering, frame.container)) try builder.set_name(name);
        }
        const flags = count_flags(container.flags);
        if (flags != 0) builder.set_flags(@bitCast(flags));
        frame.next_named = 0;
    }
    const position = frame.next_named.?;
    if (position == container.named.items.len) return null;
    frame.next_named = position + 1;
    const named = container.named.items[position];
    _ = try builder.begin_container(.{ .name = ir.container(named).name.?, .named_only = true });
    return named;
}

fn is_named_only(lowering: *Lowering, id: ContainerId) bool {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const parent = ir.container(id).parent;
    if (parent.is_none()) return false;
    for (ir.container(parent).named.items) |named| {
        if (named == id) return true;
    }
    return false;
}

fn add_item(
    lowering: *Lowering,
    layout: *const Layout,
    builder: *ProgramBuilder,
    value: Item,
    path: *std.ArrayList(u8),
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    path.clearRetainingCapacity();
    switch (value) {
        .container => unreachable,
        .command => |command| try ink_json.add_word_to(builder, command.word()),
        .native => |name| try ink_json.add_word_to(builder, native_word(name)),
        .text => |text| {
            if (std.mem.eql(u8, text, "\n")) return builder.add(.newline, {});
            try builder.add(.text, try builder.intern(text));
        },
        .integer => |integer| try builder.add(.integer, integer),
        .float => |float| try builder.add(.float, float),
        .boolean => |boolean| try builder.add(.bool, boolean),
        .divert => |divert| try add_divert(lowering, layout, builder, divert, path),
        .divert_target => |target| {
            try layout_module.target_path(lowering, layout, target, path);
            try builder.add_container_operand(.divert_target, path.items);
        },
        .read_count => |target| {
            try layout_module.target_path(lowering, layout, target, path);
            try builder.add_container_operand(.read_count, path.items);
        },
        .variable_reference => |name| try builder.add_variable_get(name),
        .assignment => |set| try add_assignment(builder, set.name, set.global, set.new),
        .variable_pointer => |pointer| {
            try ink_json.add_variable_pointer_to(builder, pointer.name, pointer.context);
        },
        .choice_point => |choice| {
            try layout_module.target_path(lowering, layout, choice.target, path);
            try builder.add_choice_point(path.items, @bitCast(@as(u32, choice.flags)));
        },
        .list => |list| try add_list(lowering, builder, list.items, list.origins),
    }
}

fn add_divert(
    lowering: *Lowering,
    layout: *const Layout,
    builder: *ProgramBuilder,
    divert: ir_module.Divert,
    path: *std.ArrayList(u8),
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    var object: ink_json.DivertObject = .{
        .key = "->",
        .target = "",
        .conditional = divert.conditional,
    };
    if (divert.external) |name| {
        object.key = "x()";
        object.target = name;
        object.external_arguments = divert.external_arguments;
        return ink_json.add_divert_object_to(builder, object);
    }
    object.key = switch (divert.kind) {
        .plain => "->",
        .function => "f()",
        .tunnel => "->t->",
    };
    if (divert.variable) |name| {
        object.target = name;
        object.variable = true;
    } else {
        try layout_module.target_path(lowering, layout, divert.target, path);
        object.target = path.items;
    }
    try ink_json.add_divert_object_to(builder, object);
}

fn add_assignment(builder: *ProgramBuilder, name: []const u8, global: bool, new: bool) !void {
    assert(builder.containers.len < std.math.maxInt(u32));
    assert(name.len > 0);
    if (global and new) return builder.add(.global_declare, try builder.global(name));
    if (global) return builder.add_variable_assign(name);
    const interned = try builder.intern(name);
    if (new) return builder.add(.temp_declare, interned);
    try builder.add(.temp_assign, interned);
}

fn add_list(
    lowering: *Lowering,
    builder: *ProgramBuilder,
    items: []const ir_module.ListItem,
    origins: []const []const u8,
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const arena = lowering.ir.arena.allocator();
    const names = try arena.alloc([]const u8, items.len);
    for (items, names) |item, *name| name.* = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        item.origin,
        item.name,
    });
    // ink writes the origins only for an empty list.
    try builder.add_list_literal(names, if (items.len == 0) origins else &.{});
}

/// listDefs: each list with its items' values.
fn add_lists(lowering: *Lowering, builder: *ProgramBuilder) !void {
    assert(lowering.results.len == lowering.tree.count());
    var items: std.ArrayList(ProgramBuilder.ListItemDeclaration) = .empty;
    defer items.deinit(lowering.gpa);
    for (lowering.resolution.lists) |definition| {
        items.clearRetainingCapacity();
        for (lowering.tree.children_of(definition)) |element| {
            const value = lowering.resolution.item_values[element.to_int()];
            try items.append(lowering.gpa, .{
                .name = lowering.child_name(element, 0),
                .value = value,
            });
        }
        _ = try builder.list_origin(
            lowering.child_name(lowering.tree.parent(definition), 0),
            items.items,
        );
    }
    assert(items.items.len < std.math.maxInt(u32));
}
