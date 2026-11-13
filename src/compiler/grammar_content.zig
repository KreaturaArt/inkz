//! ink's content rules (InkParser_Content.cs, _Logic.cs inline parts, _Tags.cs,
//! _Conditional.cs, _Sequences.cs): lines of text and inline logic, conditionals and
//! sequences. A mixed text-and-logic result is left flat on the scratch stack, as ink's
//! List<Parsed.Object> is; callers wrap it.

const std = @import("std");
const assert = std.debug.assert;
const grammar = @import("grammar.zig");
const ast = @import("ast.zig");
const Machine = grammar.Machine;
const Frame = grammar.Frame;
const Action = grammar.Action;
const Error = grammar.Error;
const Level = grammar.Level;

// Text.

/// ContentTextAllowingEcapeChar: text up to logic, a divert, glue or the line end; the token
/// keeps the `\` escapes.
pub fn content_text(machine: *Machine) Error!bool {
    const start = grammar.at(machine);
    const parsing_string = machine.flags & grammar.parsing_string != 0;
    const parsing_choice = machine.plain_flags & grammar.parsing_choice != 0;
    while (!grammar.at_end(machine)) {
        const text = grammar.rest(machine);
        const character = text[0];
        if (character == '\\') {
            machine.at += @min(2, text.len);
            continue;
        }
        if (is_end_character(character, parsing_string, parsing_choice)) break;
        if (character == '-' or character == '<') {
            const arrow = std.mem.startsWith(u8, text, "->") or std.mem.startsWith(u8, text, "<-");
            if (arrow or std.mem.startsWith(u8, text, "<>")) break;
        }
        machine.at += 1;
    }
    assert(grammar.at(machine) >= start);
    if (grammar.at(machine) == start) return false;
    const token = try machine.add_token(start, grammar.at(machine));
    try machine.push_node(.text, token.to_int());
    return true;
}

fn is_end_character(character: u8, parsing_string: bool, parsing_choice: bool) bool {
    if (std.mem.indexOfScalar(u8, "{}|\n\r\\#", character) != null) return true;
    if (parsing_string) return character == '"';
    if (parsing_choice) return character == '[' or character == ']';
    return false;
}

/// TrimEndWhitespace on the text at scratch `index`: returns whether it is now empty (and
/// so should be dropped). With `terminate_with_space` it ends with one space instead.
fn trim_text_at(machine: *Machine, index: u32, terminate_with_space: bool) Error!bool {
    const workspace = machine.workspace;
    assert(index < machine.scratch_count);
    assert(workspace.scratch_tags[index] == .text or workspace.scratch_tags[index] == .text_space);
    const token = workspace.scratch_data[index];
    const start = workspace.token_starts[token];
    const end = trimmed_end(machine.source, start, workspace.token_ends[token]);
    if (terminate_with_space) {
        const trimmed = try machine.add_token(start, end);
        workspace.scratch_tags[index] = .text_space;
        workspace.scratch_data[index] = trimmed.to_int();
        return false;
    }
    if (end == start) return true;
    if (end != workspace.token_ends[token] or workspace.scratch_tags[index] == .text_space) {
        const trimmed = try machine.add_token(start, end);
        workspace.scratch_data[index] = trimmed.to_int();
    }
    workspace.scratch_tags[index] = .text;
    return false;
}

/// The end of `source[start..end]` without trailing spaces and tabs, escaped ones too (ink
/// trims the unescaped text).
fn trimmed_end(source: []const u8, start: u32, end_initial: u32) u32 {
    assert(start <= end_initial);
    var end = end_initial;
    while (end > start and (source[end - 1] == ' ' or source[end - 1] == '\t')) {
        var backslashes: u32 = 0;
        while (end - 1 - backslashes > start and source[end - 2 - backslashes] == '\\') {
            backslashes += 1;
        }
        end -= if (backslashes % 2 == 1) 2 else 1;
    }
    assert(end >= start);
    return end;
}

/// TrimEndWhitespace(terminateWithSpace: false) on the values above `marker`.
fn trim_end_whitespace(machine: *Machine, marker: u32) Error!void {
    assert(marker <= machine.scratch_count);
    while (grammar.top_tag(machine, marker)) |tag| {
        if (tag != .text and tag != .text_space) return;
        if (!try trim_text_at(machine, machine.scratch_count - 1, false)) return;
        machine.scratch_count -= 1;
    }
    assert(machine.scratch_count >= marker);
}

pub fn is_divert(tag: ast.Tag) bool {
    assert(@backingInt(tag) < @typeInfo(ast.Tag).@"enum".field_names.len);
    return switch (tag) {
        .divert, .tunnel, .thread, .empty_divert => true,
        else => false,
    };
}

/// LineOfMixedTextAndLogic: a line's content, trimmed, with its "\n" (unless it is only a
/// tag), spliced flat into the statement list.
pub fn line_of_mixed_text_and_logic(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            frame.phase = 1;
            return .{ .call = .mixed_text_and_logic };
        },
        else => {
            assert(frame.phase == 1);
            assert(machine.outcome != .none);
            if (machine.outcome == .failed) return .fail;
            const marker = frame.checkpoint.scratch;
            const workspace = machine.workspace;
            // MixedTextAndLogic succeeds only with content; its first value is read below.
            assert(machine.scratch_count > marker);
            if (workspace.scratch_tags[marker] == .text) {
                const text = grammar.token_text(machine, .from_int(workspace.scratch_data[marker]));
                if (std.mem.startsWith(u8, text, "return")) {
                    grammar.report_message(machine, .return_without_tilde);
                }
            }
            const last = grammar.top_tag(machine, marker).?;
            if (!is_divert(last)) try trim_end_whitespace(machine, marker);
            try grammar.end_tag_if_necessary(machine, true);
            const pure_tag = machine.scratch_count > marker and
                workspace.scratch_tags[marker] == .tag_start;
            if (!pure_tag) try machine.push_node(.newline, 0);
            grammar.expect_end_of_line(machine);
            return .succeed;
        },
    }
}

/// MixedTextAndLogic: text and inline logic interleaved, then (outside choices) diverts.
pub fn mixed_text_and_logic(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            const start = grammar.at(machine);
            _ = grammar.whitespace(machine);
            if (grammar.parse_string(machine, "~")) {
                _ = grammar.whitespace(machine);
                grammar.report_message(machine, .tilde_in_content);
            } else machine.at = start;
            _ = try content_text(machine);
            frame.phase = 1;
            return .{ .call = .inline_logic_or_glue_or_start_tag };
        },
        1 => {
            assert(machine.outcome != .none);
            const got_logic = machine.outcome == .succeeded;
            const got_text = try content_text(machine);
            if ((got_logic or got_text) and !grammar.at_end(machine)) {
                return .{ .call = .inline_logic_or_glue_or_start_tag };
            }
            if (machine.plain_flags & grammar.parsing_choice != 0) return finish_mixed(
                machine,
                frame,
            );
            frame.locals[1] = machine.scratch_count;
            frame.phase = 2;
            return .{ .call = .multi_divert };
        },
        else => {
            assert(frame.phase == 2);
            assert(machine.outcome != .none);
            if (machine.outcome == .succeeded) {
                const diverts = frame.locals[1];
                // The diverts went on top of the line's content.
                assert(diverts >= frame.checkpoint.scratch);
                assert(diverts <= machine.scratch_count);
                const tag_was_active = machine.flags & grammar.tag_active != 0;
                if (tag_was_active) try grammar.insert_node(machine, diverts, .tag_end, 0);
                machine.flags &= ~grammar.tag_active;
                const last = diverts + @intFromBool(tag_was_active);
                if (last > frame.checkpoint.scratch) {
                    const tag = machine.workspace.scratch_tags[last - 1];
                    if (tag == .text or tag == .text_space) _ = try trim_text_at(
                        machine,
                        last - 1,
                        true,
                    );
                }
            }
            return finish_mixed(machine, frame);
        },
    }
}

fn finish_mixed(machine: *Machine, frame: *Frame) Action {
    assert(frame.rule == .mixed_text_and_logic);
    assert(machine.scratch_count >= frame.checkpoint.scratch);
    if (machine.scratch_count == frame.checkpoint.scratch) return .fail;
    return .succeed;
}

/// InlineLogicOrGlueOrStartTag: OneOf(InlineLogic, Glue, StartTag).
pub fn inline_logic_or_glue_or_start_tag(machine: *Machine, frame: *Frame) Error!Action {
    if (frame.phase == 0) {
        frame.phase = 1;
        return .{ .call = .inline_logic };
    }
    assert(frame.phase == 1);
    assert(machine.outcome != .none);
    if (machine.outcome == .succeeded) return .succeed;
    const start = grammar.at(machine);
    if (grammar.parse_string(machine, "<>")) {
        const token = try machine.add_token(start, start + 2);
        try machine.push_node(.glue, token.to_int());
        return .succeed;
    }
    // StartTag.
    _ = grammar.whitespace(machine);
    const hash = grammar.at(machine);
    if (!grammar.parse_string(machine, "#")) return .fail;
    if (machine.flags & grammar.parsing_string != 0) grammar.report_message(
        machine,
        .tag_in_string,
    );
    const token = try machine.add_token(hash, hash + 1);
    if (machine.flags & grammar.tag_active != 0) {
        const marker = machine.scratch_count;
        try machine.push_node(.tag_end, 0);
        try machine.push_node(.tag_start, token.to_int());
        try machine.wrap(.content_list, marker);
    } else try machine.push_node(.tag_start, token.to_int());
    machine.flags |= grammar.tag_active;
    _ = grammar.whitespace(machine);
    return .succeed;
}

/// InlineLogic: `{` inner logic `}`, as a content list.
pub fn inline_logic(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            if (!grammar.parse_string(machine, "{")) return .fail;
            frame.locals[1] = machine.flags;
            _ = grammar.whitespace(machine);
            frame.phase = 1;
            return .{ .call = .inner_logic };
        },
        else => {
            assert(machine.outcome != .none);
            if (machine.outcome == .failed) {
                grammar.report_expected(machine, .inner_logic);
                return .fail;
            }
            _ = grammar.whitespace(machine);
            grammar.expect_string(machine, "}", .closing_brace);
            const was = frame.locals[1];
            machine.flags &= ~grammar.parsing_string;
            machine.flags |= was & grammar.parsing_string;
            if (was & grammar.tag_active == 0) try grammar.end_tag_if_necessary(machine, true);
            try machine.wrap(.content_list, frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

/// InnerLogic: an annotated sequence, a conditional with a query, or else the first of a
/// conditional, a sequence and an expression that covers everything up to the `}`.
pub fn inner_logic(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            if (try sequence_type_annotation(machine)) |kind| {
                try machine.push_node(.sequence_kind, kind);
                frame.phase = 1;
                return .{ .call = .inner_sequence_objects };
            }
            frame.locals[1] = grammar.at(machine);
            frame.phase = 2;
            return .{ .call = .condition_expression };
        },
        1 => {
            if (machine.outcome == .failed) {
                grammar.report_expected(machine, .sequence_elements);
                return .fail;
            }
            // The sequence is its annotated kind and the elements.
            assert(machine.workspace.scratch_tags[frame.checkpoint.scratch] == .sequence_kind);
            try machine.wrap(.sequence, frame.checkpoint.scratch);
            return .succeed;
        },
        2 => {
            assert(machine.outcome != .none);
            if (machine.outcome == .succeeded) {
                return grammar.call(machine, frame, 3, .inner_conditional_content, 1);
            }
            frame.phase = 4;
            frame.locals[2] = 0;
            machine.argument = 0;
            return .{ .call = full_alternatives[0] };
        },
        3 => {
            assert(machine.outcome != .none);
            if (machine.outcome == .succeeded) return .succeed;
            grammar.report_expected(machine, .conditional_content);
            return .fail;
        },
        else => return inner_logic_alternative(machine, frame),
    }
}

/// The rules InnerLogic tries in turn; each must reach the closing brace.
const full_alternatives = [_]grammar.Rule{
    .inner_conditional_content,
    .inner_sequence,
    .inner_expression,
};

fn inner_logic_alternative(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .inner_logic);
    assert(frame.phase == 4);
    if (machine.outcome == .succeeded and closing_brace_ahead(machine)) return .succeed;
    machine.restore(frame.checkpoint);
    machine.at = frame.locals[1];
    frame.locals[2] += 1;
    if (frame.locals[2] == full_alternatives.len) return .fail;
    machine.argument = 0;
    return .{ .call = full_alternatives[frame.locals[2]] };
}

/// Peek(Spaced(String("}"))).
fn closing_brace_ahead(machine: *Machine) bool {
    const start = grammar.at(machine);
    _ = grammar.whitespace(machine);
    const found = grammar.parse_string(machine, "}");
    machine.at = start;
    return found;
}

/// InnerExpression: an expression output when complete.
pub fn inner_expression(machine: *Machine, frame: *Frame) Error!Action {
    if (frame.phase == 0) {
        return grammar.call(machine, frame, 1, .expression, 0);
    }
    assert(machine.outcome != .none);
    if (machine.outcome == .failed) return .fail;
    disallow_increment(machine, frame.checkpoint.scratch);
    try machine.wrap(.inline_value, frame.checkpoint.scratch);
    return .succeed;
}

/// DisallowIncrement on the value above `marker`.
pub fn disallow_increment(machine: *Machine, marker: u32) void {
    const tag = grammar.top_tag(machine, marker) orelse return;
    assert(machine.scratch_count == marker + 1);
    if (tag == .increment or tag == .decrement) grammar.report_message(
        machine,
        .increment_not_allowed,
    );
}

/// ConditionExpression: an expression and `:`.
pub fn condition_expression(machine: *Machine, frame: *Frame) Error!Action {
    if (frame.phase == 0) {
        return grammar.call(machine, frame, 1, .expression, 0);
    }
    assert(machine.outcome != .none);
    if (machine.outcome == .failed) return .fail;
    disallow_increment(machine, frame.checkpoint.scratch);
    _ = grammar.whitespace(machine);
    if (!grammar.parse_string(machine, ":")) return .fail;
    return .succeed;
}

// Conditionals.

/// InnerConditionalContent(initialQueryExpression): the argument says whether the query is
/// on the scratch stack. Inline branches split by `|`, or multiline `- condition:` branches.
pub fn inner_conditional_content(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            // The argument is whether the initial query is the scratch stack's top value.
            assert(machine.argument <= 1);
            assert(machine.scratch_count >= machine.argument);
            frame.locals[0] = machine.argument;
            frame.locals[1] = machine.scratch_count - frame.locals[0];
            if (frame.locals[0] == 0) try grammar.push_none(machine);
            if (!grammar.newline(machine)) {
                if (frame.locals[0] == 0) return .fail;
                frame.phase = 10;
                return inline_branch_next(machine, frame);
            }
            _ = grammar.multiline_whitespace(machine);
            frame.phase = 20;
            return .{ .call = .single_multiline_condition };
        },
        10 => return inline_branch(machine, frame),
        20 => {
            if (machine.outcome == .succeeded) return .{ .call = .single_multiline_condition };
            if (machine.scratch_count > frame.locals[1] + 1) {
                _ = grammar.multiline_whitespace(machine);
                return finish_multiline(machine, frame);
            }
            if (frame.locals[0] == 0) return .fail;
            // A sole branch without a dash.
            try grammar.push_none(machine);
            return grammar.call(machine, frame, 21, .statements, @backingInt(Level.inner_block));
        },
        21 => {
            assert(machine.outcome != .none);
            if (machine.outcome == .failed) return .fail;
            // The query slot, then the sole branch's empty condition and its statements.
            assert(machine.scratch_count >= frame.locals[1] + 3);
            try machine.wrap(.conditional_branch, machine.scratch_count - 2);
            frame.phase = 22;
            return .{ .call = .single_multiline_condition };
        },
        else => {
            assert(frame.phase == 22);
            if (machine.outcome == .succeeded and grammar.top_tag(machine, 0) != .else_branch) {
                grammar.report_message(machine, .expected_else);
                to_else_branch(machine, machine.scratch_count - 1);
            }
            return finish_multiline(machine, frame);
        },
    }
}

/// Starts an inline branch: an empty condition slot, then the branch content.
fn inline_branch_next(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.phase == 10);
    try grammar.push_none(machine);
    frame.locals[2] = machine.scratch_count;
    return .{ .call = .mixed_text_and_logic };
}

/// InlineConditionalBranches: Interleave(MixedTextAndLogic, Exclude(String("|"))).
fn inline_branch(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.phase == 10);
    assert(machine.outcome != .none);
    const branches = frame.locals[1] + 1;
    // Each branch starts with its condition slot, above the query slot.
    assert(frame.locals[2] > branches);
    if (machine.outcome == .failed) {
        // Drop the empty condition slot; without any branch there is no conditional.
        machine.scratch_count -= 1;
        if (machine.scratch_count == branches) return .fail;
    } else {
        try machine.wrap(.content_list, frame.locals[2]);
        try machine.wrap(.conditional_branch, frame.locals[2] - 1);
        if (grammar.parse_string(machine, "|")) return inline_branch_next(machine, frame);
    }
    if (machine.scratch_count - branches > 2) {
        grammar.report_message(machine, .inline_conditional_alternatives);
        machine.scratch_count = branches;
    }
    try machine.wrap(.branches, branches);
    try machine.wrap(.inline_conditional, frame.locals[1]);
    return .succeed;
}

/// A conditional_branch (condition, content) becomes an else_branch (content).
fn to_else_branch(machine: *Machine, index: u32) void {
    const workspace = machine.workspace;
    assert(workspace.scratch_tags[index] == .conditional_branch);
    workspace.scratch_tags[index] = .else_branch;
    workspace.scratch_data[index] += 1;
    assert(index < machine.scratch_count);
}

/// Whether the branch at scratch `index` has its own condition.
fn has_own_expression(machine: *const Machine, index: u32) bool {
    const workspace = machine.workspace;
    assert(index < machine.scratch_count);
    if (workspace.scratch_tags[index] != .conditional_branch) return false;
    return workspace.node_tags[workspace.scratch_data[index]] != .none;
}

/// The checks of multiline InnerConditionalContent, then the conditional.
fn finish_multiline(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.locals[0] <= 1);
    const has_initial = frame.locals[0] == 1;
    const branches = frame.locals[1] + 1;
    assert(machine.scratch_count >= branches);
    const tags = machine.workspace.scratch_tags;
    if (has_initial and machine.scratch_count == branches + 1 and tags[branches] == .else_branch) {
        // An empty true branch goes first.
        try grammar.push_none(machine);
        try grammar.push_none(machine);
        try machine.wrap(.conditional_branch, machine.scratch_count - 2);
        grammar.swap_top(machine);
    }
    const count = machine.scratch_count - branches;
    var earlier_have_own = false;
    for (0..count) |position| {
        const index: u32 = branches + @as(u32, @intCast(position));
        const is_last = position == count - 1;
        if (has_own_expression(machine, index)) {
            earlier_have_own = true;
        } else if (has_initial) {
            if (!(earlier_have_own and is_last) and !is_last and count > 2) {
                grammar.report_message(machine, .only_final_branch_else);
            }
        } else if (!is_last) {
            if (tags[index] != .else_branch) {
                grammar.report_message(machine, .branch_without_condition);
            } else if (tags[machine.scratch_count - 1] == .else_branch) {
                grammar.report_message(machine, .multiple_else);
            } else grammar.report_message(machine, .else_not_final);
        }
    }
    if (!has_initial and count == 1 and !has_own_expression(machine, branches)) {
        grammar.report_message(machine, .condition_block_without_conditions);
    }
    try machine.wrap(.branches, branches);
    try machine.wrap(.conditional, frame.locals[1]);
    return .succeed;
}

/// SingleMultilineCondition: `- condition: content`, `- else: content` or `- content`.
pub fn single_multiline_condition(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            _ = grammar.whitespace(machine);
            if (grammar.parse_string(machine, "->")) return .fail;
            if (!grammar.parse_string(machine, "-")) return .fail;
            _ = grammar.whitespace(machine);
            frame.locals[1] = @intFromBool(else_expression(machine));
            frame.phase = if (frame.locals[1] == 1) 2 else 1;
            if (frame.locals[1] == 1) {
                machine.argument = @backingInt(Level.inner_block);
                return .{ .call = .statements };
            }
            return .{ .call = .condition_expression };
        },
        1 => {
            assert(machine.outcome != .none);
            if (machine.outcome == .failed) try grammar.push_none(machine);
            return grammar.call(machine, frame, 2, .statements, @backingInt(Level.inner_block));
        },
        else => {
            assert(frame.phase == 2);
            assert(machine.outcome != .none);
            const is_else = frame.locals[1] == 1;
            const marker = frame.checkpoint.scratch;
            if (machine.outcome == .failed) {
                const no_expression = is_else or grammar.top_tag(machine, marker) == .none;
                if (no_expression) {
                    grammar.report_message(machine, .branch_without_content);
                    const statements_marker = machine.scratch_count;
                    const empty = try machine.add_token(
                        grammar.at(machine),
                        grammar.at(machine),
                    );
                    try machine.push_node(.text, empty.to_int());
                    try machine.wrap(.statements, statements_marker);
                } else try grammar.push_none(machine);
            }
            _ = grammar.multiline_whitespace(machine);
            try machine.wrap(if (is_else) .else_branch else .conditional_branch, marker);
            return .succeed;
        },
    }
}

/// ElseExpression: `else` and `:`, restoring the input on failure.
fn else_expression(machine: *Machine) bool {
    const start = grammar.at(machine);
    if (grammar.parse_string(machine, "else")) {
        _ = grammar.whitespace(machine);
        if (grammar.parse_string(machine, ":")) return true;
    }
    machine.at = start;
    return false;
}

// Sequences.

/// ink's SequenceType flags.
const stopping: u32 = 1;
const cycle: u32 = 2;
const shuffle: u32 = 4;
const once: u32 = 8;

/// SequenceTypeAnnotation: symbols (`!&~$`) or words (`once cycle:`); null if neither.
fn sequence_type_annotation(machine: *Machine) Error!?u32 {
    const kind = symbol_annotation(machine) orelse try word_annotation(machine) orelse return null;
    assert(kind != 0);
    switch (kind) {
        once, cycle, stopping, shuffle, shuffle | stopping, shuffle | once => return kind,
        else => {
            grammar.report_message(machine, .sequence_combination);
            return stopping;
        },
    }
}

fn symbol_annotation(machine: *Machine) ?u32 {
    const start = grammar.at(machine);
    var kind: u32 = 0;
    while (!grammar.at_end(machine)) : (machine.at += 1) {
        kind |= switch (grammar.rest(machine)[0]) {
            '!' => once,
            '&' => cycle,
            '~' => shuffle,
            '$' => stopping,
            ' ' => 0,
            else => break,
        };
    }
    if (kind == 0) machine.at = start;
    return if (kind == 0) null else kind;
}

fn word_annotation(machine: *Machine) Error!?u32 {
    const start = grammar.at(machine);
    const saved_tokens = machine.tokens_count;
    var kind: u32 = 0;
    while (try grammar.identifier(machine)) |token| {
        const word = grammar.token_text(machine, token);
        const words = [_][]const u8{ "once", "cycle", "shuffle", "stopping" };
        const flags = [_]u32{ once, cycle, shuffle, stopping };
        const found = for (words, flags) |name, flag| {
            if (std.mem.eql(u8, word, name)) break flag;
        } else 0;
        if (found == 0) {
            // The identifier just stored the last token; it is taken back.
            assert(token.to_int() + 1 == machine.tokens_count);
            machine.at = machine.workspace.token_starts[token.to_int()];
            machine.tokens_count -= 1;
            break;
        }
        kind |= found;
        if (!grammar.whitespace(machine)) break;
    }
    if (kind != 0 and grammar.parse_string(machine, ":")) return kind;
    machine.at = start;
    machine.tokens_count = saved_tokens;
    return null;
}

/// InnerSequence: an optional annotation and at least two elements.
pub fn inner_sequence(machine: *Machine, frame: *Frame) Error!Action {
    if (frame.phase == 0) {
        _ = grammar.whitespace(machine);
        const kind = try sequence_type_annotation(machine) orelse stopping;
        try machine.push_node(.sequence_kind, kind);
        frame.phase = 1;
        return .{ .call = .inner_sequence_objects };
    }
    assert(machine.outcome != .none);
    if (machine.outcome == .failed) return .fail;
    // InnerSequenceObjects leaves a branches list on top: its count node is read.
    assert(grammar.top_tag(machine, frame.checkpoint.scratch) == .branches);
    const elements = machine.workspace.scratch_data[machine.scratch_count - 1];
    if (machine.workspace.node_data[elements] <= 1) return .fail;
    try machine.wrap(.sequence, frame.checkpoint.scratch);
    return .succeed;
}

/// InnerSequenceObjects: multiline `- element` lines, or inline elements split by `|`; a
/// branches list of content lists.
pub fn inner_sequence_objects(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            if (grammar.newline(machine)) {
                _ = grammar.multiline_whitespace(machine);
                frame.phase = 1;
                return .{ .call = .single_multiline_sequence_element };
            }
            frame.locals[1] = 0;
            frame.locals[2] = machine.scratch_count;
            frame.phase = 2;
            return .{ .call = .mixed_text_and_logic };
        },
        1 => {
            assert(machine.outcome != .none);
            const element: grammar.Rule = .single_multiline_sequence_element;
            if (machine.outcome == .succeeded) return .{ .call = element };
            if (machine.scratch_count == frame.checkpoint.scratch) return .fail;
            try machine.wrap(.branches, frame.checkpoint.scratch);
            return .succeed;
        },
        else => {
            // InnerInlineSequenceObjects: Interleave(Optional(MixedTextAndLogic), String("|")).
            assert(frame.phase == 2);
            if (machine.outcome == .succeeded) frame.locals[1] = 1;
            try machine.wrap(.content_list, frame.locals[2]);
            if (grammar.parse_string(machine, "|")) {
                frame.locals[1] = 1;
                frame.locals[2] = machine.scratch_count;
                return .{ .call = .mixed_text_and_logic };
            }
            if (frame.locals[1] == 0) return .fail;
            try machine.wrap(.branches, frame.checkpoint.scratch);
            return .succeed;
        },
    }
}

/// SingleMultilineSequenceElement: `- content`; the content starts with a "\n".
pub fn single_multiline_sequence_element(machine: *Machine, frame: *Frame) Error!Action {
    if (frame.phase == 0) {
        _ = grammar.whitespace(machine);
        if (grammar.parse_string(machine, "->")) return .fail;
        if (!grammar.parse_string(machine, "-")) return .fail;
        _ = grammar.whitespace(machine);
        try machine.push_node(.newline, 0);
        return grammar.call(machine, frame, 1, .statements, @backingInt(Level.inner_block));
    }
    assert(machine.outcome != .none);
    if (machine.outcome == .failed) {
        machine.scratch_count = frame.checkpoint.scratch;
        _ = grammar.multiline_whitespace(machine);
    }
    try machine.wrap(.content_list, frame.checkpoint.scratch);
    return .succeed;
}
