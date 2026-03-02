const std = @import("std");
const lists = @import("lists.zig");
pub const InkList = lists.InkList;

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
    list_min,
    list_max,
    list_all,
    list_invert,
    list_count,
    list_value,
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
            .{ "LIST_MIN", .list_min },
            .{ "LIST_MAX", .list_max },
            .{ "LIST_ALL", .list_all },
            .{ "LIST_INVERT", .list_invert },
            .{ "LIST_COUNT", .list_count },
            .{ "LIST_VALUE", .list_value },
            .{ "INT()", .int_cast },
            .{ "INT", .int_cast },
            .{ "FLOAT()", .float_cast },
            .{ "FLOAT", .float_cast },
            .{ "FLOOR()", .floor },
            .{ "FLOOR", .floor },
            .{ "CEILING()", .ceiling },
            .{ "CEILING", .ceiling },
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
    /// An Ink list value; heap-allocated so the union remains copyable.
    list: *InkList,
    container: *Container,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "ControlCommand.fromString" {
    // All 24 command strings
    try std.testing.expectEqual(ControlCommand.eval_start, ControlCommand.fromString("ev").?);
    try std.testing.expectEqual(ControlCommand.eval_end, ControlCommand.fromString("/ev").?);
    try std.testing.expectEqual(ControlCommand.output, ControlCommand.fromString("out").?);
    try std.testing.expectEqual(ControlCommand.pop_eval_stack, ControlCommand.fromString("pop").?);
    try std.testing.expectEqual(ControlCommand.duplicate, ControlCommand.fromString("du").?);
    try std.testing.expectEqual(ControlCommand.pop_function, ControlCommand.fromString("~ret").?);
    try std.testing.expectEqual(ControlCommand.pop_tunnel, ControlCommand.fromString("->->").?);
    try std.testing.expectEqual(ControlCommand.begin_string, ControlCommand.fromString("str").?);
    try std.testing.expectEqual(ControlCommand.end_string, ControlCommand.fromString("/str").?);
    try std.testing.expectEqual(ControlCommand.no_op, ControlCommand.fromString("nop").?);
    try std.testing.expectEqual(ControlCommand.choice_count, ControlCommand.fromString("choiceCnt").?);
    try std.testing.expectEqual(ControlCommand.turns_since, ControlCommand.fromString("turns").?);
    try std.testing.expectEqual(ControlCommand.turn_index, ControlCommand.fromString("turn").?);
    try std.testing.expectEqual(ControlCommand.visit_index, ControlCommand.fromString("visit").?);
    try std.testing.expectEqual(ControlCommand.sequence_shuffle_index, ControlCommand.fromString("seq").?);
    try std.testing.expectEqual(ControlCommand.seed_random, ControlCommand.fromString("srnd").?);
    try std.testing.expectEqual(ControlCommand.start_tag, ControlCommand.fromString("#").?);
    try std.testing.expectEqual(ControlCommand.end_tag, ControlCommand.fromString("/#").?);
    try std.testing.expectEqual(ControlCommand.list_from_int, ControlCommand.fromString("listInt").?);
    try std.testing.expectEqual(ControlCommand.list_range, ControlCommand.fromString("range").?);
    try std.testing.expectEqual(ControlCommand.list_random, ControlCommand.fromString("lrnd").?);
    try std.testing.expectEqual(ControlCommand.begin_thread, ControlCommand.fromString("thread").?);
    try std.testing.expectEqual(ControlCommand.done, ControlCommand.fromString("done").?);
    try std.testing.expectEqual(ControlCommand.end_of_story, ControlCommand.fromString("end").?);
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
    // All variants can be created and their tag read
    const obj_void: RuntimeObject = .void;
    try std.testing.expectEqual(std.meta.Tag(RuntimeObject).void, std.meta.activeTag(obj_void));

    const obj_string: RuntimeObject = .{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", obj_string.string);

    const obj_int: RuntimeObject = .{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), obj_int.int);

    const obj_float: RuntimeObject = .{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), obj_float.float);

    const obj_bool: RuntimeObject = .{ .bool = true };
    try std.testing.expect(obj_bool.bool);

    const obj_glue: RuntimeObject = .glue;
    try std.testing.expectEqual(std.meta.Tag(RuntimeObject).glue, std.meta.activeTag(obj_glue));

    const obj_dt: RuntimeObject = .{ .divert_target = "knot.stitch" };
    try std.testing.expectEqualStrings("knot.stitch", obj_dt.divert_target);

    const obj_vp: RuntimeObject = .{ .variable_pointer = .{ .name = "x", .context_index = 1 } };
    try std.testing.expectEqualStrings("x", obj_vp.variable_pointer.name);
    try std.testing.expectEqual(@as(i32, 1), obj_vp.variable_pointer.context_index);

    const obj_cc: RuntimeObject = .{ .control_command = .done };
    try std.testing.expectEqual(ControlCommand.done, obj_cc.control_command);

    const obj_nf: RuntimeObject = .{ .native_function = .add };
    try std.testing.expectEqual(NativeFunction.add, obj_nf.native_function);

    const obj_div: RuntimeObject = .{ .divert = .{
        .target = "knot",
        .is_variable = true,
        .is_conditional = false,
        .push_pop_type = .tunnel,
        .external_args = 2,
    } };
    try std.testing.expect(obj_div.divert.is_variable);
    try std.testing.expectEqual(PushPopType.tunnel, obj_div.divert.push_pop_type.?);

    const obj_cp: RuntimeObject = .{ .choice_point = .{ .path = "choice.0", .flags = 0x03 } };
    try std.testing.expectEqual(@as(u8, 0x03), obj_cp.choice_point.flags);

    const obj_va: RuntimeObject = .{ .variable_assignment = .{ .name = "score", .is_new_decl = true, .is_global = true } };
    try std.testing.expectEqualStrings("score", obj_va.variable_assignment.name);
    try std.testing.expect(obj_va.variable_assignment.is_global);

    const obj_vr: RuntimeObject = .{ .variable_reference = .{ .name = "score", .path_for_count = null } };
    try std.testing.expectEqualStrings("score", obj_vr.variable_reference.name);
    try std.testing.expectEqual(@as(?[]const u8, null), obj_vr.variable_reference.path_for_count);

    var content = [_]RuntimeObject{.{ .int = 1 }};
    var c = Container{ .content = &content };
    const obj_container: RuntimeObject = .{ .container = &c };
    try std.testing.expectEqual(@as(usize, 1), obj_container.container.content.len);
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
