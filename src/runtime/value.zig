const std = @import("std");

pub const ControlCommand = enum {
    eval_start,
    eval_end,
    output,
    pop_eval_stack,
    duplicate,
    pop_function,
    pop_tunnel,
    begin_string,
    end_string,
    no_op,
    choice_count,
    turns_since,
    turn_index,
    visit_index,
    sequence_shuffle_index,
    seed_random,
    start_tag,
    end_tag,
    list_from_int,
    list_range,
    list_random,
    begin_thread,
    done,
    end_of_story,

    pub fn fromString(s: []const u8) ?ControlCommand {
        const map = std.StaticStringMap(ControlCommand).initComptime(.{
            .{ "ev", .eval_start },
            .{ "/ev", .eval_end },
            .{ "out", .output },
            .{ "pop", .pop_eval_stack },
            .{ "du", .duplicate },
            .{ "~ret", .pop_function },
            .{ "->->", .pop_tunnel },
            .{ "str", .begin_string },
            .{ "/str", .end_string },
            .{ "nop", .no_op },
            .{ "choiceCnt", .choice_count },
            .{ "turns", .turns_since },
            .{ "turn", .turn_index },
            .{ "visit", .visit_index },
            .{ "seq", .sequence_shuffle_index },
            .{ "srnd", .seed_random },
            .{ "#", .start_tag },
            .{ "/#", .end_tag },
            .{ "listInt", .list_from_int },
            .{ "range", .list_range },
            .{ "lrnd", .list_random },
            .{ "thread", .begin_thread },
            .{ "done", .done },
            .{ "end", .end_of_story },
        });
        return map.get(s);
    }
};

pub const NativeFunction = enum {
    add,
    subtract,
    multiply,
    divide,
    mod,
    negate,
    equal,
    not_equal,
    greater,
    less,
    greater_or_equal,
    less_or_equal,
    not,
    and_,
    or_,
    min,
    max,
    list_intersect,
    list_has,
    list_hasnt,
    int_cast,
    float_cast,
    floor,
    ceiling,

    pub fn fromString(s: []const u8) ?NativeFunction {
        const map = std.StaticStringMap(NativeFunction).initComptime(.{
            .{ "+", .add },
            .{ "-", .subtract },
            .{ "*", .multiply },
            .{ "/", .divide },
            .{ "%", .mod },
            .{ "_", .negate },
            .{ "==", .equal },
            .{ "!=", .not_equal },
            .{ ">", .greater },
            .{ "<", .less },
            .{ ">=", .greater_or_equal },
            .{ "<=", .less_or_equal },
            .{ "!", .not },
            .{ "&&", .and_ },
            .{ "||", .or_ },
            .{ "MIN", .min },
            .{ "MAX", .max },
            .{ "L^", .list_intersect },
            .{ "?", .list_has },
            .{ "!?", .list_hasnt },
            .{ "INT()", .int_cast },
            .{ "FLOAT()", .float_cast },
            .{ "FLOOR()", .floor },
            .{ "CEILING()", .ceiling },
        });
        return map.get(s);
    }
};

pub const PushPopType = enum { function, tunnel };

pub const Divert = struct {
    target: []const u8,
    is_variable: bool = false,
    is_conditional: bool = false,
    push_pop_type: ?PushPopType = null,
    external_args: u32 = 0,
};

/// Flags stored in the container's "#f" metadata field.
/// bit 0: visits_should_be_counted
/// bit 1: turn_index_should_be_counted
/// bit 2: count_at_start_only
pub const ContainerFlags = packed struct(u8) {
    visits_should_be_counted: bool = false,
    turn_index_should_be_counted: bool = false,
    count_at_start_only: bool = false,
    _pad: u5 = 0,
};

/// A container holds a sequence of RuntimeObjects plus optional named sub-containers.
/// Container and RuntimeObject are mutually recursive, so both live in this file.
pub const Container = struct {
    name: ?[]const u8 = null,
    content: []RuntimeObject = &.{},
    named_content: std.StringHashMapUnmanaged(*Container) = .{},
    flags: ContainerFlags = .{},
    path: []const u8 = "",
    parent: ?*Container = null,
    /// Index in parent.content; -1 if accessed only via named_content.
    index_in_parent: i32 = -1,
};

/// The RuntimeObject represents every possible value in the Ink virtual machine.
pub const RuntimeObject = union(enum) {
    void,
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    glue,
    /// Path string to a divert target: {"^->": "path"}
    divert_target: []const u8,
    variable_pointer: struct { name: []const u8, context_index: i32 },
    control_command: ControlCommand,
    native_function: NativeFunction,
    divert: Divert,
    choice_point: struct { path: []const u8, flags: u8 },
    variable_assignment: struct { name: []const u8, is_new_decl: bool, is_global: bool },
    variable_reference: struct { name: []const u8, path_for_count: ?[]const u8 },
    /// Stub for InkList — replaced in later task
    list: *anyopaque,
    container: *Container,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "ControlCommand.fromString" {
    try std.testing.expectEqual(ControlCommand.eval_start, ControlCommand.fromString("ev").?);
    try std.testing.expectEqual(ControlCommand.pop_tunnel, ControlCommand.fromString("->->").?);
    try std.testing.expectEqual(ControlCommand.choice_count, ControlCommand.fromString("choiceCnt").?);
    try std.testing.expectEqual(ControlCommand.seed_random, ControlCommand.fromString("srnd").?);
    try std.testing.expectEqual(ControlCommand.start_tag, ControlCommand.fromString("#").?);
    try std.testing.expectEqual(ControlCommand.done, ControlCommand.fromString("done").?);
    try std.testing.expectEqual(@as(?ControlCommand, null), ControlCommand.fromString("unknown"));
}

test "NativeFunction.fromString" {
    try std.testing.expectEqual(NativeFunction.add, NativeFunction.fromString("+").?);
    try std.testing.expectEqual(NativeFunction.list_intersect, NativeFunction.fromString("L^").?);
    try std.testing.expectEqual(NativeFunction.list_has, NativeFunction.fromString("?").?);
    try std.testing.expectEqual(NativeFunction.int_cast, NativeFunction.fromString("INT()").?);
    try std.testing.expectEqual(@as(?NativeFunction, null), NativeFunction.fromString("unknown"));
}

test "RuntimeObject variants" {
    const obj1: RuntimeObject = .void;
    try std.testing.expectEqual(std.meta.Tag(RuntimeObject).void, std.meta.activeTag(obj1));

    const obj2: RuntimeObject = .{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), obj2.int);

    const obj3: RuntimeObject = .{ .divert = .{
        .target = "knot",
        .is_variable = true,
        .is_conditional = false,
        .push_pop_type = .tunnel,
        .external_args = 2,
    } };
    try std.testing.expect(obj3.divert.is_variable);
    try std.testing.expectEqual(PushPopType.tunnel, obj3.divert.push_pop_type.?);

    const obj4: RuntimeObject = .{ .choice_point = .{ .path = "choice.0", .flags = 0x03 } };
    try std.testing.expectEqual(@as(u8, 0x03), obj4.choice_point.flags);
}

test "ContainerFlags" {
    const f3: ContainerFlags = @bitCast(@as(u8, 3));
    try std.testing.expect(f3.visits_should_be_counted);
    try std.testing.expect(f3.turn_index_should_be_counted);
    try std.testing.expect(!f3.count_at_start_only);

    const f0: ContainerFlags = @bitCast(@as(u8, 0));
    try std.testing.expect(!f0.visits_should_be_counted);
    try std.testing.expect(!f0.turn_index_should_be_counted);
    try std.testing.expect(!f0.count_at_start_only);
}
