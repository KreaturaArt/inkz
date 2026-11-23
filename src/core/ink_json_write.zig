//! A Program as ink's JSON, as ink's Runtime JsonSerialisation writes a
//! story: each container an array of its content, ending in a dictionary of its named-only
//! children, `#f` and `#n` (or null); paths as Object.CompactPathString writes them (relative
//! when shorter), except divert-target values, which ink writes absolute. Iterative over the
//! container tree.
//!
//! A program target is a (container, index) pair. ink targets a container (its start) except
//! for the rejoin points of conditionals and sequences, which are never at index 0, so index
//! 0 writes the container's path and any other index the item's.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("profile.zig");
const Allocator = std.mem.Allocator;
const Program = @import("program.zig").Program;
const index = @import("index.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const extra = @import("extra.zig");
const ink_json = @import("ink_json.zig");
const dotnet_float = @import("dotnet_float.zig");
const ContainerIndex = index.ContainerIndex;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;

const components_max = 64;

/// A runtime path split at its dots: container names (or content positions), then maybe an
/// item position.
const Components = struct {
    texts: [components_max][]const u8 = undefined,
    count: u32 = 0,

    fn split(path: []const u8) !Components {
        var components: Components = .{};
        if (path.len == 0) return components;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |text| try components.append(text);
        return components;
    }

    fn append(components: *Components, text: []const u8) !void {
        assert(components.count <= components_max);
        assert(text.len > 0);
        if (components.count == components_max) return error.PathTooDeep;
        components.texts[components.count] = text;
        components.count += 1;
    }
};

const Writer = struct {
    program: *const Program,
    out: *std.Io.Writer,
    arena: Allocator,

    fn string(writer: *const Writer, id: index.StringId) []const u8 {
        return writer.program.strings.get(id);
    }

    /// The absolute path of item `position` of `container`, or of the container itself at
    /// 0: the container's stored path, then the position.
    fn absolute(writer: *Writer, container: ContainerIndex, position: u32) ![]const u8 {
        // A target is an item of the container or its end (a rejoin point).
        assert(position <= writer.program.content_count(container));
        const path = writer.string(writer.program.container_field(container, .path));
        if (position == 0) return path;
        const separator: []const u8 = if (path.len > 0) "." else "";
        return std.fmt.allocPrint(writer.arena, "{s}{s}{d}", .{ path, separator, position });
    }

    /// Object.CompactPathString, from the item at (`from`, `from_position`).
    fn compact(
        writer: *Writer,
        from: ContainerIndex,
        from_position: u32,
        target: ContainerIndex,
        position: u32,
    ) ![]const u8 {
        assert(from_position < writer.program.content_count(from));
        const from_path = writer.program.container_field(from, .path);
        var own: Components = try .split(writer.string(from_path));
        try own.append(try std.fmt.allocPrint(writer.arena, "{d}", .{from_position}));
        const global = try writer.absolute(target, position);
        const other: Components = try .split(global);
        var shared: ?u32 = null;
        for (0..@min(own.count, other.count)) |at| {
            if (!std.mem.eql(u8, own.texts[at], other.texts[at])) break;
            shared = @intCast(at);
        }
        const last_shared = shared orelse return global;
        var relative: std.ArrayList(u8) = .empty;
        for (0..own.count - 1 - last_shared) |_| try relative.appendSlice(writer.arena, ".^");
        for (other.texts[last_shared + 1 .. other.count]) |text| {
            try relative.append(writer.arena, '.');
            try relative.appendSlice(writer.arena, text);
        }
        return if (relative.items.len < global.len) relative.items else global;
    }

    fn json_string(writer: *Writer, text: []const u8) !void {
        try std.json.Stringify.encodeJsonString(text, .{}, writer.out);
    }

    fn property(writer: *Writer, key: []const u8, value: []const u8) !void {
        assert(key.len > 0);
        try writer.out.writeByte('{');
        try writer.json_string(key);
        try writer.out.writeByte(':');
        try writer.json_string(value);
    }

    /// `{"key":"value"}`
    fn object(writer: *Writer, key: []const u8, value: []const u8) !void {
        try writer.property(key, value);
        try writer.out.writeByte('}');
    }
};

/// Writes `program` as ink's JSON.
pub fn serialize(gpa: Allocator, program: *const Program, out: *std.Io.Writer) !void {
    const profile_zone = profile.begin(.json_serialize);
    defer profile_zone.end();
    // The writers start at the root container and index instructions with u32.
    assert(program.containers.len > 0);
    assert(program.instructions.len < std.math.maxInt(u32));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var writer: Writer = .{ .program = program, .out = out, .arena = arena_state.allocator() };
    try out.print("{{\"inkVersion\":{d},\"root\":", .{program.ink_version});
    try write_containers(&writer, gpa);
    try out.writeAll(",\"listDefs\":{");
    try write_lists(&writer);
    try out.writeAll("}}");
}

const Frame = struct {
    container: ContainerIndex,
    next: u32 = 0,
    next_named: ?u32 = null,
    without_name: bool,
};

fn write_containers(writer: *Writer, gpa: Allocator) !void {
    const program = writer.program;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    try frames.append(gpa, .{ .container = Program.root, .without_name = false });
    try writer.out.writeByte('[');
    while (frames.items.len > 0) {
        // Each container is on the stack at most once (the containers form a tree).
        assert(frames.items.len <= program.containers.len);
        const frame = &frames.items[frames.items.len - 1];
        const count = program.content_count(frame.container);
        if (frame.next_named == null and frame.next < count) {
            const position = frame.next;
            if (position > 0) try writer.out.writeByte(',');
            frame.next += 1;
            const instruction = program.instruction_at(frame.container, position);
            if (instruction.opcode == .enter_container) {
                assert(program.parent(instruction.get(.enter_container)) == frame.container);
                try writer.out.writeByte('[');
                try frames.append(gpa, .{
                    .container = instruction.get(.enter_container),
                    .without_name = false,
                });
                continue;
            }
            try write_instruction(writer, frame.container, position, instruction);
            continue;
        }
        if (try write_terminator(writer, frame)) |named| {
            try frames.append(gpa, .{ .container = named, .without_name = true });
            continue;
        }
        _ = frames.pop();
    }
}

/// The named-only children of a container, in order.
fn named_only(program: *const Program, container: ContainerIndex, position: u32) ?ContainerIndex {
    const first = program.container_field(container, .named_first);
    const count = program.container_field(container, .named_count);
    assert(first + count <= program.named.len);
    var seen: u32 = 0;
    for (program.named[first..][0..count]) |entry| {
        const in_parent = program.container_field(entry.child, .index_in_parent);
        if (in_parent != container_module.named_only) continue;
        if (seen == position) return entry.child;
        seen += 1;
    }
    return null;
}

/// Container.countFlags: start-only alone serves no purpose, so ink drops it.
fn count_flags(flags: container_module.ContainerFlags) u8 {
    assert(@sizeOf(container_module.ContainerFlags) == 1);
    const bits: u8 = @bitCast(flags);
    assert(bits <= 7);
    return if (bits == 4) 0 else bits;
}

/// The final element and the closing bracket; returns a named-only child to write next.
fn write_terminator(writer: *Writer, frame: *Frame) !?ContainerIndex {
    const program = writer.program;
    const out = writer.out;
    const container = frame.container;
    // The terminator follows the container's content.
    assert(frame.next == program.content_count(container));
    const flags = count_flags(program.container_field(container, .flags));
    const name = program.container_field(container, .name);
    const has_name = !name.is_none() and !frame.without_name;
    const has_named = named_only(program, container, 0) != null;
    if (frame.next_named == null) {
        if (program.content_count(container) > 0) try out.writeByte(',');
        if (!has_named and flags == 0 and !has_name) {
            try out.writeAll("null]");
            return null;
        }
        try out.writeByte('{');
        frame.next_named = 0;
    }
    const position = frame.next_named.?;
    if (named_only(program, container, position)) |child| {
        if (position > 0) try out.writeByte(',');
        try writer.json_string(writer.string(program.container_field(child, .name)));
        try out.writeAll(":[");
        frame.next_named = position + 1;
        return child;
    }
    var separate = has_named;
    if (flags > 0) {
        try out.print("{s}\"#f\":{d}", .{ if (separate) "," else "", flags });
        separate = true;
    }
    if (has_name) {
        try out.writeAll(if (separate) ",\"#n\":" else "\"#n\":");
        try writer.json_string(writer.string(name));
    }
    try out.writeAll("}]");
    return null;
}

/// The JSON word of each bare instruction: ink_json's word table, read backwards.
const opcode_words = table: {
    var table: [@typeInfo(Opcode).@"enum".field_names.len]?[]const u8 = @splat(null);
    for (ink_json.words.keys(), ink_json.words.values()) |key, opcode| {
        assert(table[@backingInt(opcode)] == null);
        table[@backingInt(opcode)] = key;
    }
    break :table table;
};

fn write_instruction(
    writer: *Writer,
    container: ContainerIndex,
    position: u32,
    instruction: Instruction,
) !void {
    const out = writer.out;
    // write_containers opens nested containers itself.
    assert(instruction.opcode != .enter_container);
    if (opcode_words[@backingInt(instruction.opcode)]) |text| return writer.json_string(text);
    switch (instruction.opcode) {
        .text => {
            const text = writer.string(instruction.get(.text));
            try writer.json_string(try std.fmt.allocPrint(writer.arena, "^{s}", .{text}));
        },
        .newline => try out.writeAll("\"\\n\""),
        .integer => try out.print("{d}", .{instruction.get(.integer)}),
        .float => try dotnet_float.write_json(out, instruction.get(.float)),
        .bool => try out.writeAll(if (instruction.get(.bool)) "true" else "false"),
        .tag => try writer.object("#", writer.string(instruction.get(.tag))),
        else => try write_operand_instruction(writer, container, position, instruction),
    }
}

fn write_operand_instruction(
    writer: *Writer,
    container: ContainerIndex,
    position: u32,
    instruction: Instruction,
) !void {
    const program = writer.program;
    const out = writer.out;
    switch (instruction.opcode) {
        .divert_target => try writer.object(
            "^->",
            try writer.absolute(instruction.get(.divert_target), 0),
        ),
        .read_count => try writer.object(
            "CNT?",
            try writer.compact(container, position, instruction.get(.read_count), 0),
        ),
        .global_get, .global_declare, .global_assign => {
            const slot: index.GlobalSlot = @fromBackingInt(@intCast(instruction.operand));
            const key = if (instruction.opcode == .global_get) "VAR?" else "VAR=";
            const reassigned = instruction.opcode == .global_assign;
            try write_variable(writer, key, global_name(writer, slot), reassigned);
        },
        .temp_assign_written_global => {
            const name = writer.string(@fromBackingInt(@intCast(instruction.operand)));
            try write_variable(writer, "VAR=", name, true);
        },
        .temp_get, .temp_declare, .temp_assign => {
            const name = writer.string(@fromBackingInt(@intCast(instruction.operand)));
            const key = if (instruction.opcode == .temp_get) "VAR?" else "temp=";
            try write_variable(writer, key, name, instruction.opcode == .temp_assign);
        },
        .variable_pointer => {
            const pointer = record(instruction_module.VariablePointer, program, instruction);
            try writer.property("^var", writer.string(pointer.name));
            try out.print(",\"ci\":{d}}}", .{pointer.context});
        },
        .divert => try write_divert(writer, container, position, instruction),
        .call_external => {
            const call = record(instruction_module.ExternalCall, program, instruction);
            try writer.property(
                "x()",
                writer.string(program.externals[call.external.to_int()].name),
            );
            if (call.flags.conditional) try out.writeAll(",\"c\":true");
            if (call.arguments_count > 0) try out.print(",\"exArgs\":{d}", .{call.arguments_count});
            try out.writeByte('}');
        },
        .choice_point => {
            const choice = record(instruction_module.ChoicePoint, program, instruction);
            const path = try writer.compact(
                container,
                position,
                choice.target_container,
                choice.target_index,
            );
            try writer.property("*", path);
            try out.print(",\"flg\":{d}}}", .{@as(u32, @bitCast(choice.flags))});
        },
        .list => try write_list(writer, @backingInt(instruction.get(.list))),
        else => unreachable,
    }
}

/// An instruction's record in `extra` (its operand is the record's index).
fn record(comptime T: type, program: *const Program, instruction: Instruction) T {
    return extra.get(T, program.extra, instruction.operand);
}

fn global_name(writer: *const Writer, slot: index.GlobalSlot) []const u8 {
    return writer.string(writer.program.globals[slot.to_int()].name);
}

fn write_variable(writer: *Writer, key: []const u8, name: []const u8, reassignment: bool) !void {
    assert(name.len > 0);
    try writer.property(key, name);
    if (reassignment) try writer.out.writeAll(",\"re\":true");
    try writer.out.writeByte('}');
}

fn write_divert(
    writer: *Writer,
    container: ContainerIndex,
    position: u32,
    instruction: Instruction,
) !void {
    const program = writer.program;
    const out = writer.out;
    const divert = record(instruction_module.Divert, program, instruction);
    const key = switch (divert.flags.kind) {
        .plain => "->",
        .function => "f()",
        .tunnel => "->t->",
    };
    if (!divert.flags.variable) assert(!divert.target_container.is_none());
    const target = if (divert.flags.variable)
        writer.string(divert.name)
    else
        try writer.compact(container, position, divert.target_container, divert.target_index);
    try writer.property(key, target);
    if (divert.flags.variable) try out.writeAll(",\"var\":true");
    if (divert.flags.conditional) try out.writeAll(",\"c\":true");
    try out.writeByte('}');
}

/// `{"list": {"origin.item": value, ...}}`, with `origins` for an empty list.
fn write_list(writer: *Writer, at: u32) !void {
    const program = writer.program;
    const out = writer.out;
    const literal = extra.get(instruction_module.ListLiteral, program.extra, at);
    const tail_at = at + extra.words(instruction_module.ListLiteral);
    // The record is followed by its item indices, its origin indices and (for a list item
    // read as a variable) the name.
    assert(tail_at + literal.items_count + literal.origins_count <= program.extra.len);
    if (literal.items_count == 1 and literal.origins_count == 1) {
        // A list item read as a variable: ink's `VAR?` with the name as written.
        assert(tail_at + 2 < program.extra.len);
        const name: index.StringId = @fromBackingInt(@intCast(program.extra[tail_at + 2]));
        return writer.object("VAR?", writer.string(name));
    }
    try out.writeAll("{\"list\":{");
    for (0..literal.items_count) |position| {
        const item = program.list_items[program.extra[tail_at + position]];
        if (position > 0) try out.writeByte(',');
        try writer.json_string(writer.string(item.full_name));
        try out.print(":{d}", .{item.value});
    }
    try out.writeByte('}');
    if (literal.items_count == 0 and literal.origins_count > 0) {
        try out.writeAll(",\"origins\":[");
        for (0..literal.origins_count) |position| {
            const at_origin = tail_at + literal.items_count + @as(u32, @intCast(position));
            const origin = program.list_origins[program.extra[at_origin]];
            if (position > 0) try out.writeByte(',');
            try writer.json_string(writer.string(origin.name));
        }
        try out.writeByte(']');
    }
    try out.writeByte('}');
}

fn write_lists(writer: *Writer) !void {
    const program = writer.program;
    for (program.list_origins, 0..) |origin, position| {
        if (position > 0) try writer.out.writeByte(',');
        try writer.json_string(writer.string(origin.name));
        try writer.out.writeAll(":{");
        const first = origin.items_first.to_int();
        assert(first + origin.items_count <= program.list_items.len);
        for (program.list_items[first..][0..origin.items_count], 0..) |item, at| {
            if (at > 0) try writer.out.writeByte(',');
            try writer.json_string(writer.string(item.name));
            try writer.out.print(":{d}", .{item.value});
        }
        try writer.out.writeByte('}');
    }
}

test "a built program with each kind of operand writes as ink's JSON" {
    // Strings with escapes, an integer, a global, a conditional tunnel divert, a named-only
    // child with a counting flag and a once-only choice point, each in ink's spelling.
    const gpa = std.testing.allocator;
    const Builder = @import("program_builder.zig").ProgramBuilder;
    var builder = try Builder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("Hello \"you\""));
    try builder.add(.integer, -3);
    try builder.add(.global_get, try builder.global("mood"));
    try builder.add_divert("knot", .{ .kind = .tunnel, .conditional = true });
    const counted: container_module.ContainerFlags = .{ .visits_counted = true };
    _ = try builder.begin_container(.{ .name = "knot", .named_only = true, .flags = counted });
    try builder.add_choice_point(".^", .{
        .has_condition = false,
        .has_start_content = true,
        .has_choice_only_content = false,
        .is_invisible_default = false,
        .once_only = true,
    });
    try builder.add(.done, {});
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try serialize(gpa, &program, &output.writer);
    try std.testing.expectEqualStrings(
        \\{"inkVersion":21,"root":["^Hello \"you\"",-3,{"VAR?":"mood"},
    ++
        \\{"->t->":"knot","c":true},{"knot":[{"*":".^","flg":18},"done",{"#f":1}]}],
    ++
        \\"listDefs":{}}
    , output.written());
}
