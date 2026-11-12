//! ink's grammar (plan §4.11, P7.4-P7.8), ported from InkParser*.cs onto the parser core:
//! each InkParser method that can (indirectly) recurse is a rule of the machine; the purely
//! lexical ones are helper functions here. The rules live in grammar_statements.zig,
//! grammar_content.zig, grammar_weave.zig and grammar_expressions.zig; this file has the rule
//! set, the dispatch, ink's flags and StringParser's character-level primitives.
//!
//! The tree mirrors ink's parsed objects: statement lists are flat (a line's content is
//! spliced into its statement list, as ink's Interleave flattens), and choices and gathers
//! carry their indentation depth; weaves are built later from the depths, as ink's Weave
//! class does.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core.zig");
const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");
const limits = @import("../core/limits.zig");
const statements = @import("grammar_statements.zig");
const content = @import("grammar_content.zig");
const weave = @import("grammar_weave.zig");
const expressions = @import("grammar_expressions.zig");

pub const Grammar = struct {
    pub const Rule = enum {
        story,
        statements,
        statement,
        statements_break,
        knot_definition,
        knot_declaration,
        stitch_definition,
        stitch_declaration,
        declaration_line,
        logic_line,
        line_of_mixed_text_and_logic,
        mixed_text_and_logic,
        inline_logic_or_glue_or_start_tag,
        inline_logic,
        inner_logic,
        condition_expression,
        inner_conditional_content,
        single_multiline_condition,
        inner_sequence,
        inner_sequence_objects,
        single_multiline_sequence_element,
        inner_expression,
        multi_divert,
        start_thread,
        divert_identifier_with_arguments,
        single_divert,
        choice,
        choice_single_condition,
        gather,
        return_statement,
        temp_declaration_or_assignment,
        expression,
        expression_unary,
        expression_paren,
        expression_function_call,
        function_call_arguments,
        expression_string,
        expression_divert_target,
    };

    pub fn step(machine: *Machine, frame: *Machine.Frame) Action {
        assert(frame.phase < 64);
        assert(machine.tokenizer.at <= machine.source.len);
        assert(machine.frames_count > 0);
        const result = switch (frame.rule) {
            .story => statements.story(machine, frame),
            .statements => statements.statements(machine, frame),
            .statement => statements.statement(machine, frame),
            .statements_break => statements.statements_break(machine, frame),
            .knot_definition => statements.knot_definition(machine, frame),
            .knot_declaration => statements.knot_declaration(machine, frame),
            .stitch_definition => statements.stitch_definition(machine, frame),
            .stitch_declaration => statements.stitch_declaration(machine, frame),
            .declaration_line => statements.declaration_line(machine, frame),
            .logic_line => statements.logic_line(machine, frame),
            .return_statement => statements.return_statement(machine, frame),
            .temp_declaration_or_assignment => statements.temp_declaration_or_assignment(
                machine,
                frame,
            ),
            .line_of_mixed_text_and_logic => content.line_of_mixed_text_and_logic(machine, frame),
            .mixed_text_and_logic => content.mixed_text_and_logic(machine, frame),
            .inline_logic_or_glue_or_start_tag => content.inline_logic_or_glue_or_start_tag(
                machine,
                frame,
            ),
            .inline_logic => content.inline_logic(machine, frame),
            .inner_logic => content.inner_logic(machine, frame),
            .condition_expression => content.condition_expression(machine, frame),
            .inner_conditional_content => content.inner_conditional_content(machine, frame),
            .single_multiline_condition => content.single_multiline_condition(machine, frame),
            .inner_sequence => content.inner_sequence(machine, frame),
            .inner_sequence_objects => content.inner_sequence_objects(machine, frame),
            .single_multiline_sequence_element => content.single_multiline_sequence_element(
                machine,
                frame,
            ),
            .inner_expression => content.inner_expression(machine, frame),
            .multi_divert => weave.multi_divert(machine, frame),
            .start_thread => weave.start_thread(machine, frame),
            .divert_identifier_with_arguments => weave.divert_identifier_with_arguments(
                machine,
                frame,
            ),
            .single_divert => weave.single_divert(machine, frame),
            .choice => weave.choice(machine, frame),
            .choice_single_condition => weave.choice_single_condition(machine, frame),
            .gather => weave.gather(machine, frame),
            .expression => expressions.expression(machine, frame),
            .expression_unary => expressions.expression_unary(machine, frame),
            .expression_paren => expressions.expression_paren(machine, frame),
            .expression_function_call => expressions.expression_function_call(machine, frame),
            .function_call_arguments => expressions.function_call_arguments(machine, frame),
            .expression_string => expressions.expression_string(machine, frame),
            .expression_divert_target => expressions.expression_divert_target(machine, frame),
        };
        return result catch |err| switch (err) {
            // The workspace is too small: fail everything; the caller retries larger.
            error.WorkspaceFull => {
                machine.abandoned = true;
                machine.workspace_full = true;
                return .fail;
            },
        };
    }
};

pub const Machine = core.Machine(Grammar);
pub const Frame = Machine.Frame;
pub const Rule = Grammar.Rule;
pub const Action = core.Action(Rule);
pub const Error = core.Error;

/// ink's StatementLevel.
pub const Level = enum(u32) { inner_block, stitch, knot, top };

/// Flags restored by backtracking (ink's CustomFlags).
pub const parsing_string: u32 = 0x1;
pub const tag_active: u32 = 0x2;
/// Set when a function call is parsed: LogicLine wraps such lines (ink's Find<FunctionCall>).
pub const saw_function_call: u32 = 0x4;
/// A plain flag (not restored): ink's _parsingChoice.
pub const parsing_choice: u32 = 0x1;

/// What an `expected` diagnostic expected (its `extra`).
pub const Expectation = enum(u32) {
    end_of_line,
    knot_content,
    stitch_content,
    closing_parenthesis,
    closing_bracket,
    closing_brace,
    closing_quote,
    variable_name,
    equals,
    expression,
    inner_logic,
    conditional_content,
    sequence_elements,
    choice_condition,
    divert_target,
    list_items,
    list_item_value,
    external_name,
    external_parameters,
    include_filename,
    function_name_whitespace,
    right_operand,
    sequence_annotation,
};

/// ink's other errors and warnings (a `message` diagnostic's `extra`).
pub const Message = enum(u32) {
    tilde_in_content,
    gather_in_inner_block,
    return_at_top_level,
    return_without_tilde,
    logic_line_expression,
    include_with_tilde,
    increment_not_allowed,
    empty_divert_outside_choice,
    tunnel_onwards_placement,
    too_many_arrows,
    choice_empty,
    choice_blank,
    inline_conditional_alternatives,
    else_not_final,
    multiple_else,
    branch_without_condition,
    condition_block_without_conditions,
    expected_else,
    branch_without_content,
    tag_in_string,
    string_with_divert,
    increment_target,
    variable_initial_value,
    list_with_var,
    constant_initial_value,
    constant_string_logic,
    sequence_combination,
    knot_name_missing,
    ref_without_name,
    parameter_name_missing,
    list_item_closing_parenthesis,
    plus_minus,
    expected_equals,
    only_final_branch_else,
    integer_out_of_range,
};

pub fn report_expected(machine: *Machine, expectation: Expectation) void {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    machine.report(.expected, machine.tokenizer.at, @backingInt(expectation));
}

/// Expect(String(literal)): consumes it, or reports what was expected.
pub fn expect_string(machine: *Machine, literal: []const u8, expectation: Expectation) void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(literal.len > 0);
    if (parse_string(machine, literal)) return;
    report_expected(machine, expectation);
}

pub fn report_message(machine: *Machine, message: Message) void {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    machine.report(.message, machine.tokenizer.at, @backingInt(message));
}

// StringParser's character-level primitives.

pub fn at(machine: *const Machine) u32 {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    return machine.tokenizer.at;
}

pub fn rest(machine: *const Machine) []const u8 {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    return machine.source[machine.tokenizer.at..];
}

pub fn at_end(machine: *const Machine) bool {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    return machine.tokenizer.at == machine.source.len;
}

/// ParseString: consumes `literal` if the input starts with it.
pub fn parse_string(machine: *Machine, literal: []const u8) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(literal.len > 0);
    if (!std.mem.startsWith(u8, rest(machine), literal)) return false;
    machine.tokenizer.at += @intCast(literal.len);
    return true;
}

/// Whitespace: one or more spaces and tabs.
pub fn whitespace(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    while (!at_end(machine) and (rest(machine)[0] == ' ' or rest(machine)[0] == '\t')) {
        machine.tokenizer.at += 1;
    }
    return at(machine) > start;
}

/// ParseNewline: an optional `\r` and a `\n`; nothing is consumed if there is no `\n`.
pub fn parse_newline(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    _ = parse_string(machine, "\r");
    if (parse_string(machine, "\n")) return true;
    machine.tokenizer.at = start;
    return false;
}

/// Newline called directly: whitespace is consumed even when no newline follows.
pub fn newline_direct(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = whitespace(machine);
    return parse_newline(machine);
}

/// Newline through Parse or OneOf: on failure, nothing is consumed.
pub fn newline(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    if (newline_direct(machine)) return true;
    machine.tokenizer.at = start;
    return false;
}

/// EndOfFile through OneOf.
pub fn end_of_file(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    _ = whitespace(machine);
    if (at_end(machine)) return true;
    machine.tokenizer.at = start;
    return false;
}

/// EndOfLine: OneOf(Newline, EndOfFile).
pub fn end_of_line(machine: *Machine) bool {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    assert(machine.tokenizer.at <= machine.source.len);
    return newline(machine) or end_of_file(machine);
}

/// MultilineWhitespace: one or more newlines.
pub fn multiline_whitespace(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    var count: u32 = 0;
    while (newline(machine)) count += 1;
    return count > 0;
}

/// AnyWhitespace: any mix of whitespace and newlines.
pub fn any_whitespace(machine: *Machine) bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    var any = false;
    while (whitespace(machine) or multiline_whitespace(machine)) any = true;
    return any;
}

/// ParseUntilCharactersFromString("\n\r"): the rest of the line (maybe empty).
pub fn until_line_end(machine: *Machine) struct { start: u32, end: u32 } {
    assert(machine.tokenizer.at <= machine.source.len);
    const start = at(machine);
    const end = std.mem.indexOfAnyPos(u8, machine.source, start, "\n\r") orelse machine.source.len;
    machine.tokenizer.at = @intCast(end);
    assert(end >= start);
    return .{ .start = start, .end = @intCast(end) };
}

/// SkipToNextLine, the usual recovery rule.
pub fn skip_to_next_line(machine: *Machine) void {
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    _ = until_line_end(machine);
    _ = parse_newline(machine);
    assert(machine.tokenizer.at <= machine.source.len);
}

/// Expect(EndOfLine, ..., recoveryRule: SkipToNextLine).
pub fn expect_end_of_line(machine: *Machine) void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    if (end_of_line(machine)) return;
    report_expected(machine, .end_of_line);
    skip_to_next_line(machine);
}

/// Identifier: a run of identifier characters that isn't only digits; its token.
pub fn identifier(machine: *Machine) Error!?ast.TokenIndex {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    const length = tokenizer.identifier_length(rest(machine)) orelse return null;
    const text = rest(machine)[0..length];
    for (text) |character| {
        if (!std.ascii.isDigit(character)) break;
    } else return null;
    machine.tokenizer.at += length;
    return try machine.add_token(.word, start, start + length);
}

/// The text of a word token (or of any token).
pub fn token_text(machine: *const Machine, token: ast.TokenIndex) []const u8 {
    assert(machine.tokenizer.at <= machine.source.len);
    const workspace = machine.workspace;
    assert(token.to_int() < machine.tokens_count);
    const start = workspace.token_starts[token.to_int()];
    return machine.source[start..workspace.token_ends[token.to_int()]];
}

/// Parse(Identifier) == word: consumes the identifier only if it is `word`.
pub fn keyword(machine: *Machine, word: []const u8) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const start = at(machine);
    const saved_tokens = machine.tokens_count;
    const token = try identifier(machine) orelse return false;
    if (std.mem.eql(u8, token_text(machine, token), word)) return true;
    machine.tokenizer.at = start;
    machine.tokens_count = saved_tokens;
    return false;
}

/// Pushes an identifier leaf, or returns false if there is no identifier.
pub fn push_identifier(machine: *Machine) Error!bool {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    const token = try identifier(machine) orelse return false;
    try machine.push_node(.identifier, token.to_int());
    return true;
}

pub fn push_none(machine: *Machine) Error!void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    try machine.push_node(.none, 0);
}

pub fn push_missing(machine: *Machine) Error!void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    try machine.push_node(.missing, at(machine));
}

/// The tag of the top scratch value, if any above `marker`.
pub fn top_tag(machine: *const Machine, marker: u32) ?ast.Tag {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(marker <= machine.scratch_count);
    if (machine.scratch_count == marker) return null;
    return machine.workspace.scratch_tags[machine.scratch_count - 1];
}

/// Reserved words that can't be variable names (ink's Story.IsReservedKeyword).
pub fn is_reserved_keyword(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));
    const words = [_][]const u8{
        "true", "false", "not", "return", "else", "VAR", "CONST", "temp", "LIST", "function",
    };
    for (words) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

// Scratch stack edits.

/// Inserts a value at scratch `position`, moving the values above it up.
pub fn insert_node(machine: *Machine, position: u32, tag: ast.Tag, data: u32) Error!void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(position <= machine.scratch_count);
    try machine.push_node(.none, 0);
    const workspace = machine.workspace;
    var index = machine.scratch_count - 1;
    while (index > position) : (index -= 1) {
        workspace.scratch_tags[index] = workspace.scratch_tags[index - 1];
        workspace.scratch_data[index] = workspace.scratch_data[index - 1];
    }
    workspace.scratch_tags[position] = tag;
    workspace.scratch_data[position] = data;
}

/// Swaps the top two scratch values.
pub fn swap_top(machine: *Machine) void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count >= 2);
    const workspace = machine.workspace;
    const top = machine.scratch_count - 1;
    std.mem.swap(ast.Tag, &workspace.scratch_tags[top], &workspace.scratch_tags[top - 1]);
    std.mem.swap(u32, &workspace.scratch_data[top], &workspace.scratch_data[top - 1]);
}

/// EndTagIfNecessary: ends an active tag, adding its end marker to the content being built
/// (if there is a list to add it to).
pub fn end_tag_if_necessary(machine: *Machine, into_list: bool) Error!void {
    assert(machine.tokenizer.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    if (machine.flags & tag_active == 0) return;
    if (into_list) try machine.push_node(.tag_end, 0);
    machine.flags &= ~tag_active;
}

// Entry point.

/// A parsed file: the tree, its tokens and diagnostics, over the comment-free source.
pub const Parsed = struct {
    source: []const u8,
    tree: ast.Ast,
    workspace: core.Workspace,
    tokens_count: u32,
    diagnostics_count: u32,
    buffer: []u8,
    /// With parse_space: each region's story root (the first is `tree.root`).
    roots: []const ast.NodeIndex = &.{},

    pub fn diagnostics(parsed: *const Parsed) []const core.Diagnostic {
        assert(parsed.buffer.len >= parsed.source.len);
        assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
        return parsed.workspace.diagnostics[0..parsed.diagnostics_count];
    }

    pub fn deinit(parsed: *Parsed, gpa: std.mem.Allocator) void {
        assert(parsed.tokens_count <= parsed.workspace.token_tags.len);
        assert(parsed.buffer.len >= parsed.source.len);
        parsed.workspace.deinit(gpa);
        gpa.free(parsed.buffer);
        if (parsed.roots.len > 0) gpa.free(parsed.roots);
        parsed.* = undefined;
    }
};

/// Parses one ink file (ink's InkParser.Parse): comments are removed first, and a full
/// workspace is retried with twice the room (plan T15).
pub fn parse(gpa: std.mem.Allocator, source: []const u8, bounds: limits.CompilerLimits) !Parsed {
    assert(bounds.parse_depth_max > 0);
    assert(source.len <= bounds.source_bytes_max);
    const buffer = try gpa.alloc(u8, source.len);
    errdefer gpa.free(buffer);
    const clean = tokenizer.eliminate_comments(source, buffer);
    const frames = try gpa.alloc(Frame, bounds.parse_depth_max);
    defer gpa.free(frames);
    var scale: u32 = 1;
    for (0..bounds.compile_retries_max + 1) |_| {
        var workspace = try core.Workspace.init(
            gpa,
            @intCast(clean.len),
            bounds.diagnostics_max,
            scale,
        );
        errdefer workspace.deinit(gpa);
        var machine: Machine = .init(clean, &workspace, frames);
        const outcome = machine.run(.story) catch |err| switch (err) {
            error.WorkspaceFull => core.Outcome.failed,
        };
        if (!machine.workspace_full and outcome == .succeeded) {
            const tree = try machine.finish();
            return .{
                .source = clean,
                .tree = tree,
                .workspace = workspace,
                .tokens_count = machine.tokens_count,
                .diagnostics_count = machine.diagnostics_count,
                .buffer = buffer,
            };
        }
        workspace.deinit(gpa);
        if (!machine.workspace_full) return error.ParseFailed;
        scale *= 2;
    }
    return error.WorkspaceFull;
}

/// A file's range in a shared source space.
pub const Region = struct { start: u32, end: u32 };

/// Parses each region of `buffer` (comment-free files laid end to end, plan §4.11) into one
/// tree, so token and node indices are global. Takes ownership of `buffer`.
pub fn parse_space(
    gpa: std.mem.Allocator,
    buffer: []u8,
    regions: []const Region,
    bounds: limits.CompilerLimits,
) !Parsed {
    assert(regions.len > 0);
    errdefer gpa.free(buffer);
    const frames = try gpa.alloc(Frame, bounds.parse_depth_max);
    defer gpa.free(frames);
    const roots = try gpa.alloc(ast.NodeIndex, regions.len);
    errdefer gpa.free(roots);
    var scale: u32 = 1;
    for (0..bounds.compile_retries_max + 1) |_| {
        const length: u32 = @intCast(buffer.len);
        var workspace = try core.Workspace.init(gpa, length, bounds.diagnostics_max, scale);
        errdefer workspace.deinit(gpa);
        var machine: Machine = .init(buffer, &workspace, frames);
        if (try parse_regions(&machine, buffer, regions, roots)) {
            return .{
                .source = buffer,
                .tree = machine.finish_regions(roots[0]),
                .workspace = workspace,
                .tokens_count = machine.tokens_count,
                .diagnostics_count = machine.diagnostics_count,
                .buffer = buffer,
                .roots = roots,
            };
        }
        workspace.deinit(gpa);
        if (!machine.workspace_full) return error.ParseFailed;
        scale *= 2;
    }
    return error.WorkspaceFull;
}

/// Whether every region parsed (false: retry with more room if the workspace was full).
fn parse_regions(
    machine: *Machine,
    buffer: []const u8,
    regions: []const Region,
    roots: []ast.NodeIndex,
) !bool {
    assert(roots.len == regions.len);
    for (regions, roots) |region, *root| {
        assert(region.start <= region.end and region.end <= buffer.len);
        machine.begin_region(buffer[0..region.end], region.start);
        const outcome = machine.run(.story) catch |err| switch (err) {
            error.WorkspaceFull => core.Outcome.failed,
        };
        if (machine.workspace_full or outcome != .succeeded) return false;
        root.* = machine.commit_root() catch {
            machine.workspace_full = true;
            return false;
        };
    }
    return true;
}
