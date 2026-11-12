//! ink's expression rules (InkParser_Expressions.cs): precedence climbing over ink's infix
//! operators (with ink's precedences and registration order), unary operators, calls,
//! variable references, list literals, numbers, strings and divert targets.

const std = @import("std");
const assert = std.debug.assert;
const grammar = @import("grammar.zig");
const ast = @import("ast.zig");
const Machine = grammar.Machine;
const Frame = grammar.Frame;
const Action = grammar.Action;
const Error = grammar.Error;

const Operator = struct {
    text: []const u8,
    precedence: u32,
    require_whitespace: bool = false,
    tag: ast.Tag,
};

/// RegisterExpressionOperators, in order: the first match wins.
const operators = [_]Operator{
    .{ .text = "&&", .precedence = 1, .tag = .@"and" },
    .{ .text = "||", .precedence = 1, .tag = .@"or" },
    .{ .text = "and", .precedence = 1, .require_whitespace = true, .tag = .@"and" },
    .{ .text = "or", .precedence = 1, .require_whitespace = true, .tag = .@"or" },
    .{ .text = "==", .precedence = 2, .tag = .equal },
    .{ .text = ">=", .precedence = 2, .tag = .greater_equal },
    .{ .text = "<=", .precedence = 2, .tag = .less_equal },
    .{ .text = "<", .precedence = 2, .tag = .less },
    .{ .text = ">", .precedence = 2, .tag = .greater },
    .{ .text = "!=", .precedence = 2, .tag = .not_equal },
    .{ .text = "?", .precedence = 3, .tag = .has },
    .{ .text = "has", .precedence = 3, .require_whitespace = true, .tag = .has },
    .{ .text = "!?", .precedence = 3, .tag = .hasnt },
    .{ .text = "hasnt", .precedence = 3, .require_whitespace = true, .tag = .hasnt },
    .{ .text = "^", .precedence = 3, .tag = .intersect },
    .{ .text = "+", .precedence = 4, .tag = .add },
    .{ .text = "-", .precedence = 5, .tag = .subtract },
    .{ .text = "*", .precedence = 6, .tag = .multiply },
    .{ .text = "/", .precedence = 7, .tag = .divide },
    .{ .text = "%", .precedence = 8, .tag = .modulo },
    .{ .text = "mod", .precedence = 8, .require_whitespace = true, .tag = .modulo },
};

/// ParseInfixOperator: the index of the operator at the input, consumed.
fn infix_operator(machine: *Machine) ?u32 {
    assert(machine.tokenizer.at <= machine.source.len);
    const start = grammar.at(machine);
    for (operators, 0..) |operator, position| {
        if (!grammar.parse_string(machine, operator.text)) continue;
        if (operator.require_whitespace and !grammar.whitespace(machine)) {
            machine.tokenizer.at = start;
            continue;
        }
        return @intCast(position);
    }
    assert(grammar.at(machine) == start);
    return null;
}

/// Expression(minimumPrecedence): the argument is the minimum precedence; locals are it,
/// the marker and the pending operator.
pub fn expression(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression);
    assert(machine.tokenizer.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            frame.locals[0] = machine.argument;
            frame.locals[1] = machine.scratch_count;
            _ = grammar.whitespace(machine);
            frame.phase = 1;
            return .{ .call = .expression_unary };
        },
        1 => {
            if (machine.outcome == .failed) return .fail;
            _ = grammar.whitespace(machine);
            return infix(machine, frame);
        },
        else => {
            if (machine.outcome == .failed) {
                grammar.report_expected(machine, .right_operand);
                return .fail;
            }
            try machine.wrap(operators[frame.locals[2]].tag, frame.locals[1]);
            return infix(machine, frame);
        },
    }
}

fn infix(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(frame.rule == .expression);
    const start = grammar.at(machine);
    if (infix_operator(machine)) |position| {
        if (operators[position].precedence > frame.locals[0]) {
            frame.locals[2] = position;
            frame.phase = 2;
            _ = grammar.whitespace(machine);
            machine.argument = operators[position].precedence;
            return .{ .call = .expression };
        }
        machine.tokenizer.at = start;
    }
    _ = grammar.whitespace(machine);
    return .succeed;
}

/// ExpressionUnary: a divert target, or prefix operators and an operand, then `++`/`--`.
/// locals: the marker and 1 + the prefix tag (0 if none).
pub fn expression_unary(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_unary);
    assert(machine.tokenizer.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            frame.locals[0] = machine.scratch_count;
            frame.phase = 1;
            return .{ .call = .expression_divert_target };
        },
        1 => {
            if (machine.outcome == .succeeded) return .succeed;
            frame.locals[1] = try prefix_operator(machine);
            _ = grammar.whitespace(machine);
            if (try expression_list(machine)) return postfix(machine, frame);
            frame.phase = 2;
            return .{ .call = .expression_paren };
        },
        2 => {
            if (machine.outcome == .succeeded) return postfix(machine, frame);
            frame.phase = 3;
            return .{ .call = .expression_function_call };
        },
        3 => {
            if (machine.outcome == .succeeded) return postfix(machine, frame);
            if (try variable_name(machine)) return postfix(machine, frame);
            if (try literal(machine)) return postfix(machine, frame);
            frame.phase = 4;
            return .{ .call = .expression_string };
        },
        4 => {
            if (machine.outcome == .succeeded) return postfix(machine, frame);
            if (frame.locals[1] == 0) return .fail;
            frame.phase = 5;
            return .{ .call = .expression_unary };
        },
        else => {
            if (machine.outcome == .failed) return .fail;
            return postfix(machine, frame);
        },
    }
}

/// OneOf(String("-"), String("!")), else ExpressionNot: 1 + the unary tag, or 0.
fn prefix_operator(machine: *Machine) Error!u32 {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    if (grammar.parse_string(machine, "-")) return 1 + @as(u32, @backingInt(ast.Tag.negate));
    if (grammar.parse_string(machine, "!")) return 1 + @as(u32, @backingInt(ast.Tag.not));
    if (try grammar.keyword(machine, "not")) return 1 + @as(u32, @backingInt(ast.Tag.not));
    return 0;
}

fn postfix(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_unary);
    const marker = frame.locals[0];
    assert(machine.scratch_count == marker + 1);
    if (frame.locals[1] != 0) {
        const prefix: ast.Tag = @fromBackingInt(@intCast(frame.locals[1] - 1));
        try machine.wrap(prefix, marker);
    }
    _ = grammar.whitespace(machine);
    const increment = grammar.parse_string(machine, "++");
    if (increment or grammar.parse_string(machine, "--")) {
        if (grammar.top_tag(machine, marker) != .variable_reference) {
            grammar.report_message(machine, .increment_target);
        } else try machine.wrap(if (increment) .increment else .decrement, marker);
    }
    return .succeed;
}

/// ExpressionDivertTarget: `-> target` as a value (not a thread).
pub fn expression_divert_target(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_divert_target);
    assert(machine.tokenizer.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.scratch_count;
        _ = grammar.whitespace(machine);
        frame.phase = 1;
        return .{ .call = .single_divert };
    }
    if (machine.outcome == .failed) return .fail;
    if (grammar.top_tag(machine, frame.locals[0]) == .thread) return .fail;
    _ = grammar.whitespace(machine);
    try machine.wrap(.divert_target, frame.locals[0]);
    return .succeed;
}

/// ExpressionParen: `(expression)`; the inner expression itself.
pub fn expression_paren(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_paren);
    assert(machine.tokenizer.at <= machine.source.len);
    if (frame.phase == 0) {
        if (!grammar.parse_string(machine, "(")) return .fail;
        frame.phase = 1;
        machine.argument = 0;
        return .{ .call = .expression };
    }
    if (machine.outcome == .failed) return .fail;
    _ = grammar.whitespace(machine);
    grammar.expect_string(machine, ")", .closing_parenthesis);
    return .succeed;
}

/// ExpressionFunctionCall: `name(arguments)`.
pub fn expression_function_call(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_function_call);
    assert(machine.tokenizer.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.scratch_count;
        if (!try grammar.push_identifier(machine)) return .fail;
        _ = grammar.whitespace(machine);
        frame.phase = 1;
        return .{ .call = .function_call_arguments };
    }
    if (machine.outcome == .failed) return .fail;
    try machine.wrap(.function_call, frame.locals[0]);
    machine.flags |= grammar.saw_function_call;
    return .succeed;
}

/// ExpressionFunctionCallArguments: `(` Interleave(Expression, Exclude(String(","))) `)`.
pub fn function_call_arguments(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .function_call_arguments);
    assert(machine.tokenizer.at <= machine.source.len);
    if (frame.phase == 0) {
        if (!grammar.parse_string(machine, "(")) return .fail;
        frame.locals[0] = machine.scratch_count;
        frame.phase = 1;
        machine.argument = 0;
        return .{ .call = .expression };
    }
    if (machine.outcome == .succeeded and grammar.parse_string(machine, ",")) {
        if (!grammar.at_end(machine)) {
            machine.argument = 0;
            return .{ .call = .expression };
        }
    }
    _ = grammar.whitespace(machine);
    grammar.expect_string(machine, ")", .closing_parenthesis);
    try machine.wrap(.arguments, frame.locals[0]);
    return .succeed;
}

/// ExpressionString: `"` mixed text and logic `"`.
pub fn expression_string(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .expression_string);
    assert(machine.tokenizer.at <= machine.source.len);
    if (frame.phase == 0) {
        if (!grammar.parse_string(machine, "\"")) return .fail;
        machine.flags |= grammar.parsing_string;
        frame.locals[0] = machine.scratch_count;
        frame.phase = 1;
        return .{ .call = .mixed_text_and_logic };
    }
    if (!grammar.parse_string(machine, "\"")) grammar.report_expected(machine, .closing_quote);
    machine.flags &= ~grammar.parsing_string;
    const marker = frame.locals[0];
    if (machine.outcome == .failed) {
        const empty = try machine.add_token(.text, grammar.at(machine), grammar.at(machine));
        try machine.push_node(.text, empty.to_int());
    } else {
        for (machine.workspace.scratch_tags[marker..machine.scratch_count]) |tag| {
            if (tag == .divert or tag == .tunnel or tag == .thread or tag == .empty_divert) {
                grammar.report_message(machine, .string_with_divert);
                break;
            }
        }
    }
    try machine.wrap(.string, marker);
    return .succeed;
}

/// Whether the string at the top of the scratch stack is one text (isSingleString).
pub fn top_string_is_single(machine: *const Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    const workspace = machine.workspace;
    assert(grammar.top_tag(machine, 0) == .string);
    const counter = workspace.scratch_data[machine.scratch_count - 1];
    return workspace.node_data[counter] == 1 and workspace.node_tags[counter + 1] == .text;
}

/// Whether a value is a number once ink folds unary operators into it (WithInner).
pub fn is_number(machine: *const Machine, tag_initial: ast.Tag, data_initial: u32) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    const workspace = machine.workspace;
    assert(data_initial <= workspace.node_tags.len);
    var tag = tag_initial;
    var data = data_initial;
    while (tag == .negate or tag == .not) {
        tag = workspace.node_tags[data];
        data = workspace.node_data[data];
    }
    return tag == .integer or tag == .float or tag == .true or tag == .false;
}

// Lexical expressions.

/// ExpressionList: `(a, b.c)`, a list literal (maybe empty).
fn expression_list(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    const saved_tokens = machine.tokens_count;
    const marker = machine.scratch_count;
    _ = grammar.whitespace(machine);
    if (grammar.parse_string(machine, "(")) {
        _ = grammar.whitespace(machine);
        if (try list_member(machine)) {
            while (true) {
                const separator = grammar.at(machine);
                _ = grammar.whitespace(machine);
                const comma = grammar.parse_string(machine, ",");
                _ = grammar.whitespace(machine);
                if (comma and try list_member(machine)) continue;
                machine.tokenizer.at = separator;
                break;
            }
        }
        _ = grammar.whitespace(machine);
        if (grammar.parse_string(machine, ")")) {
            try machine.wrap(.list_literal, marker);
            return true;
        }
    }
    machine.tokenizer.at = start;
    machine.tokens_count = saved_tokens;
    machine.scratch_count = marker;
    return false;
}

/// ListMember: `name` or `list.name`, one identifier token.
fn list_member(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.whitespace(machine);
    const first = try grammar.identifier(machine) orelse return false;
    if (grammar.parse_string(machine, ".")) {
        if (try grammar.identifier(machine) == null) {
            grammar.report_expected(machine, .variable_name);
        } else machine.tokens_count -= 1;
        machine.workspace.token_ends[first.to_int()] = grammar.at(machine);
    }
    try machine.push_node(.identifier, first.to_int());
    _ = grammar.whitespace(machine);
    return true;
}

/// ExpressionVariableName: Interleave(Identifier, Exclude(Spaced(String(".")))), not a
/// reserved word.
fn variable_name(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    const saved_tokens = machine.tokens_count;
    const marker = machine.scratch_count;
    while (try grammar.push_identifier(machine)) {
        const separator = grammar.at(machine);
        _ = grammar.whitespace(machine);
        if (!grammar.parse_string(machine, ".")) {
            machine.tokenizer.at = separator;
            break;
        }
        _ = grammar.whitespace(machine);
    }
    const workspace = machine.workspace;
    const empty = machine.scratch_count == marker;
    const first_word = if (empty) 0 else workspace.scratch_data[marker];
    const first: ast.TokenIndex = .from_int(first_word);
    const reserved = !empty and grammar.is_reserved_keyword(grammar.token_text(machine, first));
    if (empty or reserved) {
        machine.tokenizer.at = start;
        machine.tokens_count = saved_tokens;
        machine.scratch_count = marker;
        return false;
    }
    try machine.wrap(.path, marker);
    try machine.wrap(.variable_reference, marker);
    return true;
}

/// ExpressionLiteral: OneOf(ExpressionFloat, ExpressionInt, ExpressionBool); the string is
/// a rule of its own.
fn literal(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    if (parse_int(machine)) {
        if (grammar.parse_string(machine, ".")) {
            while (!grammar.at_end(machine) and std.ascii.isDigit(grammar.rest(machine)[0])) {
                machine.tokenizer.at += 1;
            }
            const token = try machine.add_token(.word, start, grammar.at(machine));
            try machine.push_node(.float, token.to_int());
            return true;
        }
        machine.tokenizer.at = start;
    }
    if (try push_integer(machine)) return true;
    const token = try grammar.identifier(machine) orelse return false;
    const text = grammar.token_text(machine, token);
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
        try machine.push_node(if (text[0] == 't') .true else .false, token.to_int());
        return true;
    }
    machine.tokenizer.at = start;
    machine.tokens_count -= 1;
    return false;
}

/// ParseInt: an optional `-`, optional spaces, digits; a value out of range is an error.
fn parse_int(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    _ = grammar.parse_string(machine, "-");
    _ = grammar.whitespace(machine);
    const digits = grammar.at(machine);
    while (!grammar.at_end(machine) and std.ascii.isDigit(grammar.rest(machine)[0])) {
        machine.tokenizer.at += 1;
    }
    if (grammar.at(machine) == digits) {
        machine.tokenizer.at = start;
        return false;
    }
    const negative = machine.source[start] == '-';
    const text = machine.source[digits..grammar.at(machine)];
    const value = std.fmt.parseInt(i64, text, 10) catch std.math.maxInt(i64);
    const limit: i64 = if (negative) 1 << 31 else (1 << 31) - 1;
    if (value > limit) {
        grammar.report_message(machine, .integer_out_of_range);
        machine.tokenizer.at = start;
        return false;
    }
    return true;
}

/// ExpressionInt: an integer leaf whose token covers the sign, spaces and digits.
pub fn push_integer(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    if (!parse_int(machine)) return false;
    const token = try machine.add_token(.word, start, grammar.at(machine));
    try machine.push_node(.integer, token.to_int());
    return true;
}
