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
const profile = @import("../core/profile.zig");
const core = @import("core.zig");
const ast = @import("ast.zig");
const lexical = @import("lexical.zig");
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

    /// Runs the rule's step function: the function of the rule's name in the grammar modules.
    pub fn step(machine: *Machine, frame: *Machine.Frame) Action {
        assert(frame.phase < 64);
        const result = switch (frame.rule) {
            inline else => |rule| rule_function(rule)(machine, frame),
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

    /// The one function named `rule` in the grammar modules.
    fn rule_function(comptime rule: Grammar.Rule) fn (*Machine, *Frame) Error!Action {
        const name = @tagName(rule);
        var found: ?fn (*Machine, *Frame) Error!Action = null;
        for (.{ statements, content, weave, expressions }) |module| {
            if (!@hasDecl(module, name)) continue;
            if (found != null) @compileError("two grammar modules define rule " ++ name);
            found = @field(module, name);
        }
        return found orelse @compileError("no grammar module defines rule " ++ name);
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
    assert(machine.at <= machine.source.len);
    machine.report(.expected, machine.at, @backingInt(expectation));
}

/// Expect(String(literal)): consumes it, or reports what was expected.
pub fn expect_string(machine: *Machine, literal: []const u8, expectation: Expectation) void {
    assert(machine.at <= machine.source.len);
    assert(literal.len > 0);
    if (parse_string(machine, literal)) return;
    report_expected(machine, expectation);
}

pub fn report_message(machine: *Machine, message: Message) void {
    assert(machine.at <= machine.source.len);
    machine.report(.message, machine.at, @backingInt(message));
}

// StringParser's character-level primitives.

pub fn at(machine: *const Machine) u32 {
    assert(machine.at <= machine.source.len);
    return machine.at;
}

pub fn rest(machine: *const Machine) []const u8 {
    assert(machine.at <= machine.source.len);
    return machine.source[machine.at..];
}

pub fn at_end(machine: *const Machine) bool {
    assert(machine.at <= machine.source.len);
    return machine.at == machine.source.len;
}

/// ParseString: consumes `literal` if the input starts with it.
pub fn parse_string(machine: *Machine, literal: []const u8) bool {
    assert(machine.at <= machine.source.len);
    assert(literal.len > 0);
    if (!std.mem.startsWith(u8, rest(machine), literal)) return false;
    machine.at += @intCast(literal.len);
    return true;
}

/// Whitespace: one or more spaces and tabs.
pub fn whitespace(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    while (!at_end(machine) and (rest(machine)[0] == ' ' or rest(machine)[0] == '\t')) {
        machine.at += 1;
    }
    return at(machine) > start;
}

/// ParseNewline: an optional `\r` and a `\n`; nothing is consumed if there is no `\n`.
pub fn parse_newline(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    _ = parse_string(machine, "\r");
    if (parse_string(machine, "\n")) return true;
    machine.at = start;
    return false;
}

/// Newline called directly: whitespace is consumed even when no newline follows.
pub fn newline_direct(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    _ = whitespace(machine);
    return parse_newline(machine);
}

/// Newline through Parse or OneOf: on failure, nothing is consumed.
pub fn newline(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    if (newline_direct(machine)) return true;
    machine.at = start;
    return false;
}

/// EndOfFile through OneOf.
pub fn end_of_file(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    _ = whitespace(machine);
    if (at_end(machine)) return true;
    machine.at = start;
    return false;
}

/// EndOfLine: OneOf(Newline, EndOfFile).
pub fn end_of_line(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    return newline(machine) or end_of_file(machine);
}

/// MultilineWhitespace: one or more newlines.
pub fn multiline_whitespace(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    var count: u32 = 0;
    while (newline(machine)) count += 1;
    return count > 0;
}

/// AnyWhitespace: any mix of whitespace and newlines.
pub fn any_whitespace(machine: *Machine) bool {
    assert(machine.at <= machine.source.len);
    var any = false;
    while (whitespace(machine) or multiline_whitespace(machine)) any = true;
    return any;
}

/// ParseUntilCharactersFromString("\n\r"): the rest of the line (maybe empty).
pub fn until_line_end(machine: *Machine) struct { start: u32, end: u32 } {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    const end = std.mem.indexOfAnyPos(u8, machine.source, start, "\n\r") orelse machine.source.len;
    machine.at = @intCast(end);
    assert(end >= start);
    return .{ .start = start, .end = @intCast(end) };
}

/// SkipToNextLine, the usual recovery rule.
pub fn skip_to_next_line(machine: *Machine) void {
    _ = until_line_end(machine);
    _ = parse_newline(machine);
    assert(machine.at <= machine.source.len);
}

/// Expect(EndOfLine, ..., recoveryRule: SkipToNextLine).
pub fn expect_end_of_line(machine: *Machine) void {
    assert(machine.at <= machine.source.len);
    if (end_of_line(machine)) return;
    report_expected(machine, .end_of_line);
    skip_to_next_line(machine);
}

/// Identifier: a run of identifier characters that isn't only digits; its token.
pub fn identifier(machine: *Machine) Error!?ast.TokenIndex {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    const length = lexical.identifier_length(rest(machine)) orelse return null;
    const text = rest(machine)[0..length];
    for (text) |character| {
        if (!std.ascii.isDigit(character)) break;
    } else return null;
    machine.at += length;
    return try machine.add_token(start, start + length);
}

/// The text of a word token (or of any token).
pub fn token_text(machine: *const Machine, token: ast.TokenIndex) []const u8 {
    assert(machine.at <= machine.source.len);
    const workspace = machine.workspace;
    assert(token.to_int() < machine.tokens_count);
    const start = workspace.token_starts[token.to_int()];
    return machine.source[start..workspace.token_ends[token.to_int()]];
}

/// Parse(Identifier) == word: consumes the identifier only if it is `word`.
pub fn keyword(machine: *Machine, word: []const u8) Error!bool {
    assert(machine.at <= machine.source.len);
    const start = at(machine);
    const saved_tokens = machine.tokens_count;
    const token = try identifier(machine) orelse return false;
    if (std.mem.eql(u8, token_text(machine, token), word)) return true;
    machine.at = start;
    machine.tokens_count = saved_tokens;
    return false;
}

/// Pushes an identifier leaf, or returns false if there is no identifier.
pub fn push_identifier(machine: *Machine) Error!bool {
    assert(machine.at <= machine.source.len);
    const token = try identifier(machine) orelse return false;
    try machine.push_node(.identifier, token.to_int());
    return true;
}

/// Expect(Identifier): pushes an identifier leaf, or reports what was expected and pushes a
/// missing one.
pub fn expect_identifier(machine: *Machine, expectation: Expectation) Error!void {
    if (try push_identifier(machine)) return;
    report_expected(machine, expectation);
    try push_missing(machine);
}

pub fn push_none(machine: *Machine) Error!void {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    try machine.push_node(.none, 0);
}

pub fn push_missing(machine: *Machine) Error!void {
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
    try machine.push_node(.missing, at(machine));
}

/// The tag of the top scratch value, if any above `marker`.
pub fn top_tag(machine: *const Machine, marker: u32) ?ast.Tag {
    assert(machine.at <= machine.source.len);
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
    assert(machine.at <= machine.source.len);
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
    assert(machine.at <= machine.source.len);
    assert(machine.scratch_count >= 2);
    const workspace = machine.workspace;
    const top = machine.scratch_count - 1;
    std.mem.swap(ast.Tag, &workspace.scratch_tags[top], &workspace.scratch_tags[top - 1]);
    std.mem.swap(u32, &workspace.scratch_data[top], &workspace.scratch_data[top - 1]);
}

/// EndTagIfNecessary: ends an active tag, adding its end marker to the content being built
/// (if there is a list to add it to).
pub fn end_tag_if_necessary(machine: *Machine, into_list: bool) Error!void {
    assert(machine.at <= machine.source.len);
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
    /// How many times the source was parsed: more than 1 when the workspace was too small.
    attempts: u32 = 1,

    pub fn diagnostics(parsed: *const Parsed) []const core.Diagnostic {
        assert(parsed.buffer.len >= parsed.source.len);
        assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
        return parsed.workspace.diagnostics[0..parsed.diagnostics_count];
    }

    /// Frees the syntax tree and the tokens once the IR is lowered (plan P8.6), keeping the
    /// source (the IR's names are slices of it) and the diagnostics.
    pub fn release_syntax(parsed: *Parsed, gpa: std.mem.Allocator) void {
        assert(parsed.tokens_count <= parsed.workspace.token_starts.len);
        assert(parsed.tree.tags.ptr == parsed.workspace.node_tags.ptr);
        parsed.workspace.release_syntax(gpa);
        parsed.tree.tags = &.{};
        parsed.tree.data = &.{};
        parsed.tokens_count = 0;
    }

    pub fn deinit(parsed: *Parsed, gpa: std.mem.Allocator) void {
        assert(parsed.tokens_count <= parsed.workspace.token_starts.len);
        assert(parsed.buffer.len >= parsed.source.len);
        parsed.workspace.deinit(gpa);
        gpa.free(parsed.buffer);
        if (parsed.roots.len > 0) gpa.free(parsed.roots);
        parsed.* = undefined;
    }
};

/// Parses one ink file (ink's InkParser.Parse): comments are removed first, then the file is
/// one region of `parse_space`.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, bounds: limits.CompilerLimits) !Parsed {
    assert(source.len <= bounds.source_bytes_max);
    const buffer = try gpa.alloc(u8, source.len);
    const comments_zone = profile.begin(.compile_comments);
    const length: u32 = @intCast(lexical.eliminate_comments(source, buffer).len);
    comments_zone.end();
    const clean = gpa.realloc(buffer, length) catch |err| {
        gpa.free(buffer);
        return err;
    };
    return parse_space(gpa, clean, &.{.{ .start = 0, .end = length }}, bounds);
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
    for (0..bounds.compile_retries_max + 1, 1..) |_, attempt| {
        const length: u32 = @intCast(buffer.len);
        var workspace = try core.Workspace.init(gpa, length, bounds.diagnostics_max, scale);
        errdefer workspace.deinit(gpa);
        var machine: Machine = .init(buffer, &workspace, frames);
        if (try parse_regions(&machine, buffer, regions, roots)) {
            var tree = machine.finish_regions(roots[0]);
            try workspace.settle(gpa, machine.nodes_count, machine.tokens_count);
            tree.tags = workspace.node_tags;
            tree.data = workspace.node_data;
            return .{
                .source = buffer,
                .tree = tree,
                .workspace = workspace,
                .tokens_count = machine.tokens_count,
                .diagnostics_count = machine.diagnostics_count,
                .buffer = buffer,
                .roots = roots,
                .attempts = @intCast(attempt),
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

test "a dense story of short knots parses in one attempt" {
    // Goal: P12.2. The bench's generated story (0.43 nodes per byte) overflowed the workspace
    // and was parsed twice. Method: 300 of its knots, parsed; one attempt, and denser than
    // the old estimate of a node per 4 bytes.
    const gpa = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    try source.writer.writeAll("VAR score = 0\n-> knot_0\n");
    for (0..300) |index| {
        try source.writer.print(
            "=== knot_{d} ===\nYou are in room {d}. Score {{score}}.\n~ score = score + {d}\n" ++
                "* [Onwards] -> knot_{d}\n* [Skip ahead] Skipping. -> knot_{d}\n",
            .{ index, index, index % 5, (index + 1) % 300, (index + 7) % 300 },
        );
    }
    var parsed = try parse(gpa, source.written(), .{});
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), parsed.attempts);
    try std.testing.expectEqual(@as(u32, 0), parsed.diagnostics_count);
    try std.testing.expect(parsed.tree.tags.len > source.written().len / 4 + 256);
}
