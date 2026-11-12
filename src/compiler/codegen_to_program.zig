//! The old codegen's CContainer tree to a Program (plan P8.0, D16), so the old front end feeds
//! the new VM until the new compiler's lowering (P8.4) replaces this. It makes the same
//! ProgramBuilder calls that loading the serializer's JSON would (src/core/ink_json.zig),
//! in the same order, without the JSON: content items in order, then the container's name,
//! flags and named children, as the JSON's final dictionary lists them.
//!
//! Two deliberate differences, both where the old codegen strays from ink's format:
//! - the serializer writes `{"f(N)": name}` for a call with arguments; here every call is
//!   ink's `{"f()": name}` (the arguments are on the evaluation stack either way);
//! - in a tunnel chain (`-> t -> DONE`) the codegen emits a divert to `DONE` or `END`, which
//!   ink compiles (and the codegen elsewhere lowers) to the `done` and `end` commands; here
//!   they are lowered too.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const codegen = @import("codegen.zig");
const Parsed = @import("parsed.zig");
const parser = @import("parser.zig");
const ink_json = @import("../core/ink_json.zig");
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const CContainer = codegen.CContainer;
const CObject = codegen.CObject;

/// The serializer's ink version.
const ink_version = 21;
/// Containers nest at most this deep (ink_json's bound).
const depth_max = ink_json.depth_max;

pub const Error = ink_json.Error || error{TooDeep};

/// Compiles `source` with the old front end into a Program for the new VM. The program is
/// the caller's (`Program.deinit(gpa)`).
pub fn compile(gpa: Allocator, source: []const u8) !Program {
    assert(source.len < std.math.maxInt(u32));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed_story = try parser.parse(arena.allocator(), source);
    const root = try codegen.generate(arena.allocator(), parsed_story);
    const program = try convert(gpa, root, parsed_story.list_defs);
    assert(program.containers.len > 0);
    return program;
}

/// One container being added: where its content and named children are up to.
const Frame = struct {
    container: *const CContainer,
    next_content: u32 = 0,
    /// Null while the content is being added; then the next named child.
    next_named: ?u32 = null,
};

/// Converts the tree rooted at `root`, with `list_definitions`, to a Program.
pub fn convert(
    gpa: Allocator,
    root: *const CContainer,
    list_definitions: []const Parsed.ListDef,
) !Program {
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    builder.ink_version = ink_version;
    var frames: [depth_max]Frame = undefined;
    var depth: u32 = 1;
    frames[0] = .{ .container = root };
    _ = try builder.begin_container(.{});
    var steps: u64 = 0;
    while (depth > 0) : (steps += 1) {
        assert(steps < std.math.maxInt(u32));
        const frame = &frames[depth - 1];
        const child = try step(&builder, frame) orelse {
            try builder.end_container();
            depth -= 1;
            continue;
        };
        if (depth == depth_max) return error.TooDeep;
        frames[depth] = .{ .container = child };
        depth += 1;
    }
    try add_list_definitions(&builder, gpa, list_definitions);
    var program = try builder.finish();
    errdefer program.deinit(gpa);
    assert(program.ink_version == ink_version);
    return program;
}

/// Adds the frame's next item. Returns a child container that was begun (to fill next), or
/// null when the frame's container is complete.
fn step(builder: *ProgramBuilder, frame: *Frame) !?*const CContainer {
    const container = frame.container;
    assert(frame.next_content <= container.content.len);
    if (frame.next_named == null) {
        while (frame.next_content < container.content.len) {
            const object = container.content[frame.next_content];
            frame.next_content += 1;
            if (object == .container) {
                _ = try builder.begin_container(.{});
                return object.container;
            }
            try add_object(builder, object);
        }
        // The final dictionary: "#n", "#f", then the named children.
        if (container.own_name) |name| try builder.set_name(name);
        if (container.flags != 0) builder.set_flags(@bitCast(@as(u8, @intCast(container.flags))));
        frame.next_named = 0;
    }
    const position = frame.next_named.?;
    assert(position <= container.named_children.len);
    if (position == container.named_children.len) return null;
    frame.next_named = position + 1;
    const named = container.named_children[position];
    _ = try builder.begin_container(.{ .name = named.name, .named_only = true });
    return named.container;
}

/// One non-container content item, as ink_json would load the serializer's JSON for it.
fn add_object(builder: *ProgramBuilder, object: CObject) !void {
    assert(object != .container);
    assert(builder.frames.items.len > 0);
    switch (object) {
        .container => unreachable,
        .text => |text| try builder.add(.text, try builder.intern(text)),
        .newline => try builder.add(.newline, {}),
        .string => |word| try ink_json.add_word_to(builder, word),
        .done => try ink_json.add_word_to(builder, "done"),
        .end => try ink_json.add_word_to(builder, "end"),
        .tunnel_return => try ink_json.add_word_to(builder, "->->"),
        .glue => try ink_json.add_word_to(builder, "<>"),
        .eval_start => try ink_json.add_word_to(builder, "ev"),
        .eval_end => try ink_json.add_word_to(builder, "/ev"),
        .eval_output => try ink_json.add_word_to(builder, "out"),
        .pop => try ink_json.add_word_to(builder, "pop"),
        .void_ => try ink_json.add_word_to(builder, "void"),
        .nop => try ink_json.add_word_to(builder, "nop"),
        .dup => try ink_json.add_word_to(builder, "du"),
        .func_return => try ink_json.add_word_to(builder, "~ret"),
        .int => |value| {
            const narrow = std.math.cast(i32, value) orelse return error.IntegerOutOfRange;
            try builder.add(.integer, narrow);
        },
        .float => |value| try builder.add(.float, @as(f32, @floatCast(value))),
        .bool_ => |value| try builder.add(.bool, value),
        else => try add_object_with_operand(builder, object),
    }
}

fn add_object_with_operand(builder: *ProgramBuilder, object: CObject) !void {
    assert(object != .container);
    assert(builder.frames.items.len > 0);
    switch (object) {
        .divert => |target| {
            if (std.mem.eql(u8, target, "DONE")) return ink_json.add_word_to(builder, "done");
            if (std.mem.eql(u8, target, "END")) return ink_json.add_word_to(builder, "end");
            try divert(builder, .{ .key = "->", .target = target });
        },
        .cond_divert => |target| try divert(builder, .{
            .key = "->",
            .target = target,
            .conditional = true,
        }),
        .divert_via_var => |name| try divert(builder, .{
            .key = "->",
            .target = name,
            .variable = true,
        }),
        .tunnel_divert => |target| try divert(builder, .{ .key = "->t->", .target = target }),
        .tunnel_divert_via_var => |name| try divert(builder, .{
            .key = "->t->",
            .target = name,
            .variable = true,
        }),
        .function_call => |call| try divert(builder, .{
            .key = "f()",
            .target = call.name,
            .variable = call.is_var,
        }),
        .external_call => |call| try divert(builder, .{
            .key = "x()",
            .target = call.name,
            .external_arguments = call.arg_count,
        }),
        else => try add_value_object(builder, object),
    }
}

fn divert(builder: *ProgramBuilder, object: ink_json.DivertObject) !void {
    assert(object.target.len > 0);
    assert(object.key.len > 0);
    try ink_json.add_divert_object_to(builder, object);
}

fn add_value_object(builder: *ProgramBuilder, object: CObject) !void {
    assert(object != .container);
    assert(builder.frames.items.len > 0);
    switch (object) {
        .var_assign => |assign| {
            if (!assign.is_new) return builder.add_variable_assign(assign.name);
            try builder.add(.global_declare, try builder.global(assign.name));
        },
        .temp_assign => |assign| {
            const name = try builder.intern(assign.name);
            if (assign.is_new) return builder.add(.temp_declare, name);
            try builder.add(.temp_assign, name);
        },
        .var_ref => |name| try builder.add_variable_get(name),
        .var_pointer => |pointer| try ink_json.add_variable_pointer_to(
            builder,
            pointer.name,
            pointer.context_idx,
        ),
        .choice_point => |choice| {
            // Five flag bits, as the loader accepts.
            if (std.math.cast(u5, choice.flags) == null) return error.InvalidInkJson;
            try builder.add_choice_point(choice.path, @bitCast(choice.flags));
        },
        .divert_target_val => |path| try builder.add_container_operand(.divert_target, path),
        .read_count => |path| try builder.add_container_operand(.read_count, path),
        .list_val => |list| try add_list_value(builder, list.entries, list.origins),
        else => unreachable,
    }
}

fn add_list_value(
    builder: *ProgramBuilder,
    entries: []const codegen.ListValEntry,
    origins: []const []const u8,
) !void {
    assert(entries.len < std.math.maxInt(u16));
    var names: [256][]const u8 = undefined;
    if (entries.len > names.len) return error.InvalidInkJson;
    for (entries, 0..) |entry, position| names[position] = entry.key;
    // The serializer writes the origins only for an empty list.
    const written_origins = if (entries.len == 0) origins else &.{};
    try builder.add_list_literal(names[0..entries.len], written_origins);
    assert(builder.frames.items.len > 0);
}

/// `listDefs`, as the serializer writes them (an item without a value is 0).
fn add_list_definitions(
    builder: *ProgramBuilder,
    gpa: Allocator,
    list_definitions: []const Parsed.ListDef,
) !void {
    assert(builder.frames.items.len == 0);
    var items: std.ArrayList(ProgramBuilder.ListItemDeclaration) = .empty;
    defer items.deinit(gpa);
    for (list_definitions) |definition| {
        items.clearRetainingCapacity();
        for (definition.items) |item| {
            try items.append(gpa, .{ .name = item.name, .value = item.value orelse 0 });
        }
        _ = try builder.list_origin(definition.name, items.items);
    }
    assert(items.items.len <= std.math.maxInt(u32));
}

// Tests.

const serializer = @import("serializer.zig");

/// Whether two programs are the same, field by field.
fn expect_same_program(expected: *const Program, actual: *const Program) !void {
    const testing = std.testing;
    assert(expected.containers.len > 0);
    assert(actual.containers.len > 0);
    try testing.expectEqualSlices(u8, expected.strings.strings.bytes, actual.strings.strings.bytes);
    try testing.expectEqualSlices(u32, expected.strings.strings.ends, actual.strings.strings.ends);
    try expect_same_columns(expected.instructions, actual.instructions);
    try expect_same_columns(expected.containers, actual.containers);
    try testing.expectEqualSlices(u32, expected.extra, actual.extra);
    inline for (.{ "named", "globals", "list_origins", "list_items", "externals" }) |field| {
        const left = @field(expected, field);
        const right = @field(actual, field);
        try testing.expectEqual(left.len, right.len);
        for (left, right) |a, b| try testing.expect(std.meta.eql(a, b));
    }
    try testing.expectEqual(expected.global_declaration, actual.global_declaration);
    try testing.expectEqual(expected.count_slots_count, actual.count_slots_count);
}

fn expect_same_columns(expected: anytype, actual: @TypeOf(expected)) !void {
    comptime assert(@TypeOf(expected) == @TypeOf(actual));
    assert(expected.len < std.math.maxInt(u32));
    try std.testing.expectEqual(expected.len, actual.len);
    const Item = @TypeOf(expected.get(0));
    inline for (comptime std.meta.fieldNames(Item)) |name| {
        const column = @field(std.meta.FieldEnum(Item), name);
        for (expected.items(column), actual.items(column)) |a, b| {
            try std.testing.expect(std.meta.eql(a, b));
        }
    }
}

fn expect_same_as_json(source: []const u8) !void {
    assert(source.len < std.math.maxInt(u32));
    const gpa = std.testing.allocator;
    assert(source.len > 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed_story = try parser.parse(arena.allocator(), source);
    const root = try codegen.generate(arena.allocator(), parsed_story);
    const json = try serializer.serializeWithListDefs(gpa, root, parsed_story.list_defs);
    defer gpa.free(json);
    var from_json = try ink_json.load(gpa, json);
    defer from_json.deinit(gpa);
    var direct = try convert(gpa, root, parsed_story.list_defs);
    defer direct.deinit(gpa);
    try expect_same_program(&from_json, &direct);
}

test "codegen_to_program: the same program as loading the serializer's JSON" {
    // Goal: P8.0's adapter makes the loader's calls. Method: sources covering text, glue,
    // tags, choices, gathers, diverts, tunnels, threads, variables, temps, lists,
    // conditionals, sequences and functions compile to identical programs both ways.
    const sources = [_][]const u8{
        "Hello, world.\n",
        "VAR x = 5\nCONST c = 2\n~ temp t = x + c\nValue {t} <> glued # tag\n",
        "LIST colours = red, (green), blue\n{colours} {LIST_COUNT(colours)}\n",
        "{x > 3: big|small} {&a|b|c}\nVAR x = 1\n",
        "* [One] -> one\n* Two\n- gathered\n-> DONE\n== one ==\nOne.\n-> END\n",
        "-> tunnel -> other\n== tunnel ==\nIn the tunnel.\n->->\n== other ==\nOther.\n-> END\n",
        "<- threaded\n-> DONE\n== threaded ==\n* Threaded choice\n-> DONE\n",
        "~ x = f()\n{x}\nVAR x = 0\n== function f ==\n~ return 1.5\n",
    };
    for (sources) |source| {
        expect_same_as_json(source) catch |err| {
            std.debug.print("source: {s}\n", .{source});
            return err;
        };
    }
}

test "codegen_to_program: a tunnel chain ending in DONE gets the done command" {
    // Goal: the documented DONE lowering. Method: the program loads (the JSON route can't
    // resolve the DONE path) and has a done instruction.
    const gpa = std.testing.allocator;
    var program = try compile(gpa, "-> tunnel -> DONE\n== tunnel ==\nIn the tunnel.\n->->\n");
    defer program.deinit(gpa);
    const opcodes = program.instructions.items(.opcode);
    try std.testing.expect(std.mem.indexOfScalar(@TypeOf(opcodes[0]), opcodes, .done) != null);
    try std.testing.expect(program.containers.len > 1);
}

test "codegen_to_program: a call with arguments uses ink's f()" {
    // Goal: the documented difference from the serializer's f(N) key. Method: the program has
    // one function divert to f, and it runs on the loader's terms (finish resolves it).
    const gpa = std.testing.allocator;
    var program = try compile(gpa, "{f(1, 2)}\n== function f(a, b) ==\n~ return a + b\n");
    defer program.deinit(gpa);
    var functions: u32 = 0;
    for (program.instructions.items(.opcode)) |opcode| {
        if (opcode == .divert) functions += 1;
    }
    try std.testing.expect(functions >= 1);
    try std.testing.expect(program.containers.len > 2);
}
