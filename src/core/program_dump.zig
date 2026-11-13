//! A readable listing of a `Program`, for debugging the loader, the compiler and
//! the VM. Containers are listed in index order, which is also the instruction layout, so the
//! dump is one pass with no recursion.
//!
//!   container 1 "knot" parent 0 depth 1 named visits
//!     0 text "Hello"
//!     1 divert plain -> 3:0

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("program.zig").Program;
const instruction_module = @import("instruction.zig");
const extra_module = @import("extra.zig");
const container_module = @import("container.zig");
const index = @import("index.zig");

pub fn dump(program: *const Program, writer: *std.Io.Writer) !void {
    assert(program.containers.len > 0);
    for (0..program.containers.len) |position| {
        try write_container(program, writer, .from_int(@intCast(position)));
    }
    try write_tables(program, writer);
    assert(program.instructions.len == program.instructions_count());
}

fn write_container(
    program: *const Program,
    writer: *std.Io.Writer,
    container: index.ContainerIndex,
) !void {
    const info = program.table().get(container);
    assert(info.instruction_count <= program.instructions.len);
    try writer.print("container {d} \"{s}\"", .{
        container.to_int(),
        program.strings.get(info.path),
    });
    if (!info.parent.is_none()) try writer.print(" parent {d}", .{info.parent.to_int()});
    try writer.print(" depth {d}", .{info.depth});
    if (info.index_in_parent == container_module.named_only and !info.parent.is_none()) {
        try writer.writeAll(" named");
    }
    if (info.flags.visits_counted) try writer.writeAll(" visits");
    if (info.flags.turns_counted) try writer.writeAll(" turns");
    if (info.flags.count_start_only) try writer.writeAll(" start_only");
    try writer.writeByte('\n');
    for (0..info.instruction_count) |position| {
        const item = program.instruction_at(container, @intCast(position));
        try writer.print("  {d} {t}", .{ position, item.opcode });
        try write_operand(program, writer, item);
        try writer.writeByte('\n');
    }
    assert(info.depth > 0 or container.to_int() == 0);
}

fn write_operand(
    program: *const Program,
    writer: *std.Io.Writer,
    item: instruction_module.Instruction,
) !void {
    const word = item.operand;
    assert(@backingInt(item.opcode) < 256);
    switch (instruction_module.operand_kind(item.opcode)) {
        .none => {},
        .string => {
            try writer.writeAll(" ");
            try std.json.Stringify.encodeJsonString(
                program.strings.get(@fromBackingInt(@intCast(word))),
                .{},
                writer,
            );
        },
        .container => try writer.print(" {d}", .{word}),
        .integer => try writer.print(" {d}", .{@as(i32, @bitCast(word))}),
        .float => try writer.print(" {d}", .{@as(f32, @bitCast(word))}),
        .boolean => try writer.print(" {}", .{word == 1}),
        .global => try writer.print(" {s}", .{program.strings.get(program.globals[word].name)}),
        .divert => try write_divert(program, writer, word),
        .choice_point => {
            const choice = record(instruction_module.ChoicePoint, program, word);
            try writer.print(" -> {d}:{d}", .{
                choice.target_container.to_int(),
                choice.target_index,
            });
            if (choice.flags.once_only) try writer.writeAll(" once");
            if (choice.flags.is_invisible_default) try writer.writeAll(" invisible");
        },
        .external_call => {
            const call = record(instruction_module.ExternalCall, program, word);
            const name = program.strings.get(program.externals[call.external.to_int()].name);
            try writer.print(" {s}/{d}", .{ name, call.arguments_count });
        },
        .variable_pointer => {
            const pointer = record(instruction_module.VariablePointer, program, word);
            try writer.print(" {s} context {d}", .{
                program.strings.get(pointer.name),
                pointer.context,
            });
        },
        .list => {
            const literal = record(instruction_module.ListLiteral, program, word);
            try writer.print(" items {d} origins {d}", .{
                literal.items_count,
                literal.origins_count,
            });
        },
    }
}

/// The extra record of type `T` at `at`.
fn record(comptime T: type, program: *const Program, at: u32) T {
    assert(at < program.extra.len);
    const result = extra_module.get(T, program.extra, at);
    assert(result.end <= program.extra.len);
    return result.data;
}

fn write_divert(program: *const Program, writer: *std.Io.Writer, at: u32) !void {
    const divert = extra_module.get(instruction_module.Divert, program.extra, at).data;
    assert(at < program.extra.len);
    try writer.print(" {t}", .{divert.flags.kind});
    if (divert.flags.conditional) try writer.writeAll(" if");
    if (divert.flags.variable) {
        try writer.print(" -> {s}", .{program.strings.get(divert.name)});
        return;
    }
    try writer.print(" -> {d}:{d}", .{ divert.target_container.to_int(), divert.target_index });
    assert(!divert.target_container.is_none());
}

fn write_tables(program: *const Program, writer: *std.Io.Writer) !void {
    assert(program.list_items.len < std.math.maxInt(u32));
    assert(program.externals.len < std.math.maxInt(u32));
    for (program.globals, 0..) |global, slot| {
        try writer.print("global {d} {s}\n", .{ slot, program.strings.get(global.name) });
    }
    for (program.list_items) |item| {
        try writer.print("list item {s} = {d}\n", .{
            program.strings.get(item.full_name),
            item.value,
        });
    }
    for (program.externals) |external| {
        try writer.print("external {s}", .{program.strings.get(external.name)});
        if (!external.fallback.is_none()) {
            try writer.print(" fallback {d}", .{external.fallback.to_int()});
        }
        try writer.writeByte('\n');
    }
    assert(program.globals.len < std.math.maxInt(u32));
}

test "dump snapshot of a small program" {
    // A stable listing: build a program with each operand family and
    // compare the dump with the expected text.
    const gpa = std.testing.allocator;
    const Builder = @import("program_builder.zig").ProgramBuilder;
    var builder = try Builder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("Hello \"you\""));
    try builder.add(.integer, -3);
    try builder.add(.global_get, try builder.global("mood"));
    try builder.add_divert("knot", .{ .kind = .tunnel, .conditional = true, .variable = false });
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
    try dump(&program, &output.writer);
    try std.testing.expectEqualStrings(
        \\container 0 "" depth 0
        \\  0 text "Hello \"you\""
        \\  1 integer -3
        \\  2 global_get mood
        \\  3 divert tunnel if -> 1:0
        \\container 1 "knot" parent 0 depth 1 named visits
        \\  0 choice_point -> 1:0 once
        \\  1 done
        \\global 0 mood
        \\
    , output.written());
}
