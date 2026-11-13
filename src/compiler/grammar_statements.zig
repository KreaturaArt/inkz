//! ink's statement-level rules (InkParser_Statements.cs, _Knot.cs, _Logic.cs, _Include.cs,
//! _AuthorWarning.cs): statement lists by level, knots and stitches, declarations and logic
//! lines.

const std = @import("std");
const assert = std.debug.assert;
const grammar = @import("grammar.zig");
const weave = @import("grammar_weave.zig");
const expressions = @import("grammar_expressions.zig");
const ast = @import("ast.zig");
const Machine = grammar.Machine;
const Frame = grammar.Frame;
const Action = grammar.Action;
const Error = grammar.Error;
const Level = grammar.Level;

/// Parse: the top-level statements make the story.
pub fn story(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            return grammar.call(machine, frame, 1, .statements, @backingInt(Level.top));
        },
        else => {
            // An empty story still has a (empty) statement list.
            if (machine.outcome == .failed) try machine.wrap(.statements, frame.checkpoint.scratch);
            try machine.wrap(.story, frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

/// StatementsAtLevel: Interleave(Optional(MultilineWhitespace), StatementAtLevel,
/// untilTerminator: StatementsBreakForLevel).
pub fn statements(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    const level: Level = @fromBackingInt(@intCast(frame.locals[0]));
    switch (frame.phase) {
        0 => {
            frame.locals[0] = machine.argument;
            frame.locals[1] = machine.scratch_count;
            const inner = frame.locals[0] == @backingInt(Level.inner_block);
            if (inner and weave.gather_dashes(machine) > 0) {
                grammar.report_message(machine, .gather_in_inner_block);
            }
            _ = grammar.multiline_whitespace(machine);
            frame.phase = 1;
            return .again;
        },
        1 => {
            frame.phase = 2;
            machine.argument = @backingInt(level);
            return .{ .peek = .statements_break };
        },
        2 => {
            if (machine.outcome == .succeeded) return finish_statements(machine, frame);
            return grammar.call(machine, frame, 3, .statement, @backingInt(level));
        },
        else => {
            if (machine.outcome == .failed) return finish_statements(machine, frame);
            _ = grammar.multiline_whitespace(machine);
            if (grammar.at_end(machine)) return finish_statements(machine, frame);
            frame.phase = 1;
            return .again;
        },
    }
}

fn finish_statements(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .statements);
    if (machine.scratch_count == frame.locals[1]) return .fail;
    try machine.wrap(.statements, frame.locals[1]);
    return .succeed;
}

/// The alternatives of StatementAtLevel, in ink's order.
const Alternative = enum(u32) {
    multi_divert,
    knot_definition,
    choice,
    author_warning,
    gather,
    stitch_definition,
    list_declaration,
    variable_declaration,
    const_declaration,
    external_declaration,
    include_statement,
    logic_line,
    line_of_mixed_text_and_logic,
};

/// An alternative's rule, whether ink wraps it in Line(...) (an end of line is expected
/// after it), and the lowest level it applies at.
const AlternativeRule = struct {
    rule: grammar.Rule,
    line: bool = false,
    level_min: Level = .inner_block,
};

const declaration: AlternativeRule = .{ .rule = .declaration_line, .line = true };

const alternative_rules: std.enums.EnumArray(Alternative, AlternativeRule) = .init(.{
    .multi_divert = .{ .rule = .multi_divert, .line = true },
    .knot_definition = .{ .rule = .knot_definition, .level_min = .top },
    .choice = .{ .rule = .choice, .line = true },
    .author_warning = declaration,
    .gather = .{ .rule = .gather, .level_min = .stitch },
    .stitch_definition = .{ .rule = .stitch_definition, .level_min = .knot },
    .list_declaration = declaration,
    .variable_declaration = declaration,
    .const_declaration = declaration,
    .external_declaration = declaration,
    .include_statement = declaration,
    .logic_line = .{ .rule = .logic_line },
    .line_of_mixed_text_and_logic = .{ .rule = .line_of_mixed_text_and_logic },
});

/// StatementAtLevel: OneOf the level's rules.
pub fn statement(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.argument;
        frame.locals[1] = 0;
        frame.phase = 1;
    } else {
        const tried: Alternative = @fromBackingInt(@intCast(frame.locals[1]));
        if (machine.outcome == .succeeded) {
            if (alternative_rules.get(tried).line) grammar.expect_end_of_line(machine);
            const is_return = grammar.top_tag(machine, frame.checkpoint.scratch) == .@"return";
            if (frame.locals[0] == @backingInt(Level.top) and is_return) {
                grammar.report_message(machine, .return_at_top_level);
            }
            return .succeed;
        }
        frame.locals[1] += 1;
    }
    const level: Level = @fromBackingInt(@intCast(frame.locals[0]));
    const count = @typeInfo(Alternative).@"enum".field_names.len;
    while (frame.locals[1] < count) : (frame.locals[1] += 1) {
        const alternative: Alternative = @fromBackingInt(@intCast(frame.locals[1]));
        const rule = alternative_rules.get(alternative);
        if (@backingInt(level) < @backingInt(rule.level_min)) continue;
        machine.argument = @backingInt(alternative);
        return .{ .call = rule.rule };
    }
    return .fail;
}

/// StatementsBreakForLevel: Whitespace, then a knot or stitch declaration, or (in an inner
/// block) a dash that isn't an arrow, or `}`.
pub fn statements_break(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            frame.locals[0] = machine.argument;
            _ = grammar.whitespace(machine);
            frame.phase = 1;
            if (frame.locals[0] > @backingInt(Level.knot)) return break_inner(machine, frame);
            return .{ .call = .knot_declaration };
        },
        1 => {
            if (machine.outcome == .succeeded) return .succeed;
            frame.phase = 2;
            if (frame.locals[0] > @backingInt(Level.stitch)) return break_inner(machine, frame);
            return .{ .call = .stitch_declaration };
        },
        else => {
            if (machine.outcome == .succeeded) return .succeed;
            return break_inner(machine, frame);
        },
    }
}

fn break_inner(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .statements_break);
    if (frame.locals[0] != @backingInt(Level.inner_block)) return .fail;
    if (weave.dash_not_arrow(machine)) return .succeed;
    if (grammar.parse_string(machine, "}")) return .succeed;
    return .fail;
}

/// KnotDefinition: a declaration, its line end, then the knot's statements.
pub fn knot_definition(machine: *Machine, frame: *Frame) Error!Action {
    return flow_definition(machine, frame, .knot);
}

/// StitchDefinition: a declaration, its line end, then the stitch's statements.
pub fn stitch_definition(machine: *Machine, frame: *Frame) Error!Action {
    return flow_definition(machine, frame, .stitch);
}

fn flow_definition(machine: *Machine, frame: *Frame, comptime level: Level) Error!Action {
    comptime assert(level == .knot or level == .stitch);
    assert(machine.at <= machine.source.len);
    const knot = level == .knot;
    switch (frame.phase) {
        0 => {
            frame.phase = 1;
            return .{ .call = if (knot) .knot_declaration else .stitch_declaration };
        },
        1 => {
            if (machine.outcome == .failed) return .fail;
            frame.locals[1] = machine.result;
            grammar.expect_end_of_line(machine);
            return grammar.call(machine, frame, 2, .statements, @backingInt(level));
        },
        else => {
            if (machine.outcome == .failed) {
                try recover_flow_content(machine, if (knot) .knot_content else .stitch_content);
            }
            const is_function = frame.locals[1] == 1;
            const tag: ast.Tag = if (knot)
                (if (is_function) .function else .knot)
            else
                (if (is_function) .function_stitch else .stitch);
            try machine.wrap(tag, frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

/// KnotStitchNoContentRecoveryRule: skip to the next knot declaration; the content is
/// ink's "<ERROR IN FLOW>" text.
fn recover_flow_content(machine: *Machine, expectation: grammar.Expectation) Error!void {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    grammar.report_expected(machine, expectation);
    while (!grammar.at_end(machine)) {
        if (grammar.rest(machine)[0] == '=' and knot_title_equals_ahead(machine)) break;
        machine.at += 1;
    }
    const marker = machine.scratch_count;
    const token = try machine.add_token(grammar.at(machine), grammar.at(machine));
    try machine.push_node(.error_text, token.to_int());
    try machine.wrap(.statements, marker);
}

fn knot_title_equals_ahead(machine: *const Machine) bool {
    assert(machine.at <= machine.source.len);
    const text = grammar.rest(machine);
    assert(text.len > 0);
    return text.len > 1 and text[1] == '=';
}

/// KnotDeclaration: `==`, an optional `function`, the name and parameters; `result` is 1 for
/// a function.
pub fn knot_declaration(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.phase == 0);
    _ = grammar.whitespace(machine);
    if (knot_title_equals(machine) == 0) return .fail;
    _ = grammar.whitespace(machine);
    const first = try grammar.identifier(machine);
    var is_function = false;
    var name = first;
    if (first) |token| {
        if (std.mem.eql(u8, grammar.token_text(machine, token), "function")) {
            is_function = true;
            const spaced = grammar.whitespace(machine);
            if (!spaced) grammar.report_expected(machine, .function_name_whitespace);
            name = try grammar.identifier(machine);
        }
    }
    if (name) |token| {
        try machine.push_node(.identifier, token.to_int());
    } else {
        grammar.report_message(machine, .knot_name_missing);
        try grammar.push_missing(machine);
    }
    _ = grammar.whitespace(machine);
    if (!try bracketed_parameters(machine)) try grammar.push_none(machine);
    _ = grammar.whitespace(machine);
    _ = knot_title_equals(machine);
    machine.result = @intFromBool(is_function);
    return .succeed;
}

/// KnotTitleEquals: two or more `=`; their count (0 if fewer).
fn knot_title_equals(machine: *Machine) u32 {
    assert(machine.at <= machine.source.len);
    const start = grammar.at(machine);
    while (!grammar.at_end(machine) and grammar.rest(machine)[0] == '=') machine.at += 1;
    const count = grammar.at(machine) - start;
    if (count <= 1) {
        machine.at = start;
        return 0;
    }
    return count;
}

/// StitchDeclaration: a single `=`, an optional `function`, the name and parameters.
pub fn stitch_declaration(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.phase == 0);
    _ = grammar.whitespace(machine);
    if (!grammar.parse_string(machine, "=")) return .fail;
    if (grammar.parse_string(machine, "=")) return .fail;
    _ = grammar.whitespace(machine);
    const is_function = grammar.parse_string(machine, "function");
    if (is_function) _ = grammar.whitespace(machine);
    if (!try grammar.push_identifier(machine)) return .fail;
    _ = grammar.whitespace(machine);
    if (!try bracketed_parameters(machine)) try grammar.push_none(machine);
    _ = grammar.whitespace(machine);
    machine.result = @intFromBool(is_function);
    return .succeed;
}

/// BracketedKnotDeclArguments: `(` parameters `)`; pushes a parameters list.
fn bracketed_parameters(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    if (!grammar.parse_string(machine, "(")) return false;
    const marker = machine.scratch_count;
    while (true) {
        _ = grammar.whitespace(machine);
        if (!try flow_parameter(machine)) break;
        _ = grammar.whitespace(machine);
        if (!grammar.parse_string(machine, ",")) break;
    }
    grammar.expect_string(machine, ")", .closing_parenthesis);
    try machine.wrap(.parameters, marker);
    return true;
}

/// FlowDeclArgument: `name`, `ref name` or `-> name`.
fn flow_parameter(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const first = try grammar.identifier(machine);
    _ = grammar.whitespace(machine);
    const is_divert = grammar.parse_string(machine, "->");
    _ = grammar.whitespace(machine);
    const second = try grammar.identifier(machine);
    if (first == null and second == null) return false;
    if (first != null and std.mem.eql(u8, grammar.token_text(machine, first.?), "ref")) {
        if (second == null) grammar.report_message(machine, .ref_without_name);
        try push_parameter(machine, .reference_parameter, second);
    } else {
        const name = if (is_divert) second else first;
        if (name == null) grammar.report_message(machine, .parameter_name_missing);
        try push_parameter(machine, if (is_divert) .divert_parameter else .parameter, name);
    }
    return true;
}

fn push_parameter(machine: *Machine, tag: ast.Tag, name: ?ast.TokenIndex) Error!void {
    assert(machine.at <= machine.source.len);
    assert(tag == .parameter or tag == .reference_parameter or tag == .divert_parameter);
    if (name) |token| return machine.push_node(tag, token.to_int());
    try grammar.push_missing(machine);
}

/// The declaration lines: ink's AuthorWarning, ListDeclaration, VariableDeclaration,
/// ConstDeclaration, ExternalDeclaration and IncludeStatement. The argument says which.
pub fn declaration_line(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.argument;
        frame.locals[1] = machine.scratch_count;
    }
    const kind: Alternative = @fromBackingInt(@intCast(frame.locals[0]));
    return switch (kind) {
        .author_warning => author_warning(machine),
        .list_declaration => list_declaration(machine),
        .external_declaration => external_declaration(machine),
        .include_statement => include_statement(machine),
        .variable_declaration, .const_declaration => value_declaration(machine, frame, kind),
        else => unreachable,
    };
}

/// AuthorWarning: `TODO:` and the rest of the line.
fn author_warning(machine: *Machine) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.whitespace(machine);
    if (!try grammar.keyword(machine, "TODO")) return .fail;
    _ = grammar.whitespace(machine);
    _ = grammar.parse_string(machine, ":");
    _ = grammar.whitespace(machine);
    const line = grammar.until_line_end(machine);
    const token = try machine.add_token(line.start, line.end);
    try machine.push_node(.author_warning, token.to_int());
    return .succeed;
}

/// IncludeStatement: `INCLUDE` and a filename (loaded later).
fn include_statement(machine: *Machine) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.whitespace(machine);
    if (!grammar.parse_string(machine, "INCLUDE")) return .fail;
    _ = grammar.whitespace(machine);
    const line = grammar.until_line_end(machine);
    var end = line.end;
    while (end > line.start and std.mem.indexOfScalar(u8, " \t", machine.source[end - 1]) != null) {
        end -= 1;
    }
    if (end == line.start) grammar.report_expected(machine, .include_filename);
    const token = try machine.add_token(line.start, end);
    try machine.push_node(.include, token.to_int());
    return .succeed;
}

/// ExternalDeclaration: `EXTERNAL name(params)`.
fn external_declaration(machine: *Machine) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.whitespace(machine);
    if (!try grammar.keyword(machine, "EXTERNAL")) return .fail;
    const marker = machine.scratch_count;
    _ = grammar.whitespace(machine);
    try grammar.expect_identifier(machine, .external_name);
    _ = grammar.whitespace(machine);
    if (!try bracketed_parameters(machine)) {
        grammar.report_expected(machine, .external_parameters);
        try machine.wrap(.parameters, machine.scratch_count);
    }
    try machine.wrap(.external_declaration, marker);
    return .succeed;
}

/// ListDeclaration: `LIST name = items`.
fn list_declaration(machine: *Machine) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.whitespace(machine);
    if (!try grammar.keyword(machine, "LIST")) return .fail;
    const marker = machine.scratch_count;
    _ = grammar.whitespace(machine);
    try grammar.expect_identifier(machine, .variable_name);
    _ = grammar.whitespace(machine);
    grammar.expect_string(machine, "=", .equals);
    _ = grammar.whitespace(machine);
    if (!try list_definition(machine)) {
        // ink returns null without a definition: the line isn't a list declaration.
        grammar.report_expected(machine, .list_items);
        return .fail;
    }
    try machine.wrap(.list_declaration, marker);
    return .succeed;
}

/// ListDefinition: items separated by commas (with any whitespace around them).
fn list_definition(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = grammar.any_whitespace(machine);
    const marker = machine.scratch_count;
    if (!try list_item(machine)) return false;
    while (true) {
        const saved = grammar.at(machine);
        const saved_tokens = machine.tokens_count;
        _ = grammar.any_whitespace(machine);
        if (!grammar.parse_string(machine, ",")) {
            machine.at = saved;
            break;
        }
        _ = grammar.any_whitespace(machine);
        if (!try list_item(machine)) {
            machine.at = saved;
            machine.tokens_count = saved_tokens;
            break;
        }
    }
    try machine.wrap(.list_items, marker);
    return true;
}

/// ListElementDefinition: `name`, `(name)`, with an optional `= value`.
fn list_item(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    const selected = grammar.parse_string(machine, "(");
    var needs_close = selected;
    _ = grammar.whitespace(machine);
    const marker = machine.scratch_count;
    if (!try grammar.push_identifier(machine)) {
        machine.at = start;
        return false;
    }
    _ = grammar.whitespace(machine);
    if (selected and grammar.parse_string(machine, ")")) {
        needs_close = false;
        _ = grammar.whitespace(machine);
    }
    if (grammar.parse_string(machine, "=")) {
        _ = grammar.whitespace(machine);
        if (!try expressions.push_integer(machine)) {
            grammar.report_expected(machine, .list_item_value);
            try grammar.push_missing(machine);
        }
        if (needs_close) {
            _ = grammar.whitespace(machine);
            if (grammar.parse_string(machine, ")")) needs_close = false;
        }
    } else try grammar.push_none(machine);
    if (needs_close) grammar.report_message(machine, .list_item_closing_parenthesis);
    try machine.wrap(if (selected) .selected_list_item else .list_item, marker);
    return true;
}

/// VariableDeclaration and ConstDeclaration: `VAR name = expression`, `CONST ...`.
fn value_declaration(machine: *Machine, frame: *Frame, kind: Alternative) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const is_variable = kind == .variable_declaration;
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            if (!try grammar.keyword(machine, if (is_variable) "VAR" else "CONST")) return .fail;
            _ = grammar.whitespace(machine);
            try grammar.expect_identifier(machine, .variable_name);
            _ = grammar.whitespace(machine);
            grammar.expect_string(machine, "=", .equals);
            _ = grammar.whitespace(machine);
            return grammar.call(machine, frame, 1, .expression, 0);
        },
        else => {
            if (machine.outcome == .failed) {
                grammar.report_expected(machine, .expression);
                // ink's declaration returns null without a value.
                return .fail;
            }
            check_initial_value(machine, is_variable);
            try machine.wrap(
                if (is_variable) .variable_declaration else .const_declaration,
                frame.locals[1],
            );
            return .succeed;
        },
    }
}

/// The initial value checks of VariableDeclaration and ConstDeclaration.
fn check_initial_value(machine: *Machine, is_variable: bool) void {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const value = grammar.top_tag(machine, 0).?;
    const data = machine.workspace.scratch_data[machine.scratch_count - 1];
    const constant = expressions.is_number(machine, value, data) or value == .string or
        value == .divert_target;
    const reference = value == .variable_reference or value == .list_literal;
    const allowed = constant or (is_variable and reference);
    if (!allowed) {
        const message: grammar.Message =
            if (is_variable) .variable_initial_value else .constant_initial_value;
        grammar.report_message(machine, message);
        if (!is_variable) return;
    }
    if (is_variable and list_separator(machine)) {
        grammar.report_message(machine, .list_with_var);
        return;
    }
    if (value == .string and !expressions.top_string_is_single(machine)) {
        grammar.report_message(machine, .constant_string_logic);
    }
}

/// Parse(ListElementDefinitionSeparator): a comma with any whitespace around it.
fn list_separator(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    _ = grammar.any_whitespace(machine);
    if (grammar.parse_string(machine, ",")) {
        _ = grammar.any_whitespace(machine);
        return true;
    }
    machine.at = start;
    return false;
}

/// LogicLine: `~` and a return, an assignment or an expression.
pub fn logic_line(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            if (!grammar.parse_string(machine, "~")) return .fail;
            _ = grammar.whitespace(machine);
            machine.flags &= ~grammar.saw_function_call;
            frame.phase = 1;
            return .{ .call = .return_statement };
        },
        1 => {
            if (machine.outcome == .succeeded) return finish_logic_line(machine, frame);
            frame.phase = 2;
            return .{ .call = .temp_declaration_or_assignment };
        },
        2 => {
            if (machine.outcome == .succeeded) return finish_logic_line(machine, frame);
            return grammar.call(machine, frame, 3, .expression, 0);
        },
        else => {
            if (machine.outcome == .succeeded) return finish_logic_line(machine, frame);
            grammar.report_expected(machine, .expression);
            grammar.skip_to_next_line(machine);
            try machine.wrap(.content_list, frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

fn finish_logic_line(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const marker = frame.checkpoint.scratch;
    const result = grammar.top_tag(machine, marker).?;
    const is_statement = switch (result) {
        .@"return", .temp_declaration, .assignment, .add_assignment, .subtract_assignment => true,
        .function_call, .increment, .decrement => true,
        else => false,
    };
    if (!is_statement) grammar.report_message(machine, .logic_line_expression);
    if (result == .function_call) try machine.wrap(.call_statement, machine.scratch_count - 1);
    if (machine.flags & grammar.saw_function_call != 0) {
        try machine.push_node(.newline, 0);
        try machine.wrap(.content_list, marker);
    }
    grammar.expect_end_of_line(machine);
    return .succeed;
}

/// ReturnStatement: `return` and an optional expression.
pub fn return_statement(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            if (!try grammar.keyword(machine, "return")) return .fail;
            _ = grammar.whitespace(machine);
            return grammar.call(machine, frame, 1, .expression, 0);
        },
        else => {
            if (machine.outcome == .failed) try grammar.push_none(machine);
            try machine.wrap(.@"return", frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

/// TempDeclarationOrAssignment: `temp name = e`, `name = e`, `name += e`, `name -= e`.
pub fn temp_declaration_or_assignment(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            const is_new = try grammar.keyword(machine, "temp");
            _ = grammar.whitespace(machine);
            if (!try grammar.push_identifier(machine)) {
                if (is_new) grammar.report_expected(machine, .variable_name);
                return .fail;
            }
            _ = grammar.whitespace(machine);
            const increment = grammar.parse_string(machine, "+");
            const decrement = grammar.parse_string(machine, "-");
            if (increment and decrement) grammar.report_message(machine, .plus_minus);
            if (!grammar.parse_string(machine, "=")) {
                if (is_new) grammar.report_message(machine, .expected_equals);
                return .fail;
            }
            frame.locals[1] = if (increment) 1 else if (decrement) 2 else if (is_new) 3 else 0;
            return grammar.call(machine, frame, 1, .expression, 0);
        },
        else => {
            if (machine.outcome == .failed) {
                grammar.report_expected(machine, .expression);
                try grammar.push_missing(machine);
            }
            const tags = [_]ast.Tag{
                .assignment, .add_assignment, .subtract_assignment, .temp_declaration,
            };
            try machine.wrap(tags[frame.locals[1]], frame.checkpoint.scratch);
            return .succeed;
        },
    }
}
