//! A Program as ink's JSON (plan §4.12, P8.5), as ink's Runtime JsonSerialisation writes a
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
const Allocator = std.mem.Allocator;
const Program = @import("program.zig").Program;
const index = @import("index.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const extra = @import("extra.zig");
const ContainerIndex = index.ContainerIndex;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;

const components_max = 64;

/// A runtime path: container names (or content positions), then maybe an item position.
const Components = struct {
    texts: [components_max][]const u8 = undefined,
    count: u32 = 0,

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
        assert(writer.program.containers.len > 0);
        assert(!id.is_none());
        return writer.program.strings.get(id);
    }

    fn container_components(
        writer: *Writer,
        container: ContainerIndex,
        components: *Components,
    ) !void {
        assert(writer.program.containers.len > 0);
        assert(writer.program.instructions.len < std.math.maxInt(u32));
        const program = writer.program;
        var chain: [components_max]ContainerIndex = undefined;
        var depth: u32 = 0;
        var current = container;
        while (!program.parent(current).is_none()) : (current = program.parent(current)) {
            if (depth == chain.len) return error.PathTooDeep;
            chain[depth] = current;
            depth += 1;
        }
        while (depth > 0) {
            depth -= 1;
            const link = chain[depth];
            const name = program.container_field(link, .name);
            if (!name.is_none()) {
                try components.append(writer.string(name));
            } else {
                const position = program.container_field(link, .index_in_parent);
                try components.append(try std.fmt.allocPrint(writer.arena, "{d}", .{position}));
            }
        }
    }

    fn target_components(
        writer: *Writer,
        container: ContainerIndex,
        position: u32,
        components: *Components,
    ) !void {
        assert(writer.program.containers.len > 0);
        assert(writer.program.instructions.len < std.math.maxInt(u32));
        try writer.container_components(container, components);
        if (position == 0) return;
        try components.append(try std.fmt.allocPrint(writer.arena, "{d}", .{position}));
    }

    /// Object.CompactPathString, from the item at (`from`, `from_position`).
    fn compact(
        writer: *Writer,
        from: ContainerIndex,
        from_position: u32,
        target: ContainerIndex,
        position: u32,
    ) ![]const u8 {
        assert(writer.program.containers.len > 0);
        assert(writer.program.instructions.len < std.math.maxInt(u32));
        var own: Components = .{};
        try writer.container_components(from, &own);
        try own.append(try std.fmt.allocPrint(writer.arena, "{d}", .{from_position}));
        var other: Components = .{};
        try writer.target_components(target, position, &other);
        const global = try std.mem.join(writer.arena, ".", other.texts[0..other.count]);
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

    fn absolute(writer: *Writer, target: ContainerIndex, position: u32) ![]const u8 {
        assert(writer.program.containers.len > 0);
        assert(writer.program.instructions.len < std.math.maxInt(u32));
        var components: Components = .{};
        try writer.target_components(target, position, &components);
        return std.mem.join(writer.arena, ".", components.texts[0..components.count]);
    }

    fn json_string(writer: *Writer, text: []const u8) !void {
        assert(writer.program.containers.len > 0);
        assert(text.len < std.math.maxInt(u32));
        try std.json.Stringify.encodeJsonString(text, .{}, writer.out);
    }

    fn property(writer: *Writer, key: []const u8, value: []const u8) !void {
        assert(writer.program.containers.len > 0);
        assert(key.len > 0);
        try writer.out.writeByte('{');
        try writer.json_string(key);
        try writer.out.writeByte(':');
        try writer.json_string(value);
    }
};

/// Writes `program` as ink's JSON.
pub fn serialize(gpa: Allocator, program: *const Program, out: *std.Io.Writer) !void {
    assert(program.instructions.len < std.math.maxInt(u32));
    assert(program.containers.len > 0);
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
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    try frames.append(gpa, .{ .container = Program.root, .without_name = false });
    try writer.out.writeByte('[');
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        const count = program.content_count(frame.container);
        if (frame.next_named == null and frame.next < count) {
            const position = frame.next;
            if (position > 0) try writer.out.writeByte(',');
            frame.next += 1;
            const instruction = program.instruction_at(frame.container, position);
            if (instruction.opcode == .enter_container) {
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
    assert(program.containers.len > 0);
    assert(program.instructions.len < std.math.maxInt(u32));
    const first = program.container_field(container, .named_first);
    const count = program.container_field(container, .named_count);
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
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    const out = writer.out;
    const container = frame.container;
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

/// The JSON word of a bare instruction (ink_json's word table, read backwards).
fn word(opcode: Opcode) ?[]const u8 {
    assert(@backingInt(opcode) < @typeInfo(Opcode).@"enum".field_names.len);
    assert(@backingInt(opcode) < @typeInfo(Opcode).@"enum".field_names.len);
    return switch (opcode) {
        .eval_start => "ev",
        .eval_output => "out",
        .eval_end => "/ev",
        .duplicate => "du",
        .pop => "pop",
        .function_return => "~ret",
        .tunnel_return => "->->",
        .string_start => "str",
        .string_end => "/str",
        .nop => "nop",
        .choice_count => "choiceCnt",
        .turns => "turn",
        .turns_since => "turns",
        .read_count_of_target => "readc",
        .random => "rnd",
        .seed_random => "srnd",
        .visit_index => "visit",
        .sequence_shuffle_index => "seq",
        .start_thread => "thread",
        .done => "done",
        .end => "end",
        .list_from_int => "listInt",
        .list_range => "range",
        .list_random => "lrnd",
        .tag_start => "#",
        .tag_end => "/#",
        .glue => "<>",
        .void => "void",
        else => native_word(opcode),
    };
}

fn native_word(opcode: Opcode) ?[]const u8 {
    assert(@backingInt(opcode) < @typeInfo(Opcode).@"enum".field_names.len);
    assert(@backingInt(opcode) < @typeInfo(Opcode).@"enum".field_names.len);
    return switch (opcode) {
        .add => "+",
        .subtract => "-",
        .divide => "/",
        .multiply => "*",
        .modulo => "%",
        .negate => "_",
        .equal => "==",
        .greater => ">",
        .less => "<",
        .greater_or_equal => ">=",
        .less_or_equal => "<=",
        .not_equal => "!=",
        .not => "!",
        .@"and" => "&&",
        .@"or" => "||",
        .min => "MIN",
        .max => "MAX",
        .pow => "POW",
        .floor => "FLOOR",
        .ceiling => "CEILING",
        .int => "INT",
        .float_cast => "FLOAT",
        .has => "?",
        .hasnt => "!?",
        .intersect => "L^",
        .list_min => "LIST_MIN",
        .list_max => "LIST_MAX",
        .list_all => "LIST_ALL",
        .list_count => "LIST_COUNT",
        .list_value => "LIST_VALUE",
        .list_invert => "LIST_INVERT",
        else => null,
    };
}

fn write_instruction(
    writer: *Writer,
    container: ContainerIndex,
    position: u32,
    instruction: Instruction,
) !void {
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const out = writer.out;
    if (word(instruction.opcode)) |text| return writer.json_string(text);
    switch (instruction.opcode) {
        .text => {
            const text = writer.string(instruction.get(.text));
            try writer.json_string(try std.fmt.allocPrint(writer.arena, "^{s}", .{text}));
        },
        .newline => try out.writeAll("\"\\n\""),
        .integer => try out.print("{d}", .{instruction.get(.integer)}),
        .float => try write_float(out, instruction.get(.float)),
        .bool => try out.writeAll(if (instruction.get(.bool)) "true" else "false"),
        .tag => {
            try writer.property("#", writer.string(instruction.get(.tag)));
            try out.writeByte('}');
        },
        else => try write_operand_instruction(writer, container, position, instruction),
    }
}

fn write_operand_instruction(
    writer: *Writer,
    container: ContainerIndex,
    position: u32,
    instruction: Instruction,
) !void {
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    const out = writer.out;
    switch (instruction.opcode) {
        .divert_target => {
            try writer.property("^->", try writer.absolute(instruction.get(.divert_target), 0));
            try out.writeByte('}');
        },
        .read_count => {
            try writer.property(
                "CNT?",
                try writer.compact(container, position, instruction.get(.read_count), 0),
            );
            try out.writeByte('}');
        },
        .global_get, .global_declare, .global_assign => {
            const slot: index.GlobalSlot = @fromBackingInt(@intCast(instruction.operand));
            const key = if (instruction.opcode == .global_get) "VAR?" else "VAR=";
            const reassigned = instruction.opcode == .global_assign;
            try write_variable(writer, key, global_name(writer, slot), reassigned);
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
            if (call.conditional) try out.writeAll(",\"c\":true");
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
    assert(instruction.operand < program.extra.len);
    assert(@typeInfo(T) == .@"struct");
    return extra.get(T, program.extra, instruction.operand).data;
}

fn global_name(writer: *const Writer, slot: index.GlobalSlot) []const u8 {
    assert(writer.program.containers.len > 0);
    assert(slot.to_int() < writer.program.globals.len);
    return writer.string(writer.program.globals[slot.to_int()].name);
}

fn write_variable(writer: *Writer, key: []const u8, name: []const u8, reassignment: bool) !void {
    assert(writer.program.containers.len > 0);
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
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    const out = writer.out;
    const divert = record(instruction_module.Divert, program, instruction);
    const key = switch (divert.flags.kind) {
        .plain => "->",
        .function => "f()",
        .tunnel => "->t->",
    };
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
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    const out = writer.out;
    const decoded = extra.get(instruction_module.ListLiteral, program.extra, at);
    const literal = decoded.data;
    if (literal.items_count == 1 and literal.origins_count == 1) {
        // A list item read as a variable: ink's `VAR?` with the name as written.
        const name: index.StringId = @fromBackingInt(@intCast(program.extra[decoded.end + 2]));
        try writer.property("VAR?", writer.string(name));
        return out.writeByte('}');
    }
    try out.writeAll("{\"list\":{");
    for (0..literal.items_count) |position| {
        const item = program.list_items[program.extra[decoded.end + position]];
        if (position > 0) try out.writeByte(',');
        try writer.json_string(writer.string(item.full_name));
        try out.print(":{d}", .{item.value});
    }
    try out.writeByte('}');
    if (literal.items_count == 0 and literal.origins_count > 0) {
        try out.writeAll(",\"origins\":[");
        for (0..literal.origins_count) |position| {
            const at_origin = decoded.end + literal.items_count + @as(u32, @intCast(position));
            const origin = program.list_origins[program.extra[at_origin]];
            if (position > 0) try out.writeByte(',');
            try writer.json_string(writer.string(origin.name));
        }
        try out.writeByte(']');
    }
    try out.writeByte('}');
}

/// SimpleJson's float: invariant shortest form, with `.0` if it would read as an integer.
fn write_float(out: *std.Io.Writer, float: f32) !void {
    assert(@sizeOf(@TypeOf(float)) == 4);
    assert(!std.math.isNan(float));
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{float});
    try out.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try out.writeAll(".0");
}

fn write_lists(writer: *Writer) !void {
    assert(writer.program.containers.len > 0);
    assert(writer.program.instructions.len < std.math.maxInt(u32));
    const program = writer.program;
    for (program.list_origins, 0..) |origin, position| {
        if (position > 0) try writer.out.writeByte(',');
        try writer.json_string(writer.string(origin.name));
        try writer.out.writeAll(":{");
        const first = origin.items_first.to_int();
        for (program.list_items[first..][0..origin.items_count], 0..) |item, at| {
            if (at > 0) try writer.out.writeByte(',');
            try writer.json_string(writer.string(item.name));
            try writer.out.print(":{d}", .{item.value});
        }
        try writer.out.writeByte('}');
    }
}
