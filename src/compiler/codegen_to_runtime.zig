/// Direct CContainer → Container[] conversion, bypassing JSON serialization.
/// Mirrors json_loader.buildContainer but accepts CContainer instead of std.json.Value.
/// Used by compiler.compileToStory for in-process compilation without a JSON round-trip.
const std = @import("std");
const codegen = @import("codegen.zig");
const CContainer = codegen.CContainer;
const CObject = codegen.CObject;
const Parsed = @import("parsed.zig");
const value = @import("../runtime/value.zig");
const lists = @import("../runtime/lists.zig");

const Container = value.Container;
const RuntimeObject = value.RuntimeObject;
const ControlCommand = value.ControlCommand;
const NativeFunction = value.NativeFunction;
const ContainerFlags = value.ContainerFlags;
const NamedEntry = value.NamedEntry;
const null_container_idx = value.null_container_idx;

pub const ConvertResult = struct {
    containers: []Container,
    named_entries: []NamedEntry,
};

/// Convert a CContainer tree to a flat Container[] + NamedEntry[] pair.
/// All allocations use `arena`. Output is structurally identical to json_loader.loadStory.
pub fn convert(arena: std.mem.Allocator, root: *const CContainer) !ConvertResult {
    var containers = std.ArrayList(Container).empty;
    var named_entries = std.ArrayList(NamedEntry).empty;
    _ = try buildContainer(arena, root, &containers, &named_entries, null_container_idx, null, "");
    return ConvertResult{
        .containers = try containers.toOwnedSlice(arena),
        .named_entries = try named_entries.toOwnedSlice(arena),
    };
}

/// Build a ListDefinitionsOrigin directly from parsed list defs (no JSON round-trip).
pub fn buildListDefs(arena: std.mem.Allocator, list_defs: []const Parsed.ListDef) !lists.ListDefinitionsOrigin {
    var origin = lists.ListDefinitionsOrigin{};
    for (list_defs) |ld| {
        var def = lists.ListDefinition{ .name = ld.name };
        for (ld.items) |item| {
            try def.items.put(arena, item.name, item.value orelse 0);
        }
        try origin.definitions.put(arena, ld.name, def);
    }
    return origin;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Recursively build a Container into the flat arrays, returning its index.
/// Logic mirrors json_loader.buildContainer exactly (same path/index conventions).
fn buildContainer(
    arena: std.mem.Allocator,
    cc: *const CContainer,
    containers: *std.ArrayList(Container),
    named_entries: *std.ArrayList(NamedEntry),
    parent_idx: u32,
    container_name: ?[]const u8,
    path: []const u8,
) !u32 {
    // Reserve my slot up front so recursive children get higher indices.
    const my_idx: u32 = @intCast(containers.items.len);
    try containers.append(arena, undefined);

    const flags: ContainerFlags = @bitCast(@as(u8, @truncate(cc.flags)));
    const name: ?[]const u8 = container_name orelse cc.own_name;

    // Build content items. Inline container CObjects are recursed into.
    var content = try std.ArrayList(RuntimeObject).initCapacity(arena, cc.content.len);
    for (cc.content) |obj| {
        const rt_obj: RuntimeObject = switch (obj) {
            .container => |child_cc| blk: {
                // child_path uses positional index (same as json_loader).
                const item_idx = content.items.len;
                const child_path = if (path.len > 0)
                    try std.fmt.allocPrint(arena, "{s}.{}", .{ path, item_idx })
                else
                    try std.fmt.allocPrint(arena, "{}", .{item_idx});
                const child_idx = try buildContainer(
                    arena, child_cc, containers, named_entries, my_idx, null, child_path,
                );
                break :blk RuntimeObject{ .container = child_idx };
            },
            else => try convertCObject(arena, obj),
        };
        try content.append(arena, rt_obj);
    }

    // Fix index_in_parent and path for inline containers that have a name (#n).
    for (content.items, 0..) |rt_obj, item_idx| {
        if (rt_obj != .container) continue;
        const child_idx = rt_obj.container;
        containers.items[child_idx].index_in_parent = @intCast(item_idx);
        if (containers.items[child_idx].name) |cname| {
            containers.items[child_idx].path = if (path.len > 0)
                try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, cname })
            else
                try arena.dupe(u8, cname);
        }
    }

    // Process named children from CContainer.named_children (JSON metadata object entries).
    var meta_named = std.ArrayList(NamedEntry).empty;
    for (cc.named_children) |nc| {
        const child_path = if (path.len > 0)
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, nc.name })
        else
            try arena.dupe(u8, nc.name);
        const child_idx = try buildContainer(
            arena, nc.container, containers, named_entries, my_idx, nc.name, child_path,
        );
        try meta_named.append(arena, .{ .name = nc.name, .container_idx = child_idx });
    }

    // Post-order: add named_entries for this container AFTER all descendants.
    const first_named: u32 = @intCast(named_entries.items.len);
    for (content.items) |rt_obj| {
        if (rt_obj != .container) continue;
        const child_idx = rt_obj.container;
        if (containers.items[child_idx].name) |cname| {
            try named_entries.append(arena, .{ .name = cname, .container_idx = child_idx });
        }
    }
    for (meta_named.items) |e| {
        try named_entries.append(arena, e);
    }
    const named_len: u32 = @as(u32, @intCast(named_entries.items.len)) - first_named;

    containers.items[my_idx] = Container{
        .name = name,
        .content = try content.toOwnedSlice(arena),
        .first_named = first_named,
        .named_len = named_len,
        .flags = flags,
        .path = path,
        .parent_idx = parent_idx,
        .index_in_parent = -1,
    };

    return my_idx;
}

/// Convert a non-container CObject to a RuntimeObject.
fn convertCObject(arena: std.mem.Allocator, obj: CObject) !RuntimeObject {
    return switch (obj) {
        .text => |t| .{ .string = t },
        .newline => .{ .string = "\n" },
        .done => .{ .control_command = .done },
        .end => .{ .control_command = .end_of_story },
        .tunnel_return => .{ .control_command = .pop_tunnel },
        .glue => .glue,
        .divert => |t| .{ .divert = .{ .target = t } },
        .tunnel_divert => |t| .{ .divert = .{ .target = t, .push_pop_type = .tunnel } },
        .tunnel_divert_via_var => |n| .{ .divert = .{
            .target = n, .is_variable = true, .push_pop_type = .tunnel,
        } },
        .container => unreachable, // handled in buildContainer
        .eval_start => .{ .control_command = .eval_start },
        .eval_end => .{ .control_command = .eval_end },
        .eval_output => .{ .control_command = .output },
        .pop => .{ .control_command = .pop_eval_stack },
        .void_ => .void,
        .nop => .{ .control_command = .no_op },
        .int => |n| .{ .int = n },
        .float => |f| .{ .float = f },
        .bool_ => |b| .{ .bool = b },
        // CObject.string is a bare JSON-style string: may be a control command, native
        // function, or a plain string literal. Mirror json_loader.parseStringObject.
        .string => |s| convertString(s),
        .var_assign => |va| .{ .variable_assignment = .{
            .name = va.name, .is_new_decl = va.is_new, .is_global = true,
        } },
        .var_ref => |n| .{ .variable_reference = .{ .name = n, .path_for_count = null } },
        .var_pointer => |vp| .{ .variable_pointer = .{
            .name = vp.name, .context_index = vp.context_idx,
        } },
        .temp_assign => |ta| .{ .variable_assignment = .{
            .name = ta.name, .is_new_decl = ta.is_new, .is_global = false,
        } },
        .cond_divert => |p| .{ .divert = .{ .target = p, .is_conditional = true } },
        .dup => .{ .control_command = .duplicate },
        .choice_point => |cp| .{ .choice_point = .{
            .path = cp.path, .flags = @intCast(cp.flags),
        } },
        .divert_target_val => |p| .{ .divert_target = p },
        .divert_via_var => |n| .{ .divert = .{ .target = n, .is_variable = true } },
        .read_count => |p| .{ .variable_reference = .{
            .name = "", .path_for_count = p,
        } },
        .func_return => .{ .control_command = .pop_function },
        .function_call => |fc| .{ .divert = .{
            .target = fc.name, .is_variable = fc.is_var, .push_pop_type = .function,
        } },
        .external_call => |ec| .{ .divert = .{
            .target = ec.name, .push_pop_type = .function, .external_args = ec.arg_count,
        } },
        .list_val => |lv| blk: {
            const ink_list = try arena.create(value.InkList);
            ink_list.* = .{};
            for (lv.entries) |e| {
                try ink_list.items.put(arena, e.key, e.value);
            }
            ink_list.origins = lv.origins;
            break :blk RuntimeObject{ .list = ink_list };
        },
    };
}

/// CObject.string → RuntimeObject. Mirrors json_loader.parseStringObject.
fn convertString(s: []const u8) RuntimeObject {
    if (std.mem.eql(u8, s, "\n")) return .{ .string = "\n" };
    if (std.mem.eql(u8, s, "<>")) return .glue;
    if (std.mem.eql(u8, s, "void")) return .void;
    if (ControlCommand.fromString(s)) |cmd| return .{ .control_command = cmd };
    if (NativeFunction.fromString(s)) |func| return .{ .native_function = func };
    return .{ .string = s };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "buildListDefs empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const origin = try buildListDefs(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), origin.definitions.count());
}

test "buildListDefs with items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const defs = [_]Parsed.ListDef{.{
        .name = "colours",
        .items = @constCast(&[_]Parsed.ListItem{
            .{ .name = "red", .value = 1 },
            .{ .name = "green", .value = 2 },
            .{ .name = "blue", .value = 3 },
        }),
    }};
    const origin = try buildListDefs(arena.allocator(), &defs);
    const def = origin.get("colours") orelse return error.MissingDef;
    try std.testing.expectEqual(@as(?i32, 1), def.valueForItem("red"));
    try std.testing.expectEqual(@as(?i32, 3), def.valueForItem("blue"));
    try std.testing.expectEqual(@as(?[]const u8, null), def.itemForValue(99));
}

test "convert hello world matches json_loader" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const parser = @import("parser.zig");
    const src = "Hello world\n";
    const parsed = try parser.parse(aa, src);
    const root = try codegen.generate(aa, parsed);

    const result = try convert(aa, root);

    // Root container has 2 items: inner container + done
    try std.testing.expectEqual(@as(usize, 2), result.containers[0].content.len);
    try std.testing.expect(result.containers[0].content[0] == .container);
    try std.testing.expectEqual(
        ControlCommand.done,
        result.containers[0].content[1].control_command,
    );

    // Inner container starts with "Hello world" text
    const inner_idx = result.containers[0].content[0].container;
    try std.testing.expectEqualStrings("Hello world", result.containers[inner_idx].content[0].string);
    try std.testing.expectEqualStrings("\n", result.containers[inner_idx].content[1].string);
}

test "convert hello world path assignment" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const parser = @import("parser.zig");
    const parsed = try parser.parse(aa, "Hello world\n");
    const root = try codegen.generate(aa, parsed);
    const result = try convert(aa, root);

    // Root path is ""
    try std.testing.expectEqualStrings("", result.containers[0].path);
    try std.testing.expectEqual(null_container_idx, result.containers[0].parent_idx);

    // Inner container at content[0] has positional path "0"
    const inner_idx = result.containers[0].content[0].container;
    try std.testing.expectEqualStrings("0", result.containers[inner_idx].path);
    try std.testing.expectEqual(@as(u32, 0), result.containers[inner_idx].parent_idx);

    // Named child "g-0" inside inner has path "0.g-0"
    const inner = &result.containers[inner_idx];
    var g0_idx: ?u32 = null;
    for (result.named_entries[inner.first_named .. inner.first_named + inner.named_len]) |e| {
        if (std.mem.eql(u8, e.name, "g-0")) g0_idx = e.container_idx;
    }
    const g0 = &result.containers[g0_idx orelse return error.MissingG0];
    try std.testing.expectEqualStrings("0.g-0", g0.path);
}
