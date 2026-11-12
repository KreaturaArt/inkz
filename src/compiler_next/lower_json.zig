//! The laid-out IR as ink's JSON (ink's Runtime JsonSerialisation): containers as arrays
//! ending in their named-only content, `#f` and `#n` (or null), and paths as
//! Object.CompactPathString writes them (relative when shorter). Tests compare it with
//! inklecate's output; the Program serializer (P8.5) follows the same rules.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lower = @import("lower.zig");
const layout_module = @import("lower_layout.zig");
const ir_module = @import("lower_ir.zig");
const Lowering = lower.Lowering;
const Layout = layout_module.Layout;
const ContainerId = ir_module.ContainerId;
const ItemId = ir_module.ItemId;
const Item = ir_module.Item;
const Target = ir_module.Target;

const components_max = 64;

/// A runtime path as components (names, or positions as text).
const Components = struct {
    items: [components_max][]const u8 = undefined,
    count: u32 = 0,

    fn append(components: *Components, component: []const u8) !void {
        assert(components.count <= components_max);
        assert(component.len > 0);
        if (components.count == components_max) return error.PathTooDeep;
        components.items[components.count] = component;
        components.count += 1;
    }
};

const Writer = struct {
    lowering: *Lowering,
    layout: *const Layout,
    out: *std.Io.Writer,
    arena: Allocator,

    fn container_components(writer: *Writer, id: ContainerId, components: *Components) !void {
        assert(writer.lowering.results.len == writer.lowering.tree.count());
        assert(writer.layout.item_container.len == writer.layout.item_position.len);
        const ir = &writer.lowering.ir;
        var chain: [components_max]ContainerId = undefined;
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
            const text = ir.container(component).name orelse
                try std.fmt.allocPrint(
                    writer.arena,
                    "{d}",
                    .{writer.layout.container_position[component.to_int()]},
                );
            try components.append(text);
        }
    }

    fn target_components(writer: *Writer, target: Target, components: *Components) !void {
        assert(writer.lowering.results.len == writer.lowering.tree.count());
        assert(writer.layout.item_container.len == writer.layout.item_position.len);
        switch (target) {
            .none => {},
            .container => |id| try writer.container_components(id, components),
            .object => |object| {
                const id = writer.lowering.runtime_containers[object.to_int()];
                if (!id.is_none()) try writer.container_components(id, components);
            },
            .item => |item_id| try writer.item_components(item_id, components),
        }
    }

    fn item_components(writer: *Writer, item_id: ItemId, components: *Components) !void {
        assert(writer.lowering.results.len == writer.lowering.tree.count());
        assert(writer.layout.item_container.len == writer.layout.item_position.len);
        try writer.container_components(writer.layout.item_container[item_id.to_int()], components);
        const position = writer.layout.item_position[item_id.to_int()];
        try components.append(try std.fmt.allocPrint(writer.arena, "{d}", .{position}));
    }

    /// Object.CompactPathString from `from` to `target`.
    fn compact_path(writer: *Writer, from: ItemId, target: Target) ![]const u8 {
        assert(writer.lowering.results.len == writer.lowering.tree.count());
        assert(writer.layout.item_container.len == writer.layout.item_position.len);
        var own: Components = .{};
        try writer.item_components(from, &own);
        var other: Components = .{};
        try writer.target_components(target, &other);
        const global = try std.mem.join(writer.arena, ".", other.items[0..other.count]);
        var shared: i32 = -1;
        for (0..@min(own.count, other.count)) |position| {
            if (!std.mem.eql(u8, own.items[position], other.items[position])) break;
            shared = @intCast(position);
        }
        if (shared == -1) return global;
        var relative: std.ArrayList(u8) = .empty;
        const ups = @as(i32, @intCast(own.count)) - 1 - shared;
        for (0..@intCast(ups)) |_| try relative.appendSlice(writer.arena, ".^");
        for (other.items[@intCast(shared + 1)..other.count]) |component| {
            try relative.append(writer.arena, '.');
            try relative.appendSlice(writer.arena, component);
        }
        return if (relative.items.len < global.len) relative.items else global;
    }

    fn absolute_path(writer: *Writer, target: Target) ![]const u8 {
        assert(writer.lowering.results.len == writer.lowering.tree.count());
        assert(writer.layout.item_container.len == writer.layout.item_position.len);
        var components: Components = .{};
        try writer.target_components(target, &components);
        return std.mem.join(writer.arena, ".", components.items[0..components.count]);
    }
};

const Frame = struct {
    container: ContainerId,
    next: u32 = 0,
    next_named: ?u32 = null,
    without_name: bool,
};

/// Writes the story as ink's JSON.
pub fn write(lowering: *Lowering, layout: *const Layout, out: *std.Io.Writer) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    var arena_state: std.heap.ArenaAllocator = .init(lowering.gpa);
    defer arena_state.deinit();
    var writer: Writer = .{
        .lowering = lowering,
        .layout = layout,
        .out = out,
        .arena = arena_state.allocator(),
    };
    try out.writeAll("{\"inkVersion\":21,\"root\":");
    try write_containers(&writer);
    try out.writeAll(",\"listDefs\":{");
    try write_lists(&writer);
    try out.writeAll("}}");
}

fn write_containers(writer: *Writer) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const gpa = writer.lowering.gpa;
    const ir = &writer.lowering.ir;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    try frames.append(gpa, .{ .container = writer.lowering.root, .without_name = false });
    try writer.out.writeByte('[');
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        const container = ir.container(frame.container);
        if (frame.next_named == null and frame.next < container.content.items.len) {
            const item_id = container.content.items[frame.next];
            if (frame.next > 0) try writer.out.writeByte(',');
            frame.next += 1;
            const value = ir.item(item_id);
            if (value == .container) {
                try writer.out.writeByte('[');
                try frames.append(gpa, .{ .container = value.container, .without_name = false });
                continue;
            }
            try write_item(writer, item_id, value);
            continue;
        }
        if (try write_terminator(writer, frame)) |named| {
            try frames.append(gpa, .{ .container = named, .without_name = true });
            continue;
        }
        _ = frames.pop();
    }
}

/// The container's final element: `{named-only..., "#f": n, "#n": name}` or null, then `]`.
/// Returns a named-only child to write next (its array is opened).
fn write_terminator(writer: *Writer, frame: *Frame) !?ContainerId {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const ir = &writer.lowering.ir;
    const container = ir.container(frame.container);
    const flags = if (container.flags == ir_module.count_start_only) 0 else container.flags;
    const has_name = container.name != null and !frame.without_name;
    const has_terminator = container.named.items.len > 0 or flags > 0 or has_name;
    const out = writer.out;
    if (frame.next_named == null) {
        if (container.content.items.len > 0) try out.writeByte(',');
        if (!has_terminator) {
            try out.writeAll("null]");
            return null;
        }
        try out.writeByte('{');
        frame.next_named = 0;
    }
    const position = frame.next_named.?;
    if (position < container.named.items.len) {
        const named = container.named.items[position];
        if (position > 0) try out.writeByte(',');
        try std.json.Stringify.encodeJsonString(ir.container(named).name.?, .{}, out);
        try out.writeAll(":[");
        frame.next_named = position + 1;
        return named;
    }
    var separate = container.named.items.len > 0;
    if (flags > 0) {
        try out.print("{s}\"#f\":{d}", .{ if (separate) "," else "", flags });
        separate = true;
    }
    if (has_name) {
        try out.writeAll(if (separate) ",\"#n\":" else "\"#n\":");
        try std.json.Stringify.encodeJsonString(container.name.?, .{}, out);
    }
    try out.writeAll("}]");
    return null;
}

fn write_item(writer: *Writer, item_id: ItemId, value: Item) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const out = writer.out;
    switch (value) {
        .container => unreachable,
        .command => |command| try std.json.Stringify.encodeJsonString(command.word(), .{}, out),
        .native => |name| {
            const word = if (std.mem.eql(u8, name, "^")) "L^" else name;
            try std.json.Stringify.encodeJsonString(word, .{}, out);
        },
        .text => |text| {
            if (std.mem.eql(u8, text, "\n")) return out.writeAll("\"\\n\"");
            try std.json.Stringify.encodeJsonString(
                try std.fmt.allocPrint(writer.arena, "^{s}", .{text}),
                .{},
                out,
            );
        },
        .integer => |integer| try out.print("{d}", .{integer}),
        .float => |float| try write_float(out, float),
        .boolean => |boolean| try out.writeAll(if (boolean) "true" else "false"),
        .divert => |divert| try write_divert(writer, item_id, divert),
        .divert_target => |target| {
            try write_property(writer, "^->", try writer.absolute_path(target));
        },
        .read_count => |target| {
            try write_property(writer, "CNT?", try writer.compact_path(item_id, target));
        },
        .variable_reference => |name| try write_property(writer, "VAR?", name),
        .assignment => |assignment| {
            try write_property_open(
                writer,
                if (assignment.global) "VAR=" else "temp=",
                assignment.name,
            );
            if (!assignment.new) try out.writeAll(",\"re\":true");
            try out.writeByte('}');
        },
        .variable_pointer => |pointer| {
            try write_property_open(writer, "^var", pointer.name);
            try out.print(",\"ci\":{d}}}", .{pointer.context});
        },
        .choice_point => |choice| {
            try write_property_open(writer, "*", try writer.compact_path(item_id, choice.target));
            try out.print(",\"flg\":{d}}}", .{choice.flags});
        },
        .list => |list| try write_list_value(writer, list.items, list.origins),
    }
}

fn write_property_open(writer: *Writer, key: []const u8, value: []const u8) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(key.len > 0);
    try writer.out.writeByte('{');
    try std.json.Stringify.encodeJsonString(key, .{}, writer.out);
    try writer.out.writeByte(':');
    try std.json.Stringify.encodeJsonString(value, .{}, writer.out);
}

fn write_property(writer: *Writer, key: []const u8, value: []const u8) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    try write_property_open(writer, key, value);
    try writer.out.writeByte('}');
}

/// SimpleJson's float: invariant shortest form, with `.0` if it would read as an integer.
fn write_float(out: *std.Io.Writer, float: f32) !void {
    assert(!std.math.isNan(float));
    assert(@sizeOf(f32) == 4);
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{float});
    try out.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try out.writeAll(".0");
}

fn write_divert(writer: *Writer, item_id: ItemId, divert: ir_module.Divert) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const key = if (divert.external != null) "x()" else switch (divert.kind) {
        .plain => "->",
        .function => "f()",
        .tunnel => "->t->",
    };
    const target = divert.external orelse divert.variable orelse try writer.compact_path(
        item_id,
        divert.target,
    );
    try write_property_open(writer, key, target);
    if (divert.variable != null) try writer.out.writeAll(",\"var\":true");
    if (divert.conditional) try writer.out.writeAll(",\"c\":true");
    if (divert.external != null) try writer.out.print(
        ",\"exArgs\":{d}",
        .{divert.external_arguments},
    );
    try writer.out.writeByte('}');
}

fn write_list_value(
    writer: *Writer,
    items: []const ir_module.ListItem,
    origins: []const []const u8,
) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const out = writer.out;
    try out.writeAll("{\"list\":{");
    for (items, 0..) |item, position| {
        if (position > 0) try out.writeByte(',');
        try std.json.Stringify.encodeJsonString(try std.fmt.allocPrint(writer.arena, "{s}.{s}", .{
            item.origin,
            item.name,
        }), .{}, out);
        try out.print(":{d}", .{item.value});
    }
    try out.writeByte('}');
    if (items.len == 0 and origins.len > 0) {
        try out.writeAll(",\"origins\":[");
        for (origins, 0..) |origin, position| {
            if (position > 0) try out.writeByte(',');
            try std.json.Stringify.encodeJsonString(origin, .{}, out);
        }
        try out.writeByte(']');
    }
    try out.writeByte('}');
}

fn write_lists(writer: *Writer) !void {
    assert(writer.lowering.results.len == writer.lowering.tree.count());
    assert(writer.layout.item_container.len == writer.layout.item_position.len);
    const lowering = writer.lowering;
    for (lowering.resolution.lists, 0..) |definition, position| {
        if (position > 0) try writer.out.writeByte(',');
        try std.json.Stringify.encodeJsonString(
            lowering.child_name(lowering.tree.parent(definition), 0),
            .{},
            writer.out,
        );
        try writer.out.writeAll(":{");
        for (lowering.tree.children_of(definition), 0..) |element, index| {
            if (index > 0) try writer.out.writeByte(',');
            try std.json.Stringify.encodeJsonString(
                lowering.child_name(element, 0),
                .{},
                writer.out,
            );
            try writer.out.print(":{d}", .{lowering.resolution.item_values[element.to_int()]});
        }
        try writer.out.writeByte('}');
    }
}
