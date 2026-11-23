//! ink's grammar, ported from InkParser*.cs onto the parser core:
//! each InkParser method that can (indirectly) recurse is a rule of the machine; the purely
//! lexical ones are helper functions here. The rules live in grammar_statements.zig,
//! grammar_content.zig, grammar_weave.zig and grammar_expressions.zig; this file has the rule
//! set, the dispatch, ink's flags and StringParser's character-level primitives.
//!
//! The tree mirrors ink's parsed objects: statement lists are flat (a line's content is
//! spliced into its statement list, as ink's Interleave flattens), and choices and gathers
//! carry their indentation depth; weaves are built later from the depths, as ink's Weave
//! class does.

// lint: allow assertion_density: StringParser's one-line primitives (at, rest, at_end,
// push_none, newline_direct, ...) have no precondition of their own; the parser machine
// asserts the input position and the stacks once per step (core.zig).

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
        } catch |err| switch (err) {
            // The workspace is too small: fail everything; the caller retries larger.
            error.WorkspaceFull => {
                machine.abandoned = true;
                machine.workspace_full = true;
                return .fail;
            },
        };
        // A rule that calls resumes in a later phase: phase 0 is its entry, and returning
        // to it would run the rule again from the start.
        switch (result) {
            .call, .peek => assert(frame.phase > 0),
            .succeed, .fail, .again => {},
        }
        return result;
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

    /// Whether a diagnostic is one of ink's warnings (it doesn't stop compilation).
    pub fn is_warning(diagnostic: core.Diagnostic) bool {
        assert(@backingInt(diagnostic.code) < 8);
        if (diagnostic.code != .message) return false;
        const message: Message = @fromBackingInt(@intCast(diagnostic.extra));
        return message == .return_without_tilde or message == .choice_empty or
            message == .choice_blank;
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

/// Calls `rule`; the frame goes on with `phase` (a later one: phase 0 is the entry).
pub fn call_then(frame: *Frame, phase: u8, rule: Rule) Action {
    assert(phase > 0);
    frame.phase = phase;
    return .{ .call = rule };
}

/// Calls `rule` with `argument` (ink's rule parameter); the frame goes on with `phase`.
pub fn call(machine: *Machine, frame: *Frame, phase: u8, rule: Rule, argument: u32) Action {
    machine.argument = argument;
    return call_then(frame, phase, rule);
}

pub fn report_expected(machine: *Machine, expectation: Expectation) void {
    machine.report(.expected, machine.at, @backingInt(expectation));
}

/// Expect(String(literal)): consumes it, or reports what was expected.
pub fn expect_string(machine: *Machine, literal: []const u8, expectation: Expectation) void {
    assert(literal.len > 0);
    if (parse_string(machine, literal)) return;
    report_expected(machine, expectation);
}

pub fn report_message(machine: *Machine, message: Message) void {
    machine.report(.message, machine.at, @backingInt(message));
}

// StringParser's character-level primitives.

pub fn at(machine: *const Machine) u32 {
    return machine.at;
}

pub fn rest(machine: *const Machine) []const u8 {
    return machine.source[machine.at..];
}

pub fn at_end(machine: *const Machine) bool {
    return machine.at == machine.source.len;
}

/// ParseString: consumes `literal` if the input starts with it.
pub fn parse_string(machine: *Machine, literal: []const u8) bool {
    assert(literal.len > 0);
    if (!std.mem.startsWith(u8, rest(machine), literal)) return false;
    machine.at += @intCast(literal.len);
    return true;
}

/// Whitespace: one or more spaces and tabs.
pub fn whitespace(machine: *Machine) bool {
    const start = at(machine);
    while (!at_end(machine) and (rest(machine)[0] == ' ' or rest(machine)[0] == '\t')) {
        machine.at += 1;
    }
    return at(machine) > start;
}

/// ParseNewline: an optional `\r` and a `\n`; nothing is consumed if there is no `\n`.
pub fn parse_newline(machine: *Machine) bool {
    const start = at(machine);
    _ = parse_string(machine, "\r");
    if (parse_string(machine, "\n")) {
        assert(at(machine) > start);
        return true;
    }
    machine.at = start;
    return false;
}

/// Newline called directly: whitespace is consumed even when no newline follows.
pub fn newline_direct(machine: *Machine) bool {
    _ = whitespace(machine);
    return parse_newline(machine);
}

/// Newline through Parse or OneOf: on failure, nothing is consumed.
pub fn newline(machine: *Machine) bool {
    const start = at(machine);
    if (newline_direct(machine)) return true;
    machine.at = start;
    return false;
}

/// EndOfFile through OneOf.
pub fn end_of_file(machine: *Machine) bool {
    const start = at(machine);
    _ = whitespace(machine);
    if (at_end(machine)) return true;
    machine.at = start;
    return false;
}

/// EndOfLine: OneOf(Newline, EndOfFile).
pub fn end_of_line(machine: *Machine) bool {
    const found = newline(machine) or end_of_file(machine);
    if (found) assert(at_end(machine) or machine.source[machine.at - 1] == '\n');
    return found;
}

/// MultilineWhitespace: one or more newlines.
pub fn multiline_whitespace(machine: *Machine) bool {
    var count: u32 = 0;
    while (newline(machine)) count += 1;
    if (count > 0) assert(machine.source[machine.at - 1] == '\n');
    return count > 0;
}

/// AnyWhitespace: any mix of whitespace and newlines.
pub fn any_whitespace(machine: *Machine) bool {
    var any = false;
    while (whitespace(machine) or multiline_whitespace(machine)) any = true;
    return any;
}

/// ParseUntilCharactersFromString("\n\r"): the rest of the line (maybe empty).
pub fn until_line_end(machine: *Machine) struct { start: u32, end: u32 } {
    const start = at(machine);
    const end = std.mem.indexOfAnyPos(u8, machine.source, start, "\n\r") orelse machine.source.len;
    machine.at = @intCast(end);
    assert(end >= start);
    assert(end == machine.source.len or machine.source[end] == '\n' or
        machine.source[end] == '\r');
    return .{ .start = start, .end = @intCast(end) };
}

/// SkipToNextLine, the usual recovery rule.
pub fn skip_to_next_line(machine: *Machine) void {
    _ = until_line_end(machine);
    _ = parse_newline(machine);
    // Past the line break, or stopped at a lone `\r` that is no newline.
    assert(at_end(machine) or machine.source[machine.at - 1] == '\n' or
        machine.source[machine.at] == '\r');
}

/// Expect(EndOfLine, ..., recoveryRule: SkipToNextLine).
pub fn expect_end_of_line(machine: *Machine) void {
    if (end_of_line(machine)) return;
    report_expected(machine, .end_of_line);
    skip_to_next_line(machine);
}

/// Identifier: a run of identifier characters that isn't only digits; its token.
pub fn identifier(machine: *Machine) Error!?ast.TokenIndex {
    const start = at(machine);
    const length = lexical.identifier_length(rest(machine)) orelse return null;
    assert(length > 0);
    const text = rest(machine)[0..length];
    for (text) |character| {
        if (!std.ascii.isDigit(character)) break;
    } else return null;
    machine.at += length;
    return try machine.add_token(start, start + length);
}

/// The text of a word token (or of any token).
pub fn token_text(machine: *const Machine, token: ast.TokenIndex) []const u8 {
    const workspace = machine.workspace;
    assert(token.to_int() < machine.tokens_count);
    const start = workspace.token_starts[token.to_int()];
    assert(start <= workspace.token_ends[token.to_int()]);
    return machine.source[start..workspace.token_ends[token.to_int()]];
}

/// Parse(Identifier) == word: consumes the identifier only if it is `word`.
pub fn keyword(machine: *Machine, word: []const u8) Error!bool {
    assert(word.len > 0);
    const start = at(machine);
    const saved_tokens = machine.tokens_count;
    const token = try identifier(machine) orelse return false;
    assert(token.to_int() == saved_tokens);
    if (std.mem.eql(u8, token_text(machine, token), word)) return true;
    machine.at = start;
    machine.tokens_count = saved_tokens;
    return false;
}

/// Pushes an identifier leaf, or returns false if there is no identifier.
pub fn push_identifier(machine: *Machine) Error!bool {
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
    try machine.push_node(.none, 0);
}

pub fn push_missing(machine: *Machine) Error!void {
    try machine.push_node(.missing, at(machine));
}

/// The tag of the top scratch value, if any above `marker`.
pub fn top_tag(machine: *const Machine, marker: u32) ?ast.Tag {
    assert(marker <= machine.scratch_count);
    if (machine.scratch_count == marker) return null;
    return machine.workspace.scratch_tags[machine.scratch_count - 1];
}

/// Reserved words that can't be variable names (ink's Story.IsReservedKeyword).
pub fn is_reserved_keyword(name: []const u8) bool {
    assert(name.len > 0);
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
    assert(machine.scratch_count >= 2);
    const workspace = machine.workspace;
    const top = machine.scratch_count - 1;
    std.mem.swap(ast.Tag, &workspace.scratch_tags[top], &workspace.scratch_tags[top - 1]);
    std.mem.swap(u32, &workspace.scratch_data[top], &workspace.scratch_data[top - 1]);
}

/// EndTagIfNecessary: ends an active tag, adding its end marker to the content being built
/// (if there is a list to add it to).
pub fn end_tag_if_necessary(machine: *Machine, into_list: bool) Error!void {
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
    /// Set when an error came after the diagnostics were full: the story still fails.
    errors_dropped: bool = false,
    buffer: []u8,
    /// Each file's story root (the first is `tree.root`).
    roots: []const ast.NodeIndex,
    /// How many times a file was parsed: once each, more when the workspace was too small.
    parses: u32,

    /// The parses beyond one per file: the retries a full workspace took.
    pub fn retries(parsed: *const Parsed) u32 {
        assert(parsed.parses >= parsed.roots.len);
        return parsed.parses - @as(u32, @intCast(parsed.roots.len));
    }

    pub fn diagnostics(parsed: *const Parsed) []const core.Diagnostic {
        assert(parsed.buffer.len >= parsed.source.len);
        assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
        return parsed.workspace.diagnostics[0..parsed.diagnostics_count];
    }

    /// The text of a leaf's token (empty for none or missing).
    pub fn leaf_text(parsed: *const Parsed, leaf: ast.NodeIndex) []const u8 {
        const tag = parsed.tree.tag(leaf);
        if (tag == .none or tag == .missing) return "";
        assert(ast.shape(tag) == .leaf);
        const token = parsed.tree.data[leaf.to_int()];
        assert(token < parsed.tokens_count);
        const workspace = &parsed.workspace;
        return parsed.source[workspace.token_starts[token]..workspace.token_ends[token]];
    }

    /// The text of the leaf in slot `which` of `node` (a name, mostly).
    pub fn slot_text(
        parsed: *const Parsed,
        node: ast.NodeIndex,
        comptime which: ast.Slot,
    ) []const u8 {
        assert(!node.is_none());
        return parsed.leaf_text(parsed.tree.slot(node, which));
    }

    /// Frees the syntax tree and the tokens once the IR is lowered, keeping the
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
        gpa.free(parsed.roots);
        parsed.* = undefined;
    }
};

pub const ParseError = error{
    /// The source is longer than `source_bytes_max`.
    SourceTooLarge,
    /// The input nests deeper than `parse_depth_max` (or stopped progressing): the parse
    /// was abandoned, so there is no tree.
    ParseFailed,
    /// The workspace was still too small after `compile_retries_max` doublings.
    WorkspaceFull,
} || std.mem.Allocator.Error;

/// Parses one ink file (ink's InkParser.Parse): a space of one file.
pub fn parse(
    gpa: std.mem.Allocator,
    source: []const u8,
    bounds: limits.CompilerLimits,
) ParseError!Parsed {
    assert(bounds.source_bytes_max > 0);
    var space = try SpaceParser.init(gpa, bounds);
    errdefer space.deinit(gpa);
    _ = try space.add(gpa, source);
    return space.finish(gpa);
}

/// Parses files one after another into one tree, so token and node indices are global:
/// each file's comments are removed and its text appended to the space, then it is parsed
/// as a region of its own. A file's INCLUDEs can be read from its region before the next
/// file is added.
pub const SpaceParser = struct {
    bounds: limits.CompilerLimits,
    /// The comment-free files, end to end.
    buffer: std.ArrayList(u8) = .empty,
    roots: std.ArrayList(ast.NodeIndex) = .empty,
    frames: []Frame,
    workspace: core.Workspace,
    /// Its workspace pointer is set on each use: the parser may move between calls.
    machine: Machine,
    /// Doubles each time a region finds the workspace full.
    scale: u32 = 1,
    parses: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, bounds: limits.CompilerLimits) !SpaceParser {
        assert(bounds.parse_depth_max > 0);
        const frames = try gpa.alloc(Frame, bounds.parse_depth_max);
        errdefer gpa.free(frames);
        return .{
            .bounds = bounds,
            .frames = frames,
            .workspace = try core.Workspace.init(gpa, 0, bounds.diagnostics_max, 1),
            .machine = .init("", undefined, frames),
        };
    }

    /// Frees a parser that wasn't finished (or whose finish failed).
    pub fn deinit(space: *SpaceParser, gpa: std.mem.Allocator) void {
        assert(space.frames.len > 0);
        space.workspace.deinit(gpa);
        space.buffer.deinit(gpa);
        space.roots.deinit(gpa);
        gpa.free(space.frames);
        space.* = undefined;
    }

    /// Appends a file and parses it: its region's story root. A full workspace grows and
    /// the region alone is parsed again, at most `compile_retries_max` times in all.
    pub fn add(
        space: *SpaceParser,
        gpa: std.mem.Allocator,
        source: []const u8,
    ) ParseError!ast.NodeIndex {
        const bounds = space.bounds;
        if (source.len > bounds.source_bytes_max) return error.SourceTooLarge;
        const start = space.buffer.items.len;
        try space.buffer.ensureTotalCapacityPrecise(gpa, start + source.len);
        try space.roots.ensureUnusedCapacity(gpa, 1);
        const comments_zone = profile.begin(.compile_comments);
        const clean = lexical.eliminate_comments(source, space.buffer.unusedCapacitySlice());
        comments_zone.end();
        // Each file is within the bound, but together they may not be: offsets are u32.
        if (start + clean.len > bounds.source_bytes_max) return error.SourceTooLarge;
        space.buffer.items.len += clean.len;
        const machine = &space.machine;
        machine.workspace = &space.workspace;
        const saved = machine.*;
        while (true) {
            try space.workspace.reserve(gpa, @intCast(space.buffer.items.len), space.scale, .{
                .nodes = machine.nodes_count,
                .tokens = machine.tokens_count,
                .diagnostics = machine.diagnostics_count,
            });
            space.parses += 1;
            machine.begin_region(space.buffer.items, @intCast(start));
            const outcome = machine.run(.story) catch |err| switch (err) {
                error.WorkspaceFull => core.Outcome.failed,
            };
            if (!machine.workspace_full and outcome == .succeeded) {
                if (machine.commit_root()) |root| {
                    space.roots.appendAssumeCapacity(root);
                    return root;
                } else |_| machine.workspace_full = true;
            }
            if (!machine.workspace_full) return error.ParseFailed;
            const retries = space.parses - space.roots.items.len;
            if (retries > bounds.compile_retries_max) return error.WorkspaceFull;
            // The region again, from where it started, with twice the room.
            machine.* = saved;
            space.scale *= 2;
        }
    }

    /// The parsed space; the parser is used up (on failure, `deinit` frees it).
    pub fn finish(space: *SpaceParser, gpa: std.mem.Allocator) !Parsed {
        assert(space.roots.items.len > 0);
        const machine = &space.machine;
        machine.workspace = &space.workspace;
        const roots = try space.roots.toOwnedSlice(gpa);
        errdefer gpa.free(roots);
        const buffer = try space.buffer.toOwnedSlice(gpa);
        errdefer gpa.free(buffer);
        var tree = machine.finish_regions(roots[0]);
        try space.workspace.settle(gpa, machine.nodes_count, machine.tokens_count);
        assert(space.workspace.node_tags.len == machine.nodes_count);
        tree.tags = space.workspace.node_tags;
        tree.data = space.workspace.node_data;
        gpa.free(space.frames);
        return .{
            .source = buffer,
            .tree = tree,
            .workspace = space.workspace,
            .tokens_count = machine.tokens_count,
            .diagnostics_count = machine.diagnostics_count,
            .errors_dropped = machine.errors_dropped,
            .buffer = buffer,
            .roots = roots,
            .parses = space.parses,
        };
    }
};

test "a dense story of short knots parses in one attempt" {
    // The bench's generated story (0.43 nodes per byte) overflowed the workspace
    // and was parsed twice. 300 of its knots, parsed; one attempt, and denser than
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
    try std.testing.expectEqual(@as(u32, 1), parsed.parses);
    try std.testing.expectEqual(@as(u32, 0), parsed.diagnostics_count);
    try std.testing.expect(parsed.tree.tags.len > source.written().len / 4 + 256);
}

test "the parser reports an unclosed brace" {
    // The old compile() ignored this error. The parse gets ink's diagnostics: the inner logic,
    // then the line end.
    const gpa = std.testing.allocator;
    var parsed = try parse(gpa, "Hello {unclosed\n", .{});
    defer parsed.deinit(gpa);
    try std.testing.expect(parsed.diagnostics_count > 0);
    const expected: u32 = @backingInt(Expectation.inner_logic);
    try std.testing.expectEqual(expected, parsed.diagnostics()[0].extra);
}
