//! Compiler diagnostics for the host (finding F5): each parse, resolve and lowering diagnostic
//! rendered as inklecate renders it, with its file, line and column, and delivered to a sink
//! in inklecate's order (author notes, then warnings, then errors).
//!
//! The texts are ink v1.2.1's (InkParser_*.cs, StringParser.cs, ParsedHierarchy/*.cs). Where
//! one inkz code covers several ink messages that differ in wording, the most common one is
//! used; `docs/RunningYourInk.md` lists the differences that remain.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const grammar = @import("grammar.zig");
const ast_module = @import("ast.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const lexical = @import("lexical.zig");
const source_space = @import("source_space.zig");
const values = @import("values.zig");
const lower_expressions = @import("lower_expressions.zig");

pub const Severity = enum {
    @"error",
    warning,
    /// A `TODO:` note in the story (ink's ErrorType.Author).
    author,
};

/// One diagnostic as the host sees it. The strings are valid during the sink's call only.
pub const Diagnostic = struct {
    severity: Severity,
    /// The code's name, such as `target_not_found` or `expected`.
    code: []const u8,
    /// The file's path as the compile was given it; empty for `compile_source`.
    file: []const u8,
    /// From 1, in the comment-free text (as ink's CommentEliminator leaves lines).
    line: u32,
    column: u32,
    message: []const u8,
};

/// Receives each diagnostic of a compile.
pub const Sink = struct {
    context: ?*anyopaque = null,
    function: *const fn (context: ?*anyopaque, diagnostic: Diagnostic) void,
};

/// The diagnostics of one compile, rendered and kept until `deliver` hands them over in
/// inklecate's order.
pub const Collector = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        severity: Severity,
        code: []const u8,
        file: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
    };

    pub fn init(gpa: Allocator) Collector {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(collector: *Collector) void {
        collector.arena.deinit();
        collector.* = undefined;
    }

    fn add(collector: *Collector, entry: Entry) !void {
        assert(entry.line > 0);
        try collector.entries.append(collector.arena.allocator(), entry);
    }

    /// Author notes, then warnings, then errors, each in the order found (as inklecate prints
    /// them).
    pub fn deliver(collector: *const Collector, sink: Sink) void {
        for ([_]Severity{ .author, .warning, .@"error" }) |severity| {
            for (collector.entries.items) |entry| {
                if (entry.severity != severity) continue;
                sink.function(sink.context, .{
                    .severity = entry.severity,
                    .code = entry.code,
                    .file = entry.file,
                    .line = entry.line,
                    .column = entry.column,
                    .message = entry.message,
                });
            }
        }
    }

    pub fn has_errors(collector: *const Collector) bool {
        for (collector.entries.items) |entry| {
            if (entry.severity == .@"error") return true;
        }
        return false;
    }
};

/// Where an offset of the parsed text is: through the space's newline table, or by counting
/// lines of a single source.
pub const Locator = struct {
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    space: ?*source_space.Space,
    /// The file name of a single source (empty for `compile_source`).
    file: []const u8 = "",

    fn position_of(locator: *const Locator, offset: u32) !source_space.Location {
        assert(offset <= locator.parsed.source.len);
        if (locator.space) |space| return space.locate(locator.gpa, offset);
        const position = lexical.line_and_column(locator.parsed.source, offset);
        return .{ .path = locator.file, .line = position.line, .column = position.column };
    }

    /// The parsed text up to the end of the file `offset` is in: a file's last line doesn't
    /// run on into the next file of the space.
    fn text_of_file(locator: *const Locator, offset: u32) []const u8 {
        const source = locator.parsed.source;
        assert(offset <= source.len);
        const space = locator.space orelse return source;
        const file = space.files[space.file_at(offset)];
        assert(offset <= file.end and file.end <= source.len);
        return source[0..file.end];
    }
};

// Parse diagnostics.

/// Renders the parse diagnostics (and the dropped-errors cap, once) into `collector`.
pub fn collect_parse(collector: *Collector, locator: *const Locator) !void {
    const parsed = locator.parsed;
    const arena = collector.arena.allocator();
    for (parsed.diagnostics()) |diagnostic| {
        const where = try locator.position_of(diagnostic.offset);
        const warning = grammar.Grammar.is_warning(diagnostic);
        const severity: Severity = if (warning) .warning else .@"error";
        try collector.add(.{
            .severity = severity,
            .code = code_name(diagnostic),
            .file = where.path,
            .line = where.line,
            .column = where.column,
            .message = try parse_message(
                arena,
                locator.text_of_file(diagnostic.offset),
                diagnostic,
            ),
        });
    }
    if (parsed.errors_dropped) {
        const last = parsed.source.len;
        const where = try locator.position_of(@intCast(last));
        try collector.add(.{
            .severity = .@"error",
            .code = "diagnostics_dropped",
            .file = where.path,
            .line = where.line,
            .column = where.column,
            .message = "Too many errors: the ones after these weren't recorded",
        });
    }
    try collect_author_notes(collector, locator);
}

/// `TODO:` notes, which ink reports as author messages.
fn collect_author_notes(collector: *Collector, locator: *const Locator) !void {
    const parsed = locator.parsed;
    const tree = &parsed.tree;
    for (tree.tags, 0..) |tag, at| {
        if (tag != .author_warning) continue;
        const node: ast_module.NodeIndex = .from_int(@intCast(at));
        const text = std.mem.trim(u8, parsed.leaf_text(node), " \t");
        const token = tree.data[node.to_int()];
        const where = try locator.position_of(parsed.workspace.token_starts[token]);
        try collector.add(.{
            .severity = .author,
            .code = "author_warning",
            .file = where.path,
            .line = where.line,
            .column = where.column,
            .message = text,
        });
    }
}

fn code_name(diagnostic: core.Diagnostic) []const u8 {
    return switch (diagnostic.code) {
        .expected => @tagName(@as(grammar.Expectation, @fromBackingInt(diagnostic.extra))),
        .message => @tagName(@as(grammar.Message, @fromBackingInt(diagnostic.extra))),
        .too_deep => "too_deep",
        .no_progress => "no_progress",
        _ => "parse_error",
    };
}

/// ink's message for a parse diagnostic: `Expected <what> but saw <rest of the line>` for an
/// expectation, else the message itself.
pub fn parse_message(
    arena: Allocator,
    source: []const u8,
    diagnostic: core.Diagnostic,
) ![]const u8 {
    assert(diagnostic.offset <= source.len);
    switch (diagnostic.code) {
        .expected => {
            const expectation: grammar.Expectation = @fromBackingInt(diagnostic.extra);
            const rest = line_rest(source, diagnostic.offset);
            if (rest.len == 0) {
                return std.fmt.allocPrint(arena, "Expected {s} but saw end of line", .{
                    expected_text(expectation),
                });
            }
            return std.fmt.allocPrint(arena, "Expected {s} but saw '{s}'", .{
                expected_text(expectation),
                rest,
            });
        },
        .message => return message_text(@fromBackingInt(diagnostic.extra)),
        .too_deep => return "The story nests too deeply for the parser",
        .no_progress => return "The parser made no progress here",
        _ => return "Parse error",
    }
}

/// ink's StringParser.LineRemainder: the rest of the line from `offset`, up to `\n` or `\r`.
fn line_rest(source: []const u8, offset: u32) []const u8 {
    assert(offset <= source.len);
    const rest = source[offset..];
    const end = std.mem.indexOfAny(u8, rest, "\n\r") orelse rest.len;
    return rest[0..end];
}

/// What ink's `Expect` says was expected.
fn expected_text(expectation: grammar.Expectation) []const u8 {
    return switch (expectation) {
        .end_of_line => "end of line",
        .knot_content => "at least one line within the knot",
        .stitch_content => "at least one line within the stitch",
        .closing_parenthesis => "closing parenthesis ')' for expression",
        .closing_bracket => "closing ']' for weave-style option",
        .closing_brace => "closing brace '}' for inline logic",
        .closing_quote => "close quote for string expression",
        .variable_name => "variable name",
        .equals => "the '=' for an assignment of a value, e.g. '= 5' (initial values are " ++
            "mandatory)",
        .expression => "expression after '~'",
        .inner_logic => "some kind of logic, conditional or sequence within braces: { ... }",
        .conditional_content => "conditional content following query",
        .sequence_elements => "sequence elements (for cycle/stoping etc)",
        .choice_condition => "choice condition inside { }",
        .divert_target => "target for new thread",
        .list_items => "list item names",
        .list_item_value => "value to be assigned to list item",
        .external_name => "name of external function",
        .external_parameters => "declaration of arguments for EXTERNAL, even if empty",
        .include_filename => "filename for include statement",
        .function_name_whitespace => "whitespace after the 'function' keyword",
        .right_operand => "right side of the expression",
        .sequence_annotation => "a sequence annotation",
    };
}

fn message_text(message: grammar.Message) []const u8 {
    return switch (message) {
        .tilde_in_content => "You shouldn't use a '~' here - tildas are for logic that's on " ++
            "its own line. To do inline logic, use { curly braces } instead",
        .gather_in_inner_block => "You can't use a gather (the dashes) within the { curly " ++
            "braces } context. For multi-line sequences and conditions, you should only use one " ++
            "dash.",
        .return_at_top_level => "should not have return statement outside of a knot",
        .return_without_tilde => "Do you need a '~' before 'return'? If not, perhaps use a " ++
            "glue: <> (since it's lowercase) or rewrite somehow?",
        .logic_line_expression => "Logic following a '~' can't be that type of expression. It " ++
            "can only be something like:\n\t~ return\n\t~ var x = blah\n\t~ x++\n\t~ myFunction()",
        .include_with_tilde => "'~ include' is no longer the correct syntax - please use " ++
            "'INCLUDE your_filename.ink', without the tilda, and in block capitals.",
        .increment_not_allowed => "Can't use increment/decrement here. It can only be used on " ++
            "a ~ line",
        .empty_divert_outside_choice => "Empty diverts (->) are only valid on choices",
        .tunnel_onwards_placement => "Tunnel onwards '->->' must only come at the begining or " ++
            "the start of a divert",
        .too_many_arrows => "Unexpected number of arrows in divert. Should only have '->' or " ++
            "'->->'",
        .choice_empty => "Choice is completely empty. Interpretting as a default fallback " ++
            "choice. Add a divert arrow to remove this warning: * ->",
        .choice_blank => "Blank choice - if you intended a default fallback choice, use the " ++
            "`* ->` syntax",
        .inline_conditional_alternatives => "Expected one or two alternatives separated by " ++
            "'|' in inline conditional",
        .else_not_final => "'else' case in conditional should always be the final one",
        .multiple_else => "Multiple 'else' cases. Can have a maximum of one, at the end.",
        .branch_without_condition => "Branch doesn't have condition. Are you missing a ':'? ",
        .condition_block_without_conditions => "Condition block with no conditions",
        .expected_else => "Expected an '- else:' clause here rather than an extra condition",
        .branch_without_content => "expected content for the conditional branch following '-'",
        .tag_in_string => "Tags aren't allowed inside of strings. Please use \\# if you want a " ++
            "hash symbol.",
        .string_with_divert => "String expressions cannot contain diverts (->)",
        .increment_target => "can only increment and decrement variables",
        .variable_initial_value => "initial value for a variable must be a number, constant, " ++
            "list or divert target",
        .list_with_var => "Unexpected ','. If you're trying to declare a new list, use the " ++
            "LIST keyword, not VAR",
        .constant_initial_value => "initial value for a constant must be a number or divert " ++
            "target",
        .constant_string_logic => "Constant strings cannot contain any logic.",
        .sequence_combination => "Sequence type combination not supported",
        .knot_name_missing => "Expected the name of the knot",
        .ref_without_name => "Expected an parameter name after 'ref'",
        .parameter_name_missing => "Expected an parameter name",
        .list_item_closing_parenthesis => "Expected closing ')'",
        .plus_minus => "Unexpected sequence '+-'",
        .expected_equals => "Expected '='",
        .only_final_branch_else => "Only final branch can be an 'else'. Did you miss a ':'?",
        .integer_out_of_range => "Failed to read integer value. Perhaps it's out of the range " ++
            "of acceptable numbers ink supports? (-2147483648 to 2147483647)",
    };
}

// Resolve and lowering diagnostics.

/// What the resolve and lowering messages read from the story.
pub const Story = struct {
    parsed: *const grammar.Parsed,
    tree: *const sema.Tree,
    locator: *const Locator,

    fn syntax(story: *const Story) *const ast_module.Ast {
        return &story.parsed.tree;
    }

    /// A dotted path's text.
    fn path_text(story: *const Story, arena: Allocator, path: ast_module.NodeIndex) ![]const u8 {
        const ast = story.syntax();
        if (ast.tag(path) != .path) return "";
        var text: std.ArrayList(u8) = .empty;
        const listed = ast.list(path);
        for (0..listed.count) |position| {
            if (position > 0) try text.append(arena, '.');
            try text.appendSlice(arena, story.parsed.leaf_text(ast.item(path, position)));
        }
        return text.items;
    }

    /// The name an object's message uses: a divert's target, a reference's path, or the
    /// object's own name.
    fn name(story: *const Story, arena: Allocator, object: sema.ObjectIndex) ![]const u8 {
        const node = story.tree.node(object);
        if (node.is_none()) return "";
        const ast = story.syntax();
        return switch (ast.tag(node)) {
            .divert, .tunnel, .thread => story.path_text(arena, ast.slot(node, .path)),
            .variable_reference => story.path_text(arena, ast.slot(node, .path)),
            .increment, .decrement => story.path_text(
                arena,
                ast.slot(ast.slot(node, .name), .path),
            ),
            .divert_target => story.divert_target_name(arena, object),
            .knot, .function, .stitch, .function_stitch, .function_call => story.leaf(node),
            .temp_declaration, .assignment => story.leaf(node),
            .add_assignment, .subtract_assignment => story.leaf(node),
            .variable_declaration, .const_declaration, .list_declaration => story.leaf(node),
            .list_item, .selected_list_item, .external_declaration => story.leaf(node),
            .choice, .sticky_choice, .gather => story.parsed.slot_text(node, .label),
            else => "",
        };
    }

    /// What Divert's Error override puts before its own messages: "Function call " for a
    /// call, "Divert " for another divert; nothing for other objects.
    fn divert_prefix(story: *const Story, object: sema.ObjectIndex) []const u8 {
        if (story.tree.kind(object) != .divert) return "";
        const call = story.tree.has(object, sema.Flags.function_call);
        return if (call) "Function call " else "Divert ";
    }

    /// ink's typeName of an object, as the naming messages print it.
    fn type_name(story: *const Story, object: sema.ObjectIndex) []const u8 {
        const tree = story.tree;
        return switch (tree.kind(object)) {
            .story => "Story",
            .knot, .stitch => if (tree.has(object, sema.Flags.function))
                "Function"
            else if (tree.kind(object) == .knot) "Knot" else "Stitch",
            .variable_assignment => if (tree.has(object, sema.Flags.new_temporary))
                "temp"
            else if (tree.has(object, sema.Flags.global)) "VAR" else "variable assignment",
            .constant_declaration => "Constant",
            .list_definition => "List definition",
            .list_element => "List element",
            .choice => "Choice",
            .gather => "Gather",
            else => "",
        };
    }

    /// A list definition's name: its LIST declaration's.
    fn list_name(story: *const Story, arena: Allocator, definition: sema.ObjectIndex) ![]const u8 {
        assert(story.tree.kind(definition) == .list_definition);
        return story.name(arena, story.tree.parent(definition));
    }

    /// ink's descriptionOfScope: the named flows around `object`, innermost first, then
    /// "at top scope" (`'s', 'k' and at top scope`).
    fn scope_text(story: *const Story, arena: Allocator, object: sema.ObjectIndex) ![]const u8 {
        const tree = story.tree;
        var text: std.ArrayList(u8) = .empty;
        var ancestor = object;
        var count: u32 = 0;
        while (!ancestor.is_none()) : (ancestor = tree.parent(ancestor)) {
            if (!tree.is_flow(ancestor) or tree.kind(ancestor) == .story) continue;
            if (count > 0) try text.appendSlice(arena, ", ");
            try text.print(arena, "'{s}'", .{try story.name(arena, ancestor)});
            count += 1;
        }
        if (count > 0) try text.appendSlice(arena, " and ");
        try text.appendSlice(arena, "at top scope");
        return text.items;
    }

    /// ink's ToString of an expression: numbers as C# prints them (a folded literal is a
    /// Number), dotted names, `(a op b)`, `_x` and `!x`, `f(a, b)`, a string's text, and the
    /// class name of a list or divert-target value. An explicit stack, no recursion.
    fn expression_text(
        story: *const Story,
        arena: Allocator,
        root: sema.ObjectIndex,
    ) ![]const u8 {
        var printer: ExpressionPrinter = .{ .story = story, .arena = arena };
        printer.stack[0] = .{ .object = root };
        printer.depth = 1;
        while (printer.depth > 0) {
            printer.depth -= 1;
            switch (printer.stack[printer.depth]) {
                .text => |part| try printer.text.appendSlice(arena, part),
                // Each object pushes at most 2 * 64 + 2 items; deeper text is left out.
                .object => |object| if (printer.depth + 130 <= printer.stack.len) {
                    try printer.print(object);
                },
            }
        }
        return printer.text.items;
    }

    /// ink's Choice.ToString: `* <start content>...`, with `[<choice-only content>]` if the
    /// choice has some, each a ContentList printed as `ContentList(a, b)`.
    fn choice_text(story: *const Story, arena: Allocator, object: sema.ObjectIndex) ![]const u8 {
        assert(story.tree.is_choice(object));
        const ast = story.syntax();
        const node = story.tree.node(object);
        const start = try story.content_list_text(arena, ast.slot(node, .start));
        const choice_only = ast.slot(node, .choice_only);
        if (ast.tag(choice_only) == .none) return std.fmt.allocPrint(arena, "* {s}...", .{start});
        return std.fmt.allocPrint(arena, "* {s}[{s}]...", .{
            start,
            try story.content_list_text(arena, choice_only),
        });
    }

    /// ink's ContentList.ToString: its items joined by ", ", texts as their text (C# prints
    /// a null list as nothing). Other content prints as ink's class name would, which inkz
    /// doesn't keep: as nothing.
    fn content_list_text(
        story: *const Story,
        arena: Allocator,
        list: ast_module.NodeIndex,
    ) ![]const u8 {
        const ast = story.syntax();
        if (ast.tag(list) != .content_list) return "";
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, "ContentList(");
        const items = ast.list(list);
        for (0..items.count) |position| {
            if (position > 0) try text.appendSlice(arena, ", ");
            const item = ast.item(list, position);
            switch (ast.tag(item)) {
                .text => try text.appendSlice(arena, story.parsed.leaf_text(item)),
                .text_space => {
                    try text.appendSlice(arena, story.parsed.leaf_text(item));
                    try text.append(arena, ' ');
                },
                else => {},
            }
        }
        try text.append(arena, ')');
        return text.items;
    }

    /// A divert-target value's target: its inner divert's path.
    fn divert_target_name(
        story: *const Story,
        arena: Allocator,
        object: sema.ObjectIndex,
    ) ![]const u8 {
        assert(story.tree.kind(object) == .divert_target);
        const divert = story.inner_divert(object) orelse return "";
        const node = story.tree.node(divert);
        if (node.is_none()) return "";
        const ast = story.syntax();
        if (ast.tag(node) != .divert) return "";
        return story.path_text(arena, ast.slot(node, .path));
    }

    fn leaf(story: *const Story, node: ast_module.NodeIndex) []const u8 {
        assert(!node.is_none());
        return story.parsed.slot_text(node, .name);
    }

    fn inner_divert(story: *const Story, object: sema.ObjectIndex) ?sema.ObjectIndex {
        assert(story.tree.kind(object) == .divert_target);
        for (story.tree.children_of(object)) |child| {
            if (story.tree.kind(child) == .divert) return child;
        }
        return null;
    }

    fn offset(story: *const Story, object: sema.ObjectIndex) u32 {
        return sema.object_offset(story.parsed, story.tree, object);
    }

    fn location(story: *const Story, object: sema.ObjectIndex) !source_space.Location {
        assert(!object.is_none());
        return story.locator.position_of(story.offset(object));
    }

    /// ink's DebugMetadata text: `line N of file`, or `line N` without a file name.
    fn debug_metadata(story: *const Story, arena: Allocator, object: sema.ObjectIndex) ![]const u8 {
        assert(!object.is_none());
        const where = try story.location(object);
        if (where.path.len == 0) return std.fmt.allocPrint(arena, "line {d}", .{where.line});
        return std.fmt.allocPrint(arena, "line {d} of {s}", .{ where.line, where.path });
    }
};

/// The work of `Story.expression_text`: the pending objects and texts, last on top.
const ExpressionPrinter = struct {
    story: *const Story,
    arena: Allocator,
    stack: [256]Item = undefined,
    depth: u32 = 0,
    text: std.ArrayList(u8) = .empty,

    const Item = union(enum) { object: sema.ObjectIndex, text: []const u8 };

    fn push(printer: *ExpressionPrinter, item: Item) void {
        assert(printer.depth < printer.stack.len);
        printer.stack[printer.depth] = item;
        printer.depth += 1;
    }

    /// Prints a literal or a name, or pushes an operator's parts in reverse.
    fn print(printer: *ExpressionPrinter, object: sema.ObjectIndex) !void {
        const story = printer.story;
        const tree = story.tree;
        const arena = printer.arena;
        const literal = values.literal(story.parsed, tree, object) catch null;
        if (literal) |value| return switch (value) {
            .integer => |number| printer.text.print(arena, "{d}", .{number}),
            .float => |number| printer.text.print(arena, "{d}", .{number}),
            .bool => |flag| printer.text.appendSlice(arena, if (flag) "True" else "False"),
            .string => |string| printer.text.appendSlice(arena, string),
            .divert_target => printer.text.appendSlice(arena, "Ink.Parsed.DivertTarget"),
        };
        switch (tree.kind(object)) {
            .variable_reference => try printer.text.appendSlice(arena, try story.name(
                arena,
                object,
            )),
            .binary => {
                const operands = tree.children_of(object);
                const tag = story.syntax().tag(tree.node(object));
                printer.push(.{ .text = ")" });
                printer.push(.{ .object = operands[1] });
                printer.push(.{ .text = try std.fmt.allocPrint(arena, " {s} ", .{
                    lower_expressions.native_name(tag),
                }) });
                printer.push(.{ .object = operands[0] });
                printer.push(.{ .text = "(" });
            },
            .unary => {
                const negate = story.syntax().tag(tree.node(object)) == .negate;
                printer.push(.{ .object = tree.children_of(object)[0] });
                printer.push(.{ .text = if (negate) "_" else "!" });
            },
            .function_call => try printer.call(object),
            .string_expression => for (tree.children_of(object)) |part| {
                if (tree.kind(part) != .text) continue;
                try printer.text.appendSlice(arena, story.parsed.leaf_text(tree.node(part)));
            },
            .divert_target => try printer.text.appendSlice(arena, "Ink.Parsed.DivertTarget"),
            .list_literal => try printer.text.appendSlice(arena, "Ink.Parsed.List"),
            else => {},
        }
    }

    /// `f(a, b)`: the name now, the arguments (from the call's proxy divert) pushed.
    fn call(printer: *ExpressionPrinter, object: sema.ObjectIndex) !void {
        const tree = printer.story.tree;
        assert(tree.kind(object) == .function_call);
        const children = tree.children_of(object);
        const arguments = if (children.len > 0) tree.children_of(children[0]) else &.{};
        printer.push(.{ .text = ")" });
        var position = @min(arguments.len, 64);
        while (position > 0) {
            position -= 1;
            printer.push(.{ .object = arguments[position] });
            if (position > 0) printer.push(.{ .text = ", " });
        }
        try printer.text.print(printer.arena, "{s}(", .{try printer.story.name(
            printer.arena,
            object,
        )});
    }
};

/// Whether ink reports `code` while it generates code (Story.ExportRuntime's first pass,
/// or the constant and label checks just before it).
fn reported_in_generation(code: resolve.Code) bool {
    return switch (code) {
        .constant_redefined, .duplicate_label, .duplicate_declaration => true,
        .duplicate_external, .duplicate_flow, .duplicate_list_item => true,
        .function_is_stitch, .function_has_stitch, .function_has_divert => true,
        .function_has_choice, .return_outside_function, .loose_end => true,
        .divert_parameter_unmarked, .arguments_to_non_flow, .flow_takes_no_parameters => true,
        .arguments_in_divert_target, .wrong_argument_count => true,
        .divert_target_argument_expected, .read_count_instead_of_divert_target => true,
        .reference_argument_not_variable, .read_count_by_reference => true,
        .builtin_argument_count, .builtin_argument_not_integer => true,
        .list_from_more_than_one_value, .ambiguous_list_item, .list_item_not_found => true,
        .duplicate_list_literal_item, .unsupported_fold => true,
        else => false,
    };
}

/// Where a generation-phase diagnostic falls in ink's generation order: a flow's loose
/// end after everything in the flow (its stitches too), the global VAR and LIST
/// initializations after all flows, the rest in tree order.
fn generation_order(tree: *const sema.Tree, diagnostic: resolve.Diagnostic) u64 {
    const object = diagnostic.object;
    const count: u64 = tree.count();
    if (diagnostic.code == .loose_end) {
        // The flow's last descendant: its last child's, down to a leaf.
        var last = tree.closest_flow(object);
        while (tree.children_of(last).len > 0) {
            const children = tree.children_of(last);
            last = children[children.len - 1];
        }
        return @as(u64, last.to_int()) * 2 + 1;
    }
    var ancestor = object;
    while (!ancestor.is_none()) : (ancestor = tree.parent(ancestor)) {
        const global = tree.kind(ancestor) == .variable_assignment and
            tree.has(ancestor, sema.Flags.global);
        if (global or tree.kind(ancestor) == .list_definition) {
            return count * 2 + @as(u64, object.to_int());
        }
    }
    return @as(u64, object.to_int()) * 2;
}

/// Whether ink resolves references after generating code: unless the last message of
/// generation was an error (ink's `_hadError` is set by each message, so a warning after an
/// error clears it).
fn resolves_references(tree: *const sema.Tree, diagnostics: []const resolve.Diagnostic) bool {
    var last: ?resolve.Diagnostic = null;
    var last_order: u64 = 0;
    for (diagnostics) |diagnostic| {
        if (!reported_in_generation(diagnostic.code)) continue;
        const order = generation_order(tree, diagnostic);
        if (last == null or order >= last_order) {
            last = diagnostic;
            last_order = order;
        }
    }
    const final = last orelse return true;
    return final.code.is_warning();
}

/// Renders resolve and lowering diagnostics into `collector`: lowering's go among
/// resolve's by position, as ink reports each where its walk reaches the object (inkz
/// numbers a choice's nested content after later flows, so not by object). As in ink,
/// when code generation ends in an error, the reference errors never appear: ink never
/// checked them.
pub fn collect_resolve(
    collector: *Collector,
    story: *const Story,
    resolved: []const resolve.Diagnostic,
    lowered: []const resolve.Diagnostic,
) !void {
    const gpa = collector.arena.allocator();
    var all: std.ArrayList(resolve.Diagnostic) = .empty;
    try all.ensureTotalCapacity(gpa, resolved.len + lowered.len);
    all.appendSliceAssumeCapacity(resolved);
    for (lowered) |diagnostic| {
        const offset = story.offset(diagnostic.object);
        var position: usize = all.items.len;
        for (all.items, 0..) |existing, at| {
            if (story.offset(existing.object) > offset) {
                position = at;
                break;
            }
        }
        all.insertAssumeCapacity(position, diagnostic);
    }
    const resolves = resolves_references(story.tree, all.items);
    for (all.items) |diagnostic| {
        if (!resolves and !reported_in_generation(diagnostic.code)) continue;
        try collect_one(collector, story, diagnostic);
    }
}

fn collect_one(collector: *Collector, story: *const Story, diagnostic: resolve.Diagnostic) !void {
    const where = try story.location(diagnostic.object);
    try collector.add(.{
        .severity = if (diagnostic.code.is_warning()) .warning else .@"error",
        .code = @tagName(diagnostic.code),
        .file = where.path,
        .line = where.line,
        .column = where.column,
        .message = try resolve_message(collector.arena.allocator(), story, diagnostic),
    });
}

// lint: allow function_length: one message per code, as ink words each one
fn resolve_message(
    arena: Allocator,
    story: *const Story,
    diagnostic: resolve.Diagnostic,
) ![]const u8 {
    const object = diagnostic.object;
    const other = diagnostic.other;
    const name = if (diagnostic.name.len > 0) diagnostic.name else try story.name(arena, object);
    const numbers = diagnostic.numbers;
    // Divert's Error override puts its kind before the messages it raises itself.
    const prefix = story.divert_prefix(object);
    const print = std.fmt.allocPrint;
    return switch (diagnostic.code) {
        .target_not_found => print(arena, "{s}target not found: '-> {s}'", .{ prefix, name }),
        .unresolved_variable => print(arena, "Unresolved variable: {s}", .{name}),
        // ink adds the list item reading for paths a list item could be (two components).
        .read_count_target_not_found => if (std.mem.count(u8, name, ".") <= 1)
            print(arena, "Could not find target for read count: -> {s}, or couldn't find " ++
                "list item with the name {s}", .{
                name,
                try std.mem.replaceOwned(u8, arena, name, ".", ","),
            })
        else
            print(arena, "Could not find target for read count: -> {s}", .{name}),
        .assignment_target_not_found => print(arena, "Variable could not be found to " ++
            "assign to: '{s}'", .{name}),
        .assignment_to_constant => print(arena, "Can't re-assign to a constant (do you need " ++
            "to use VAR when declaring '{s}'?)", .{name}),
        .increment_target_not_found => print(arena, "variable for {s} could not be found: " ++
            "'{s}' after searching: {s}", .{
            if (story.tree.has(object, sema.Flags.decrement)) "decrement" else "increment",
            name,
            try story.scope_text(arena, object),
        }),
        .duplicate_label => print(arena, "A {s} with the same label name '{s}' already exists " ++
            "in this context on line {d}", .{
            if (story.tree.kind(other) == .gather) "gather" else "choice",
            name,
            (try story.location(other)).line,
        }),
        .duplicate_declaration => print(arena, "found declaration variable '{s}' that was " ++
            "already declared{s}", .{ name, try back_reference(arena, story, diagnostic) }),
        .duplicate_argument => print(arena, "Multiple arguments with the same name: " ++
            "'{s}'", .{name}),
        .duplicate_external => print(arena, "Duplicate EXTERNAL definition of '{s}'", .{name}),
        .name_conflict => print(arena, "{s} '{s}': name has already been used for a {s} on {s}", .{
            if (numbers[0] == 1) "argument" else story.type_name(object),
            name,
            try std.ascii.allocLowerString(arena, story.type_name(other)),
            try story.debug_metadata(arena, other),
        }),
        // ink prints its story's name here, which is empty.
        .argument_name_conflict => print(arena, "{s} '': Name has already been used for a " ++
            "argument to {s} on {s}", .{
            story.type_name(object),
            try story.name(arena, other),
            try story.debug_metadata(arena, other),
        }),
        .reserved_name, .builtin_name => print(arena, "'' cannot be used for the name of a {s} " ++
            "because it's a {s}", .{
            if (numbers[0] == 1)
                "argument"
            else
                try std.ascii.allocLowerString(arena, story.type_name(object)),
            if (diagnostic.code == .reserved_name) "reserved keyword" else "built in function",
        }),
        .duplicate_flow => print(arena, "{s} already contains flow named '{s}' (at {s})", .{
            if (story.tree.kind(story.tree.parent(object)) == .story) "Story" else "Knot",
            name,
            try story.debug_metadata(arena, other),
        }),
        .not_a_function => print(arena, "{s} hasn't been marked as a function, but it's being " ++
            "called as one. Do you need to delcare the knot as '== function {s} =='?", .{
            try story.name(arena, other),
            try story.name(arena, other),
        }),
        .function_diverted_to => print(arena, "{s} can't be diverted to. It can only be called " ++
            "as a function since it's been marked as such: '{s}(...)'", .{
            try story.name(arena, other),
            try story.name(arena, other),
        }),
        .builtin_not_called => print(arena, "{s} must be called as a function: ~ {s}()", .{
            name,
            name,
        }),
        .done_or_end_as_value => "Can't Can't use -> DONE or -> END as variable divert targets",
        .tunnel_onwards_to_end_or_done => "Can't use '->-> END' or '->-> DONE': a tunnel can " ++
            "only return onwards to a knot, stitch or label. Write '->->' and then '-> END' " ++
            "instead",
        .arguments_to_non_flow => print(arena, "{s}target needs to be a knot or stitch in " ++
            "order to pass arguments", .{prefix}),
        .flow_takes_no_parameters => print(arena, "{s}target ({s}) doesn't take parameters", .{
            prefix,
            try story.name(arena, other),
        }),
        .arguments_in_divert_target => print(arena, "{s}can't store arguments in a divert " ++
            "target variable", .{prefix}),
        .wrong_argument_count => print(arena, "{s}to '{s}' requires {d} arguments, {s}", .{
            prefix,
            try story.name(arena, other),
            numbers[0],
            if (numbers[1] == 0)
                "but there weren't any passed to it"
            else if (numbers[1] < numbers[0])
                try print(arena, "but only got {d}", .{numbers[1]})
            else
                try print(arena, "but got {d}", .{numbers[1]}),
        }),
        .divert_target_argument_expected => print(arena, "Target '{s}' expects a divert " ++
            "target for the parameter named -> {s} but saw {s}", .{
            try story.name(arena, other),
            name,
            try story.expression_text(arena, object),
        }),
        .read_count_instead_of_divert_target => print(arena, "{s}Passing read count of '{s}' " ++
            "instead of a divert target. You probably meant '-> {s}'", .{
            prefix,
            try story.name(arena, other),
            try story.name(arena, other),
        }),
        .reference_argument_not_variable => print(arena, "{s}Expected variable name to pass " ++
            "by reference to 'ref {s}' but saw {s}", .{
            prefix,
            name,
            try story.expression_text(arena, other),
        }),
        .read_count_by_reference => print(arena, "{s}can't pass a read count by reference. " ++
            "'{s}' is a knot/stitch/label, but '{s}' requires the name of a VAR to be passed.", .{
            prefix,
            try story.name(arena, other),
            try story.name(arena, object),
        }),
        .divert_parameter_unmarked => print(arena, "Since '{s}' is used as a variable divert " ++
            "target (on {s}), it should be marked as: -> {s}", .{
            name,
            try story.debug_metadata(arena, other),
            name,
        }),
        .external_argument_count => print(arena, "{s}incorrect number of arguments sent to " ++
            "external function '{s}'. Expected {d} but got {d}", .{
            prefix,
            name,
            numbers[0],
            numbers[1],
        }),
        .builtin_argument_count => builtin_count_text(arena, name, numbers[0]),
        .builtin_argument_not_integer => if (std.mem.eql(u8, name, "SEED_RANDOM"))
            "SEED_RANDOM's parameter should be an integer seed"
        else
            print(arena, "RANDOM's {s} parameter should be an integer", .{
                if (numbers[0] == 0) "minimum" else "maximum",
            }),
        .list_from_more_than_one_value => "Can currently only construct a list from one " ++
            "integer (or an empty list from a given list definition)",
        .ambiguous_list_item => print(arena, "Ambiguous item name '{s}' found in multiple " ++
            "sets, including {s} and {s}", .{
            name,
            try story.list_name(arena, other),
            try story.list_name(arena, .from_int(numbers[0])),
        }),
        .global_refers_to_variable => "global variable assignments cannot refer to other " ++
            "variables, only literal values, constants and list items",
        .duplicate_list_item => print(arena, "List '{s}' contains dupicate items called " ++
            "'{s}'", .{ try story.list_name(arena, object), name }),
        .list_item_not_found => if (std.mem.indexOfScalar(u8, name, '.') == null)
            print(arena, "Could not find list definition that contains item '{s}'", .{name})
        else
            print(arena, "Could not find list item {s}", .{name}),
        .duplicate_list_literal_item => print(arena, "Duplicate of item '{s}' in list.", .{name}),
        .constant_redefined => print(arena, "CONST '{s}' has been redefined with a different " ++
            "value. Multiple definitions of the same CONST are valid so long as they contain " ++
            "the same value. Initial definition was on {s}.", .{
            name,
            try story.debug_metadata(arena, other),
        }),
        .negated_has_operand => negated_has(arena, story, object),
        .divert_target_misused => print(arena, "Can't use a divert target like that. Did you " ++
            "intend to call '-> {s}' as a function: likeThis(), or check the read count: " ++
            "likeThis, with no arrows?", .{name}),
        .variable_divert_target => print(arena, "Since '{s}' is a variable, it shouldn't be " ++
            "preceded by '->' here.", .{name}),
        .turns_since_variable_target => print(arena, "When getting the TURNS_SINCE() of a " ++
            "variable target, remove the '->' - i.e. it should just be TURNS_SINCE({s})", .{
            try story.name(arena, story.tree.children_of(object)[0]),
        }),
        .turns_since_target_not_found => print(arena, "Failed to find target for " ++
            "TURNS_SINCE: '-> {s}'", .{try story.name(arena, other)}),
        .count_without_arrow => print(arena, "Should be {s}(-> {s}). Usage without the '->' " ++
            "only makes sense for variable targets.", .{ name, try story.name(arena, other) }),
        .increment_as_sub_expression => print(arena, "Can't use {s} as sub-expression", .{
            if (story.tree.has(object, sema.Flags.decrement)) "decrement" else "increment",
        }),
        .divert_target_to_reference_flow => print(arena, "Can't store a divert target to a " ++
            "knot or function that has by-reference arguments ('{s}' has 'ref {s}').", .{
            try story.name(arena, other),
            name,
        }),
        .unsupported_fold => "Unexpected operation or number type",
        .function_is_stitch => "Functions cannot be stitches - i.e. they should be defined as " ++
            "'== function myFunc ==' rather than public to another knot.",
        .function_has_stitch => print(arena, "Functions may not contain stitches, but saw " ++
            "'{s}' within the function '{s}'", .{ name, try story.name(arena, other) }),
        .function_has_divert => print(arena, "Functions may not contain diverts, but saw " ++
            "'-> {s}'", .{name}),
        .function_has_choice => print(arena, "Functions may not contain choices, but saw " ++
            "'{s}'", .{try story.choice_text(arena, object)}),
        .return_outside_function => print(arena, "Return statements can only be used in knots " ++
            "that are declared as functions: == function {s} ==", .{
            try story.name(arena, other),
        }),
        .nested_choice_needs_divert => "Choices nested in conditionals or sequences need to " ++
            "explicitly divert afterwards.",
        .conditional_choice_syntax => "Choices with conditions should be written: " ++
            "'* {condition} choice'. Otherwise, choices nested in conditionals or sequences " ++
            "need to explicitly divert afterwards.",
        .loose_end => loose_end(arena, story, object),
    };
}

/// FunctionCall.GenerateIntoContainer's argument count texts, one per built-in; a native
/// function's says how many it takes (`expected`).
fn builtin_count_text(arena: Allocator, name: []const u8, expected: u32) ![]const u8 {
    assert(name.len > 0);
    const fixed = [_]struct { []const u8, []const u8 }{
        .{ "CHOICE_COUNT", "The CHOICE_COUNT() function shouldn't take any arguments" },
        .{ "TURNS", "The TURNS() function shouldn't take any arguments" },
        .{ "RANDOM", "RANDOM should take 2 parameters: a minimum and a maximum integer" },
        .{ "SEED_RANDOM", "SEED_RANDOM should take 1 parameter - an integer seed" },
        .{ "LIST_RANGE", "LIST_RANGE should take 3 parameters - a list, a min and a max" },
        .{ "LIST_RANDOM", "LIST_RANDOM should take 1 parameter - a list" },
    };
    for (fixed) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    if (std.mem.eql(u8, name, "TURNS_SINCE") or std.mem.eql(u8, name, "READ_COUNT")) {
        return std.fmt.allocPrint(arena, "The {s}() function should take one argument: a " ++
            "divert target to the target knot, stitch, gather or choice you want to check. " ++
            "e.g. TURNS_SINCE(-> myKnot)", .{name});
    }
    return std.fmt.allocPrint(arena, "{s} should take {d} parameter{s}", .{
        name,
        expected,
        if (expected > 1) "s" else "",
    });
}

/// FlowBase's loose-end warning, with its notes: the first stitch a knot's top level runs
/// into without a divert, and a final tunnel that has nowhere to return to.
fn loose_end(arena: Allocator, story: *const Story, object: sema.ObjectIndex) ![]const u8 {
    const tree = story.tree;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "Apparent loose end exists where the flow runs out. Do you " ++
        "need a '-> DONE' statement, choice or divert?");
    const flow = tree.closest_flow(object);
    const children = tree.children_of(flow);
    if (children.len > 0 and tree.parent(object) == children[0]) {
        for (children) |child| {
            if (!tree.is_flow(child)) continue;
            try text.print(arena, " Note that if you intend to enter '{s}' next, you need to " ++
                "divert to it explicitly.", .{try story.name(arena, child)});
            break;
        }
    }
    if (tree.kind(object) == .divert and tree.has(object, sema.Flags.tunnel)) {
        try text.print(arena, " When final tunnel to '-> {s} ->' returns it won't have " ++
            "anywhere to go.", .{try story.name(arena, object)});
    }
    return text.items;
}

/// ` (line N of file)`, pointing at the earlier object a duplicate repeats.
fn back_reference(
    arena: Allocator,
    story: *const Story,
    diagnostic: resolve.Diagnostic,
) ![]const u8 {
    if (diagnostic.other.is_none()) return "";
    const metadata = try story.debug_metadata(arena, diagnostic.other);
    assert(metadata.len > 0);
    return std.fmt.allocPrint(arena, " ({s})", .{metadata});
}

/// The negated operand's text, as ink prints an expression (`x`, `(a + b)`, `f(x)`).
fn negated_has(arena: Allocator, story: *const Story, object: sema.ObjectIndex) ![]const u8 {
    assert(story.tree.kind(object) == .binary);
    const negation = story.tree.children_of(object)[0];
    assert(story.tree.kind(negation) == .unary);
    const negated = story.tree.children_of(negation)[0];
    return std.fmt.allocPrint(arena, "Using 'not' or '!' here negates '{s}' rather than the " ++
        "result of the '?' or 'has' operator. You need to add parentheses around the (A ? B) " ++
        "expression.", .{try story.expression_text(arena, negated)});
}

// Source space problems.

/// INCLUDE problems: ink's "Failed to load" for a missing file, inkz's own for the bounds.
pub fn collect_problems(
    collector: *Collector,
    locator: *const Locator,
    space: *const source_space.Space,
) !void {
    assert(space.files.len > 0);
    const arena = collector.arena.allocator();
    for (space.problems) |problem| {
        const where = try locator.position_of(problem.offset);
        const name = include_name(locator.text_of_file(problem.offset), problem.offset);
        const message = switch (problem.code) {
            .include_not_found => try std.fmt.allocPrint(arena, "Failed to load: '{s}'", .{name}),
            .include_cycle => try std.fmt.allocPrint(arena, "Recursive INCLUDE detected: " ++
                "'{s}' is already open.", .{name}),
            .include_too_deep => "INCLUDEs nest deeper than the compiler's limit",
            .include_too_many => "More INCLUDEd files than the compiler's limit",
        };
        try collector.add(.{
            .severity = .@"error",
            .code = @tagName(problem.code),
            .file = where.path,
            .line = where.line,
            .column = where.column,
            .message = message,
        });
    }
}

/// Every INCLUDE of a story compiled from text, which has no directory to load from:
/// inklecate's "Failed to load: 'name'".
pub fn collect_includes(collector: *Collector, locator: *const Locator) !void {
    assert(locator.space == null);
    const parsed = locator.parsed;
    const arena = collector.arena.allocator();
    for (parsed.tree.tags, 0..) |tag, at| {
        if (tag != .include) continue;
        const offset = parsed.workspace.token_starts[parsed.tree.data[at]];
        const newline = std.mem.lastIndexOfScalar(u8, parsed.source[0..offset], '\n');
        const line_start: u32 = if (newline) |position| @intCast(position + 1) else 0;
        const where = try locator.position_of(offset);
        try collector.add(.{
            .severity = .@"error",
            .code = "include_not_found",
            .file = where.path,
            .line = where.line,
            .column = where.column,
            .message = try std.fmt.allocPrint(arena, "Failed to load: '{s}'", .{
                include_name(parsed.source, line_start),
            }),
        });
    }
}

/// Why the parser gave up on a story, which then has no tree to point into: one error at
/// the start of the root file, delivered at once.
pub fn deliver_give_up(sink: Sink, err: anyerror, file: []const u8) void {
    assert(err != error.OutOfMemory);
    sink.function(sink.context, give_up(err, file));
}

fn give_up(err: anyerror, file: []const u8) Diagnostic {
    const code: []const u8, const message: []const u8 = switch (err) {
        error.SourceTooLarge => .{
            "source_too_large",
            "The story is larger than the compiler's source limit",
        },
        error.ParseFailed => .{ "too_deep", "The story nests too deeply for the parser" },
        error.WorkspaceFull => .{
            "workspace_full",
            "The story needs more parser workspace than the compiler's limit",
        },
        else => unreachable,
    };
    return .{
        .severity = .@"error",
        .code = code,
        .file = file,
        .line = 1,
        .column = 1,
        .message = message,
    };
}

/// The name after `INCLUDE` on the line at `offset`, its trailing spaces and tabs trimmed.
pub fn include_name(source: []const u8, offset: u32) []const u8 {
    assert(offset <= source.len);
    const rest = line_rest(source, offset);
    const keyword = "INCLUDE";
    const after = if (std.mem.indexOf(u8, rest, keyword)) |at| rest[at + keyword.len ..] else rest;
    return std.mem.trim(u8, after, " \t");
}
