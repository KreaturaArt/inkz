//! The laid-out IR as a Program, through ProgramBuilder, making the calls ink_json's loader
//! makes for the same JSON, so the program equals the one loaded from inklecate's output;
//! ink_json.serialize writes it back as JSON. Targets (of diverts, choices, read counts and
//! divert targets) go to the builder as the IR's own containers and positions, not as paths
//! it would parse back. The lowering tests check the paths ink_json.serialize writes for
//! them against inklecate's, and the verified pair that loading those paths gives the same
//! targets.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const ir_module = @import("lower_ir.zig");
const ink_json = @import("../core/ink_json.zig");
const program_builder = @import("../core/program_builder.zig");
const ProgramBuilder = program_builder.ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const Lowered = lower.Lowered;
const Layout = layout_module.Layout;
const ContainerId = ir_module.ContainerId;
const Item = ir_module.Item;
const Target = ir_module.Target;
const KeyTarget = program_builder.KeyTarget;

/// Container.countFlags: start-only alone serves no purpose, so it is dropped.
fn count_flags(flags: u8) u8 {
    assert(flags & 0xf8 == 0);
    assert(flags <= 7);
    return if (flags == ir_module.count_start_only) 0 else flags;
}

/// Each command's opcode, from the word ink writes for it (as the JSON loader reads it).
const command_opcodes = table: {
    const Command = ir_module.Command;
    const Opcode = @import("../core/instruction.zig").Opcode;
    var table: [@typeInfo(Command).@"enum".field_names.len]Opcode = undefined;
    for (std.enums.values(Command)) |command| {
        table[@backingInt(command)] = ink_json.words.get(command.word()).?;
    }
    break :table table;
};

/// ink writes NativeFunctionCall "^" as "L^".
fn native_word(name: []const u8) []const u8 {
    assert(name.len < 16);
    assert(name.len > 0);
    return if (std.mem.eql(u8, name, "^")) "L^" else name;
}

const Frame = struct { container: ContainerId, next: u32 = 0, next_named: ?u32 = null };

/// The program, through ProgramBuilder.
pub fn emit_program(lowered: *Lowered, layout: *const Layout) !Program {
    assert(lowered.ir.items.items.len == layout.item_container.len);
    assert(!lowered.root.is_none());
    const gpa = lowered.ir.gpa;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    builder.ink_version = 21;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    _ = try builder.begin_container(.{ .key = lowered.root.to_int() });
    try frames.append(gpa, .{ .container = lowered.root });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        const child = try step(lowered, layout, &builder, frame) orelse {
            try builder.end_container();
            _ = frames.pop();
            continue;
        };
        try frames.append(gpa, .{ .container = child });
    }
    try add_lists(lowered, &builder);
    return builder.finish();
}

/// The frame's next content item or named child; returns a container begun (to fill next).
fn step(
    lowered: *Lowered,
    layout: *const Layout,
    builder: *ProgramBuilder,
    frame: *Frame,
) !?ContainerId {
    assert(lowered.ir.items.items.len == layout.item_container.len);
    const ir = &lowered.ir;
    const container = ir.container(frame.container);
    if (frame.next_named == null) {
        const content = ir.content_of(frame.container);
        while (frame.next < content.len) {
            const item_id = content[frame.next];
            frame.next += 1;
            const value = ir.item(item_id);
            if (value == .container) {
                _ = try builder.begin_container(.{ .key = value.container.to_int() });
                return value.container;
            }
            try add_item(lowered, layout, builder, value);
        }
        frame.next_named = 0;
    }
    const position = frame.next_named.?;
    if (position == container.named.items.len) {
        // The final dictionary: named content first, then "#f" and "#n", as the loader reads it.
        if (container.name) |name| {
            if (!is_named_only(lowered, frame.container)) try builder.set_name(name);
        }
        const flags = count_flags(container.flags);
        if (flags != 0) builder.set_flags(@bitCast(flags));
        return null;
    }
    frame.next_named = position + 1;
    const named = container.named.items[position];
    _ = try builder.begin_container(.{
        .name = ir.container(named).name.?,
        .named_only = true,
        .key = named.to_int(),
    });
    return named;
}

fn is_named_only(lowered: *Lowered, id: ContainerId) bool {
    assert(id.to_int() < lowered.ir.containers.items.len);
    assert(!lowered.root.is_none());
    const ir = &lowered.ir;
    const parent = ir.container(id).parent;
    if (parent.is_none()) return false;
    for (ir.container(parent).named.items) |named| {
        if (named == id) return true;
    }
    return false;
}

fn add_item(lowered: *Lowered, layout: *const Layout, builder: *ProgramBuilder, value: Item) !void {
    assert(lowered.ir.items.items.len == layout.item_container.len);
    switch (value) {
        .container => unreachable,
        .command => |command| try builder.add_bare(command_opcodes[@backingInt(command)]),
        .native => |name| try ink_json.add_word_to(builder, native_word(name)),
        .text => |text| {
            if (std.mem.eql(u8, text, "\n")) return builder.add(.newline, {});
            try builder.add(.text, try builder.intern(text));
        },
        .integer => |integer| try builder.add(.integer, integer),
        .float => |float| try builder.add(.float, float),
        .boolean => |boolean| try builder.add(.bool, boolean),
        .divert => |divert| try emit_divert(layout, builder, divert),
        .divert_target => |target| {
            try builder.add_container_operand(.divert_target, key_of(layout, target));
        },
        .read_count => |target| {
            try builder.add_container_operand(.read_count, key_of(layout, target));
        },
        .variable_reference => |name| try builder.add_variable(name, .get),
        .assignment => |set| try add_assignment(builder, set.name, set.global, set.new),
        .variable_pointer => |pointer| {
            try ink_json.add_variable_pointer_to(builder, pointer.name, pointer.context);
        },
        .choice_point => |choice| {
            const flags: @import("../core/instruction.zig").ChoiceFlags = @bitCast(
                @as(u32, choice.flags),
            );
            try builder.add_choice_point(key_of(layout, choice.target), flags);
        },
        .list => |list| try add_list(lowered, builder, list.items, list.origins),
    }
}

fn emit_divert(layout: *const Layout, builder: *ProgramBuilder, divert: ir_module.Divert) !void {
    assert(divert.external == null or divert.variable == null);
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
        return ink_json.add_divert_object_to(builder, object);
    }
    try builder.add_divert(key_of(layout, divert.target), .{
        .kind = switch (divert.kind) {
            .plain => .plain,
            .function => .function,
            .tunnel => .tunnel,
        },
        .conditional = divert.conditional,
        .variable = false,
    });
}

/// A target as the builder's key: the IR container, or an item's container and position.
fn key_of(layout: *const Layout, target: Target) KeyTarget {
    assert(target == .container or target == .item);
    assert(layout.item_container.len == layout.item_position.len);
    return switch (target) {
        .container => |id| .{ .key = id.to_int() },
        .item => |item_id| .{
            .key = layout.item_container[item_id.to_int()].to_int(),
            .index = layout.item_position[item_id.to_int()],
        },
        .none, .object => unreachable,
    };
}

fn add_assignment(builder: *ProgramBuilder, name: []const u8, global: bool, new: bool) !void {
    assert(name.len > 0);
    if (global and new) return builder.add(.global_declare, try builder.global(name));
    if (global) return builder.add_variable(name, .assign);
    const interned = try builder.intern(name);
    if (new) return builder.add(.temp_declare, interned);
    try builder.add(.temp_assign, interned);
}

fn add_list(
    lowered: *Lowered,
    builder: *ProgramBuilder,
    items: []const ir_module.ListItem,
    origins: []const []const u8,
) !void {
    assert(!lowered.root.is_none());
    const arena = lowered.ir.arena.allocator();
    const names = try arena.alloc([]const u8, items.len);
    for (items, names) |item, *name| name.* = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        item.origin,
        item.name,
    });
    // ink writes the origins only for an empty list.
    try builder.add_list_literal(names, if (items.len == 0) origins else &.{});
}

/// listDefs: each list with its items' values.
fn add_lists(lowered: *Lowered, builder: *ProgramBuilder) !void {
    assert(!lowered.root.is_none());
    const gpa = lowered.ir.gpa;
    var items: std.ArrayList(ProgramBuilder.ListItemDeclaration) = .empty;
    defer items.deinit(gpa);
    for (lowered.lists) |list| {
        items.clearRetainingCapacity();
        for (list.items) |item| try items.append(gpa, .{ .name = item.name, .value = item.value });
        _ = try builder.list_origin(list.name, items.items);
    }
}
