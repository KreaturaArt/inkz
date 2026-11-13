//! ink's weave and divert rules (InkParser_Choices.cs, _Divert.cs): choices, gathers, and
//! divert lines with tunnels and threads.

const std = @import("std");
const assert = std.debug.assert;
const grammar = @import("grammar.zig");
const ast = @import("ast.zig");
const Machine = grammar.Machine;
const Frame = grammar.Frame;
const Action = grammar.Action;
const Error = grammar.Error;

/// A choice header's bits besides the depth.
pub const header_weave_brackets: u32 = 1 << 16;
pub const header_invisible_default: u32 = 1 << 17;

/// The bits of a choice frame's locals[2]; the condition count is in the bits above 8.
const choice_sticky: u32 = 1;
const choice_start: u32 = 2;
const choice_brackets: u32 = 4;
const choice_option: u32 = 8;
const choice_inner: u32 = 16;
const choice_conditions_shift = 8;

/// Choice: bullets, a label, conditions, then start, choice-only and inner content (the
/// content after `]`, the diverts and a "\n").
pub fn choice(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .choice);
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            var bits: u32 = 0;
            var depth = bullets(machine, '*');
            if (depth == 0) {
                depth = bullets(machine, '+');
                bits = choice_sticky;
            }
            if (depth == 0) return .fail;
            frame.locals[0] = machine.scratch_count;
            frame.locals[2] = bits;
            try machine.push_node(.header, depth);
            const named = try bracketed_name(machine);
            if (!named) try grammar.push_none(machine);
            _ = grammar.whitespace(machine);
            if (named) _ = grammar.newline_direct(machine);
            frame.locals[1] = machine.scratch_count;
            frame.phase = 1;
            return .{ .call = .choice_single_condition };
        },
        1 => return choice_conditions(machine, frame),
        2 => return choice_after_start(machine, frame),
        3 => {
            if (machine.outcome == .succeeded) frame.locals[2] |= choice_option;
            grammar.expect_string(machine, "]", .closing_bracket);
            try finish_section(machine, frame, choice_option);
            frame.locals[1] = machine.scratch_count;
            frame.phase = 4;
            return .{ .call = .mixed_text_and_logic };
        },
        4 => {
            if (machine.outcome == .succeeded) frame.locals[2] |= choice_inner;
            _ = grammar.whitespace(machine);
            try grammar.end_tag_if_necessary(machine, frame.locals[2] & choice_inner != 0);
            frame.phase = 5;
            return .{ .call = .multi_divert };
        },
        else => return finish_choice(machine, frame),
    }
}

/// ChoiceCondition: Interleave(ChoiceSingleCondition, ChoiceConditionsSpace).
fn choice_conditions(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .choice and frame.phase == 1);
    if (machine.outcome == .succeeded) {
        frame.locals[2] += 1 << choice_conditions_shift;
        _ = grammar.newline_direct(machine);
        _ = grammar.whitespace(machine);
        return .{ .call = .choice_single_condition };
    }
    const count = frame.locals[2] >> choice_conditions_shift;
    if (count == 0) try grammar.push_none(machine);
    if (count > 1) try machine.wrap(.conditions, frame.locals[1]);
    _ = grammar.whitespace(machine);
    machine.plain_flags |= grammar.parsing_choice;
    frame.locals[1] = machine.scratch_count;
    frame.phase = 2;
    return .{ .call = .mixed_text_and_logic };
}

/// After the start content: weave-style `[...]`, or straight on to the diverts.
fn choice_after_start(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .choice and frame.phase == 2);
    if (machine.outcome == .succeeded) frame.locals[2] |= choice_start;
    if (grammar.parse_string(machine, "[")) {
        frame.locals[2] |= choice_brackets;
        try finish_section(machine, frame, choice_start);
        frame.locals[1] = machine.scratch_count;
        frame.phase = 3;
        return .{ .call = .mixed_text_and_logic };
    }
    _ = grammar.whitespace(machine);
    try finish_section(machine, frame, choice_start);
    try grammar.push_none(machine);
    frame.locals[1] = machine.scratch_count;
    frame.phase = 5;
    return .{ .call = .multi_divert };
}

/// EndTagIfNecessary on a content section, then its content list (or none if it is null).
fn finish_section(machine: *Machine, frame: *Frame, bit: u32) Error!void {
    assert(bit == choice_start or bit == choice_option);
    const present = frame.locals[2] & bit != 0;
    try grammar.end_tag_if_necessary(machine, present);
    if (present) return machine.wrap(.content_list, frame.locals[1]);
    assert(machine.scratch_count == frame.locals[1]);
    try grammar.push_none(machine);
}

fn finish_choice(machine: *Machine, frame: *Frame) Error!Action {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .choice);
    const bits = frame.locals[2];
    const had_diverts = machine.outcome == .succeeded;
    // An empty divert only says the choice is intentionally blank.
    if (had_diverts and grammar.top_tag(machine, frame.locals[1]) == .empty_divert) {
        machine.scratch_count -= 1;
    }
    machine.plain_flags &= ~grammar.parsing_choice;
    _ = grammar.whitespace(machine);
    const empty = bits & (choice_start | choice_option | choice_inner) == 0;
    if (empty and !had_diverts) {
        grammar.report_message(machine, .choice_empty);
    } else if (bits & (choice_start | choice_option) == 0 and bits & choice_brackets != 0) {
        grammar.report_message(machine, .choice_blank);
    }
    try grammar.end_tag_if_necessary(machine, true);
    try machine.push_node(.newline, 0);
    try machine.wrap(.content_list, frame.locals[1]);
    const header = frame.locals[0];
    const header_data = &machine.workspace.scratch_data[header];
    if (bits & choice_brackets != 0) header_data.* |= header_weave_brackets;
    if (empty) header_data.* |= header_invisible_default;
    try machine.wrap(if (bits & choice_sticky != 0) .sticky_choice else .choice, header);
    return .succeed;
}

/// Interleave(OptionalExclude(Whitespace), String(bullet)): how many bullets.
fn bullets(machine: *Machine, bullet: u8) u32 {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    var count: u32 = 0;
    while (true) {
        _ = grammar.whitespace(machine);
        if (!grammar.parse_string(machine, &.{bullet})) break;
        count += 1;
    }
    if (count == 0) machine.at = start;
    return count;
}

/// BracketedName: `(name)`; pushes the identifier.
fn bracketed_name(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    const saved_tokens = machine.tokens_count;
    if (!grammar.parse_string(machine, "(")) return false;
    _ = grammar.whitespace(machine);
    if (!try grammar.push_identifier(machine)) {
        machine.at = start;
        machine.tokens_count = saved_tokens;
        return false;
    }
    _ = grammar.whitespace(machine);
    grammar.expect_string(machine, ")", .closing_parenthesis);
    return true;
}

/// ChoiceSingleCondition: `{expression}`.
pub fn choice_single_condition(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .choice_single_condition);
    assert(machine.at <= machine.source.len);
    if (frame.phase == 0) {
        if (!grammar.parse_string(machine, "{")) return .fail;
        frame.locals[0] = machine.scratch_count;
        frame.phase = 1;
        machine.argument = 0;
        return .{ .call = .expression };
    }
    if (machine.outcome == .failed) {
        grammar.report_expected(machine, .choice_condition);
        grammar.expect_string(machine, "}", .closing_brace);
        return .fail;
    }
    @import("grammar_content.zig").disallow_increment(machine, frame.locals[0]);
    grammar.expect_string(machine, "}", .closing_brace);
    return .succeed;
}

/// Gather: dashes, an optional label, and an optional newline.
pub fn gather(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .gather);
    assert(frame.phase == 0);
    const depth = gather_dashes(machine);
    if (depth == 0) return .fail;
    const marker = machine.scratch_count;
    try machine.push_node(.header, depth);
    if (!try bracketed_name(machine)) try grammar.push_none(machine);
    _ = grammar.newline_direct(machine);
    try machine.wrap(.gather, marker);
    return .succeed;
}

/// GatherDashes: dashes that aren't arrows, with whitespace; their count (0 restores).
pub fn gather_dashes(machine: *Machine) u32 {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = grammar.at(machine);
    _ = grammar.whitespace(machine);
    var count: u32 = 0;
    while (dash_not_arrow(machine)) {
        count += 1;
        _ = grammar.whitespace(machine);
    }
    if (count == 0) machine.at = start;
    return count;
}

/// ParseDashNotArrow.
pub fn dash_not_arrow(machine: *Machine) bool {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const text = grammar.rest(machine);
    assert(machine.at <= machine.source.len);
    if (std.mem.startsWith(u8, text, "->") or text.len == 0 or text[0] != '-') return false;
    machine.at += 1;
    return true;
}

// Diverts.

/// MultiDivert: a thread, or arrows and targets (diverts, tunnels, `->->`, a bare `->`).
/// locals: the marker, how many arrows and targets, and 1 + the index of the first `->->`.
pub fn multi_divert(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .multi_divert);
    assert(machine.at <= machine.source.len);
    switch (frame.phase) {
        0 => {
            frame.locals[0] = machine.scratch_count;
            _ = grammar.whitespace(machine);
            frame.phase = 1;
            return .{ .call = .start_thread };
        },
        1 => {
            if (machine.outcome == .succeeded) return .succeed;
            if (!divert_arrow(machine, frame)) return .fail;
            frame.phase = 2;
            return .{ .call = .divert_identifier_with_arguments };
        },
        else => {
            if (machine.outcome == .succeeded) {
                frame.locals[1] += 1;
                // Interleave stops at the end of the input, even after an arrow.
                if (divert_arrow(machine, frame) and !grammar.at_end(machine)) {
                    return .{ .call = .divert_identifier_with_arguments };
                }
            }
            try finish_multi_divert(machine, frame);
            return .succeed;
        },
    }
}

/// ParseDivertArrowOrTunnelOnwards, counted into the frame.
fn divert_arrow(machine: *Machine, frame: *Frame) bool {
    assert(machine.at <= machine.source.len);
    assert(frame.rule == .multi_divert);
    var arrows: u32 = 0;
    while (grammar.parse_string(machine, "->")) arrows += 1;
    if (arrows == 0) return false;
    if (arrows > 2) grammar.report_message(machine, .too_many_arrows);
    if (arrows >= 2 and frame.locals[2] == 0) frame.locals[2] = frame.locals[1] + 1;
    frame.locals[1] += 1;
    return true;
}

/// MultiDivert's pass over the arrows and targets: tunnels, `->->` and the bare `->`.
fn finish_multi_divert(machine: *Machine, frame: *Frame) Error!void {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const marker = frame.locals[0];
    const count = frame.locals[1];
    const workspace = machine.workspace;
    // A target is element 2k+1, value marker+k; one followed by an arrow is a tunnel.
    const onwards = frame.locals[2];
    const targets_before = if (onwards == 0) count / 2 else (onwards - 1) / 2;
    for (0..targets_before) |k| {
        if (2 * k + 1 < count - 1) workspace.scratch_tags[marker + k] = .tunnel;
    }
    if (onwards != 0) {
        const index = onwards - 1;
        if (!(index == 0 or index == count - 1 or index == count - 2)) {
            grammar.report_message(machine, .tunnel_onwards_placement);
        }
        const has_after = index < count - 1;
        machine.scratch_count = marker + targets_before + @intFromBool(has_after);
        if (!has_after) try grammar.push_none(machine);
        try machine.wrap(.tunnel_onwards, marker + targets_before);
    } else if (count == 1) {
        try machine.push_node(.empty_divert, grammar.at(machine));
        if (machine.plain_flags & grammar.parsing_choice == 0) {
            grammar.report_message(machine, .empty_divert_outside_choice);
        }
    }
    if (machine.flags & grammar.tag_active != 0) try grammar.insert_node(
        machine,
        marker,
        .tag_end,
        0,
    );
    machine.flags &= ~grammar.tag_active;
}

/// StartThread: `<-` and a target.
pub fn start_thread(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .start_thread);
    if (frame.phase == 0) {
        _ = grammar.whitespace(machine);
        if (!grammar.parse_string(machine, "<-")) return .fail;
        _ = grammar.whitespace(machine);
        frame.phase = 1;
        return .{ .call = .divert_identifier_with_arguments };
    }
    if (machine.outcome == .failed) {
        grammar.report_expected(machine, .divert_target);
        const marker = machine.scratch_count;
        try grammar.push_missing(machine);
        try grammar.push_none(machine);
        try machine.wrap(.thread, marker);
        return .succeed;
    }
    assert(grammar.top_tag(machine, 0) == .divert);
    machine.workspace.scratch_tags[machine.scratch_count - 1] = .thread;
    return .succeed;
}

/// DivertIdentifierWithArguments: a dotted path and optional arguments.
pub fn divert_identifier_with_arguments(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .divert_identifier_with_arguments);
    assert(machine.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.scratch_count;
        _ = grammar.whitespace(machine);
        if (!try divert_path(machine)) return .fail;
        _ = grammar.whitespace(machine);
        frame.phase = 1;
        return .{ .call = .function_call_arguments };
    }
    if (machine.outcome == .failed) try grammar.push_none(machine);
    _ = grammar.whitespace(machine);
    try machine.wrap(.divert, frame.locals[0]);
    return .succeed;
}

/// DotSeparatedDivertPathComponents: Interleave(Spaced(Identifier), Exclude(String("."))).
fn divert_path(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const marker = machine.scratch_count;
    while (true) {
        const start = grammar.at(machine);
        _ = grammar.whitespace(machine);
        if (!try grammar.push_identifier(machine)) {
            machine.at = start;
            break;
        }
        _ = grammar.whitespace(machine);
        if (!grammar.parse_string(machine, ".")) break;
    }
    if (machine.scratch_count == marker) return false;
    try machine.wrap(.path, marker);
    return true;
}

/// SingleDivert: a multi-divert that is one plain divert (or thread, or bare `->`).
pub fn single_divert(machine: *Machine, frame: *Frame) Error!Action {
    assert(frame.rule == .single_divert);
    assert(machine.at <= machine.source.len);
    if (frame.phase == 0) {
        frame.locals[0] = machine.scratch_count;
        frame.phase = 1;
        return .{ .call = .multi_divert };
    }
    if (machine.outcome == .failed) return .fail;
    if (machine.scratch_count != frame.locals[0] + 1) return .fail;
    const tag = grammar.top_tag(machine, frame.locals[0]).?;
    if (tag == .tunnel or tag == .tunnel_onwards or tag == .tag_end) return .fail;
    return .succeed;
}

comptime {
    assert(choice_inner < 1 << choice_conditions_shift);
    assert(@sizeOf(ast.Tag) == 1);
}
