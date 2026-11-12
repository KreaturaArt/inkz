//! Instructions (plan §4.2, D1): a one-byte opcode and a 32-bit operand, stored as two SoA
//! arrays, so 5 bytes per instruction. Wider operands live in `extra` (see `extra.zig`), and
//! the operand is then their index.
//!
//! One ink content item is exactly one instruction (plan P2.1, constraint from P1.9): path
//! indices address a container's content, so the loader must keep the count equal.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("index.zig");
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;
const GlobalSlot = index.GlobalSlot;
const ExternalIndex = index.ExternalIndex;

pub const Opcode = enum(u8) {
    // Output and literal values.
    text,
    newline,
    glue,
    integer,
    float,
    bool,
    void,
    /// A divert-target value; divert targets point at containers (plan §4.3).
    divert_target,
    variable_pointer,
    list,
    /// A v20 tag literal, `{"#": "text"}`.
    tag,

    // Control commands (ink's ControlCommand.CommandType, in its order).
    eval_start,
    eval_output,
    eval_end,
    duplicate,
    pop,
    function_return,
    tunnel_return,
    string_start,
    string_end,
    nop,
    choice_count,
    turns,
    turns_since,
    read_count_of_target,
    random,
    seed_random,
    visit_index,
    sequence_shuffle_index,
    start_thread,
    done,
    end,
    list_from_int,
    list_range,
    list_random,
    tag_start,
    tag_end,

    // Native functions (ink's NativeFunctionCall names).
    add,
    subtract,
    divide,
    multiply,
    modulo,
    negate,
    equal,
    greater,
    less,
    greater_or_equal,
    less_or_equal,
    not_equal,
    not,
    @"and",
    @"or",
    min,
    max,
    pow,
    floor,
    ceiling,
    int,
    float_cast,
    has,
    hasnt,
    intersect,
    list_min,
    list_max,
    list_all,
    list_count,
    list_value,
    list_invert,

    // Flow.
    /// Falling into a nested container at this position.
    enter_container,
    divert,
    call_external,
    choice_point,

    // Variables and counts.
    global_get,
    temp_get,
    global_declare,
    global_assign,
    temp_declare,
    temp_assign,
    /// `{"CNT?": path}`: the visit count of a container.
    read_count,
};

comptime {
    assert(@sizeOf(Opcode) == 1);
    assert(@typeInfo(Opcode).@"enum".field_names.len < 256);
}

/// A typed index into `extra` for record `T`, so an operand can't be read as the wrong record.
pub fn ExtraIndex(comptime T: type) type {
    comptime assert(@typeInfo(T) == .@"struct");
    return enum(u32) {
        _,
        pub const Record = T;
    };
}

/// A position inside a container: a divert target or a choice target.
pub const Target = struct {
    container: ContainerIndex,
    /// The content index inside `container`; 0 is its start.
    index: u32,
};

pub const DivertKind = enum(u2) { plain, function, tunnel };

pub const DivertFlags = packed struct(u32) {
    kind: DivertKind,
    conditional: bool,
    /// The target is the divert target held in the variable `name`, not `target`.
    variable: bool,
    padding: u28 = 0,
};

pub const Divert = struct {
    target_container: ContainerIndex,
    target_index: u32,
    /// The variable holding the target, for `variable` diverts; otherwise `.none`.
    name: StringId,
    flags: DivertFlags,
};

pub const ExternalCall = struct {
    external: ExternalIndex,
    arguments_count: u32,
    conditional: bool,
};

pub const ChoiceFlags = packed struct(u32) {
    has_condition: bool,
    has_start_content: bool,
    has_choice_only_content: bool,
    is_invisible_default: bool,
    once_only: bool,
    padding: u27 = 0,
};

pub const ChoicePoint = struct {
    target_container: ContainerIndex,
    target_index: u32,
    flags: ChoiceFlags,
};

pub const VariablePointer = struct {
    name: StringId,
    /// ink's context index: -1 unknown, 0 global, n > 0 a call-stack frame.
    context: i32,
};

/// A list literal; `items_count` list item indices and then `origins_count` origin indices
/// follow it in `extra`.
pub const ListLiteral = struct {
    items_count: u32,
    origins_count: u32,
};

pub const OperandKind = enum {
    none,
    string,
    container,
    integer,
    float,
    boolean,
    global,
    divert,
    external_call,
    choice_point,
    variable_pointer,
    list,
};

/// What the operand of `opcode` means. The switch has no `else`, so a new opcode can't be
/// added without deciding its operand.
pub fn operand_kind(opcode: Opcode) OperandKind {
    assert(@backingInt(opcode) < @typeInfo(Opcode).@"enum".field_names.len);
    const kind: OperandKind = switch (opcode) {
        .text, .tag, .temp_get, .temp_declare, .temp_assign => .string,
        .divert_target, .enter_container, .read_count => .container,
        .integer => .integer,
        .float => .float,
        .bool => .boolean,
        .global_get, .global_declare, .global_assign => .global,
        .divert => .divert,
        .call_external => .external_call,
        .choice_point => .choice_point,
        .variable_pointer => .variable_pointer,
        .list => .list,
        .newline, .glue, .void => .none,
        .eval_start, .eval_output, .eval_end, .duplicate, .pop, .function_return => .none,
        .tunnel_return, .string_start, .string_end, .nop, .choice_count, .turns => .none,
        .turns_since, .read_count_of_target, .random, .seed_random, .visit_index => .none,
        .sequence_shuffle_index, .start_thread, .done, .end, .list_from_int => .none,
        .list_range, .list_random, .tag_start, .tag_end => .none,
        .add, .subtract, .divide, .multiply, .modulo, .negate, .equal, .greater => .none,
        .less, .greater_or_equal, .less_or_equal, .not_equal, .not, .@"and", .@"or" => .none,
        .min, .max, .pow, .floor, .ceiling, .int, .float_cast, .has, .hasnt => .none,
        .intersect, .list_min, .list_max, .list_all, .list_count, .list_value => .none,
        .list_invert => .none,
    };
    // Every opcode from `eval_start` on is a command, a native function or flow.
    if (@backingInt(opcode) >= @backingInt(Opcode.eval_start)) assert(kind != .integer);
    return kind;
}

/// The Zig type of an operand of kind `kind`.
pub fn Operand(comptime kind: OperandKind) type {
    return switch (kind) {
        .none => void,
        .string => StringId,
        .container => ContainerIndex,
        .integer => i32,
        .float => f32,
        .boolean => bool,
        .global => GlobalSlot,
        .divert => ExtraIndex(Divert),
        .external_call => ExtraIndex(ExternalCall),
        .choice_point => ExtraIndex(ChoicePoint),
        .variable_pointer => ExtraIndex(VariablePointer),
        .list => ExtraIndex(ListLiteral),
    };
}

/// The operand word for a typed operand.
fn word_of(comptime kind: OperandKind, operand: Operand(kind)) u32 {
    const word: u32 = switch (kind) {
        .none => 0,
        .integer, .float => @bitCast(operand),
        .boolean => @intFromBool(operand),
        else => @backingInt(operand),
    };
    if (kind == .boolean) assert(word <= 1);
    if (kind == .none) assert(word == 0);
    return word;
}

pub const Instruction = struct {
    opcode: Opcode,
    operand: u32,

    /// Builds an instruction from a typed operand (plan T13).
    pub fn init(comptime opcode: Opcode, operand: Operand(operand_kind(opcode))) Instruction {
        const kind = comptime operand_kind(opcode);
        const word = word_of(kind, operand);
        const instruction: Instruction = .{ .opcode = opcode, .operand = word };
        // Compare bits, not values: a NaN literal must round-trip too.
        assert(word_of(kind, instruction.get(opcode)) == word);
        assert(kind != .none or word == 0);
        return instruction;
    }

    /// The typed operand; `opcode` must be this instruction's opcode.
    pub fn get(instruction: Instruction, comptime opcode: Opcode) Operand(operand_kind(opcode)) {
        assert(instruction.opcode == opcode);
        const word = instruction.operand;
        return switch (comptime operand_kind(opcode)) {
            .none => {
                assert(word == 0);
            },
            .integer, .float => @bitCast(word),
            .boolean => boolean: {
                assert(word <= 1);
                break :boolean word == 1;
            },
            else => @fromBackingInt(@intCast(word)),
        };
    }
};

test "every opcode round-trips through its typed operand" {
    // Goal: encode and decode agree for every opcode (P2.1). Method: build a sample operand of
    // each opcode's kind, encode it, decode it and compare.
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Opcode).@"enum".field_names) |name| {
        const opcode = @field(Opcode, name);
        const kind = comptime operand_kind(opcode);
        const sample: Operand(kind) = switch (kind) {
            .none => {},
            .integer => -123456,
            .float => 2.5,
            .boolean => true,
            .string => StringId.from_int(7),
            .container => ContainerIndex.from_int(3),
            .global => GlobalSlot.from_int(1),
            else => @fromBackingInt(@intCast(42)),
        };
        const instruction = Instruction.init(opcode, sample);
        try std.testing.expectEqual(opcode, instruction.opcode);
        try std.testing.expectEqual(sample, instruction.get(opcode));
    }
}

test "integer and float operands keep their exact bits" {
    // Goal: i32 and f32 literals live in the operand (D14). Method: extremes and a NaN.
    const minimum = Instruction.init(.integer, std.math.minInt(i32));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), minimum.get(.integer));
    const nan = Instruction.init(.float, std.math.nan(f32));
    try std.testing.expect(std.math.isNan(nan.get(.float)));
    const tiny = Instruction.init(.float, std.math.floatTrueMin(f32));
    try std.testing.expectEqual(std.math.floatTrueMin(f32), tiny.get(.float));
}

test "packed flags fit one word" {
    // Goal: divert and choice flags are single extra words. Method: size checks.
    try std.testing.expectEqual(4, @sizeOf(DivertFlags));
    try std.testing.expectEqual(4, @sizeOf(ChoiceFlags));
}
