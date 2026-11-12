// lint: allow assertion_density: a throwaway spike (P7.0), deleted once P7.3 replaces it.
//! P7.0 parser spike (throwaway, plan §4.11, D9): an explicit-stack parser for ink's hardest
//! nesting, to check the design before the real grammar (P7.3+). It parses a subset of ink
//! straight from characters:
//! - lines of text with glue-free inline braces `{...}` (conditionals `{c: a|b}`, sequences
//!   `{&a|b}`, plain expressions `{x}`), nested to any depth;
//! - weaves: choices (`*`/`+`, nested by count) with `[...]` choice-only content and a
//!   condition `{...}` before it, and gathers (`-`);
//! - multi-line conditionals `{ x > 1: ... - else: ... }` and switches `{ x: - 1: ... }`
//!   whose branches hold weaves;
//! - expressions with precedence, parentheses and `not`, by a shunting-yard loop.
//!
//! Nodes follow zirp's layout: a tag and one word, children contiguous. A finished node is
//! pushed as a value on a scratch stack; when its parent finishes, `wrap` copies the
//! children's values into one contiguous run of the node array. There is no recursion: one
//! heterogeneous frame stack drives blocks, lines, braces and choices.

const std = @import("std");
const assert = std.debug.assert;

pub const Tag = enum(u8) {
    root,
    line,
    text,
    /// `{x}`: an expression printed inline.
    inline_value,
    /// `{c: a|b}`: a condition and one or two branches.
    inline_conditional,
    /// `{&a|b}` (or `!`, `~`, `$`): branches.
    sequence,
    /// A branch of an inline construct: content items.
    branch,
    /// `{ c: ...}` or `{ x: - 1: ...}` over several lines.
    block_conditional,
    /// `- c:` or `- else:` in a block: the condition (or nothing) and a body.
    block_branch,
    weave,
    choice,
    /// Inside `[...]`.
    choice_only,
    gather,
    number,
    identifier,
    add,
    subtract,
    multiply,
    divide,
    greater,
    less,
    equal,
    @"and",
    @"or",
    not,
    /// A required part that was missing (recovery).
    missing,
};

/// One node: its tag, its first child (or a source offset for leaves) and how many children.
pub const Node = struct {
    tag: Tag,
    /// First child's index, or the leaf's source offset.
    data: u32,
    /// Children count, or the leaf's length.
    count: u32,
};

pub const Error = error{ TooDeep, TooManyNodes, Unexpected };

pub const depth_max = 64;
pub const nodes_max = 4096;

pub const Ast = struct {
    source: []const u8,
    nodes: []const Node,
    root: u32,

    pub fn children(ast: *const Ast, node: u32) []const Node {
        const item = ast.nodes[node];
        assert(item.tag != .text and item.tag != .number and item.tag != .identifier);
        return ast.nodes[item.data..][0..item.count];
    }

    /// An S-expression of the tree, for tests: `(line (text "a") (inline_value x))`.
    pub fn write(ast: *const Ast, writer: *std.Io.Writer) !void {
        // An explicit stack of (node, next child) instead of recursion.
        var stack: [depth_max]struct { node: Node, next: u32 } = undefined;
        var depth: u32 = 1;
        stack[0] = .{ .node = ast.nodes[ast.root], .next = 0 };
        try open(ast, writer, ast.nodes[ast.root]);
        while (depth > 0) {
            const top = &stack[depth - 1];
            if (is_leaf(top.node.tag) or top.next == top.node.count) {
                if (!is_leaf(top.node.tag)) try writer.writeByte(')');
                depth -= 1;
                continue;
            }
            const child = ast.nodes[top.node.data + top.next];
            top.next += 1;
            try writer.writeByte(' ');
            try open(ast, writer, child);
            if (depth == depth_max) return error.TooDeep;
            stack[depth] = .{ .node = child, .next = 0 };
            depth += 1;
        }
    }

    fn open(ast: *const Ast, writer: *std.Io.Writer, node: Node) !void {
        switch (node.tag) {
            .text => try writer.print("\"{s}\"", .{ast.source[node.data..][0..node.count]}),
            .number, .identifier => try writer.writeAll(ast.source[node.data..][0..node.count]),
            .missing => try writer.writeAll("?"),
            else => try writer.print("({t}", .{node.tag}),
        }
    }
};

fn is_leaf(tag: Tag) bool {
    return tag == .text or tag == .number or tag == .identifier or tag == .missing;
}

/// What a frame is parsing, with the state it resumes in.
const Frame = struct {
    kind: Kind,
    /// Scratch length when the frame started: its finished children sit above it.
    marker: u32,
    /// For content: the characters that end it (besides a newline).
    stop: Stop = .line,
    /// For weaves: the choice depth of this level; for blocks: whether branches started.
    level: u32 = 0,

    const Kind = enum { root, weave, choice, block, block_branch, line, inline_brace, branch };
    const Stop = enum { line, bracket, pipe_or_brace };
};

const Parser = struct {
    source: []const u8,
    at: u32 = 0,
    nodes: [nodes_max]Node = undefined,
    nodes_count: u32 = 0,
    scratch: [nodes_max]Node = undefined,
    scratch_count: u32 = 0,
    frames: [depth_max]Frame = undefined,
    frames_count: u32 = 0,

    fn peek(parser: *const Parser) u8 {
        return if (parser.at < parser.source.len) parser.source[parser.at] else 0;
    }

    fn push_frame(parser: *Parser, frame: Frame) Error!void {
        if (parser.frames_count == depth_max) return error.TooDeep;
        parser.frames[parser.frames_count] = frame;
        parser.frames_count += 1;
    }

    fn push(parser: *Parser, node: Node) Error!void {
        if (parser.scratch_count == nodes_max) return error.TooManyNodes;
        parser.scratch[parser.scratch_count] = node;
        parser.scratch_count += 1;
    }

    /// zirp's wrap: the values above `marker` become `tag`'s contiguous children.
    fn wrap(parser: *Parser, tag: Tag, marker: u32) Error!void {
        const count = parser.scratch_count - marker;
        if (parser.nodes_count + count > nodes_max) return error.TooManyNodes;
        const first = parser.nodes_count;
        @memcpy(parser.nodes[first..][0..count], parser.scratch[marker..parser.scratch_count]);
        parser.nodes_count += count;
        parser.scratch_count = marker;
        try parser.push(.{ .tag = tag, .data = first, .count = count });
    }

    fn leaf(parser: *Parser, tag: Tag, start: u32) Error!void {
        assert(parser.at >= start);
        try parser.push(.{ .tag = tag, .data = start, .count = parser.at - start });
    }

    fn skip_blank(parser: *Parser) void {
        while (std.mem.indexOfScalar(u8, " \t\n", parser.peek()) != null) parser.at += 1;
    }

    fn skip_spaces(parser: *Parser) void {
        while (parser.peek() == ' ' or parser.peek() == '\t') parser.at += 1;
    }

    fn top(parser: *Parser) *Frame {
        assert(parser.frames_count > 0);
        return &parser.frames[parser.frames_count - 1];
    }

    fn pop(parser: *Parser, tag: Tag) Error!void {
        const frame = parser.frames[parser.frames_count - 1];
        parser.frames_count -= 1;
        try parser.wrap(tag, frame.marker);
    }

    fn run(parser: *Parser) Error!Ast {
        try parser.push_frame(.{ .kind = .root, .marker = 0 });
        try parser.push_frame(.{ .kind = .weave, .marker = 0, .level = 0 });
        var gas: u32 = 0;
        while (parser.frames_count > 0) : (gas += 1) {
            // The progress bound: every step consumes input or closes a frame.
            if (gas > 16 * (parser.source.len + 16)) return error.Unexpected;
            switch (parser.top().kind) {
                .root => try parser.pop(.root),
                .weave => try parser.weave_step(),
                .choice => try parser.choice_step(),
                .block => try parser.block_step(),
                .block_branch => try parser.block_branch_step(),
                .line, .branch => try parser.content_step(),
                .inline_brace => try parser.brace_step(),
            }
        }
        assert(parser.scratch_count == 1);
        parser.nodes[parser.nodes_count] = parser.scratch[0];
        const nodes = parser.nodes[0 .. parser.nodes_count + 1];
        return .{ .source = parser.source, .nodes = nodes, .root = parser.nodes_count };
    }

    /// At a line start inside a weave: a choice or gather of some depth, a block, a line, or
    /// the end of this weave (input end, `}`, a `-` branch marker of an enclosing block, or a
    /// choice no deeper than this level).
    fn weave_step(parser: *Parser) Error!void {
        parser.skip_blank();
        const frame = parser.top().*;
        const character = parser.peek();
        if (character == 0 or character == '}') return parser.pop(.weave);
        const in_block = parser.in_block_body();
        const branch_ahead = character == '-' and in_block and parser.block_branch_ahead();
        if (branch_ahead) return parser.pop(.weave);
        if (character == '*' or character == '+' or character == '-') {
            const depth = parser.marker_depth(character);
            if (depth <= frame.level) return parser.pop(.weave);
            parser.at += depth;
            parser.skip_spaces();
            if (character == '-') {
                try parser.push_frame(.{ .kind = .line, .marker = parser.scratch_count });
                return;
            }
            try parser.push_frame(.{
                .kind = .choice,
                .marker = parser.scratch_count,
                .level = depth,
            });
            return;
        }
        if (character == '{' and parser.line_is_block_start()) {
            parser.at += 1;
            try parser.push_frame(.{ .kind = .block, .marker = parser.scratch_count });
            return parser.expression(':');
        }
        try parser.push_frame(.{ .kind = .line, .marker = parser.scratch_count });
    }

    fn in_block_body(parser: *const Parser) bool {
        var position = parser.frames_count;
        while (position > 0) {
            position -= 1;
            if (parser.frames[position].kind == .block_branch) return true;
            if (parser.frames[position].kind != .weave) return false;
        }
        return false;
    }

    /// `- something:` at the line start, inside a block: a `:` on the line outside braces.
    fn block_branch_ahead(parser: *const Parser) bool {
        assert(parser.peek() == '-');
        var depth: u32 = 0;
        var position = parser.at;
        while (position < parser.source.len and parser.source[position] != '\n') : (position += 1) {
            switch (parser.source[position]) {
                '{' => depth += 1,
                '}' => depth -|= 1,
                ':' => if (depth == 0) return true,
                else => {},
            }
        }
        return false;
    }

    fn marker_depth(parser: *const Parser, character: u8) u32 {
        var depth: u32 = 0;
        var position = parser.at;
        while (position < parser.source.len) : (position += 1) {
            const here = parser.source[position];
            if (here == character) depth += 1 else if (here != ' ') break;
        }
        return depth;
    }

    fn line_is_block_start(parser: *const Parser) bool {
        const source = parser.source;
        const end = std.mem.indexOfScalarPos(u8, source, parser.at, '\n') orelse source.len;
        return std.mem.endsWith(u8, std.mem.trimEnd(u8, parser.source[parser.at..end], " \t"), ":");
    }

    /// A choice: an optional `{condition}`, start content, `[choice only]`, the rest of the
    /// line, then a nested weave for deeper choices.
    fn choice_step(parser: *Parser) Error!void {
        const frame = parser.top();
        switch (frame.level & 0xff00) {
            0 => {
                frame.level |= 0x100;
                if (parser.peek() == '{') {
                    parser.at += 1;
                    try parser.expression('}');
                    parser.skip_spaces();
                }
                try parser.push_frame(.{
                    .kind = .line,
                    .marker = parser.scratch_count,
                    .stop = .bracket,
                });
            },
            0x100 => {
                frame.level |= 0x200;
                if (parser.peek() == '[') {
                    parser.at += 1;
                    try parser.push_frame(.{
                        .kind = .line,
                        .marker = parser.scratch_count,
                        .stop = .bracket,
                    });
                    parser.top().kind = .branch;
                } else try parser.push(.{ .tag = .missing, .data = parser.at, .count = 0 });
            },
            0x300 => {
                frame.level |= 0x400;
                if (parser.peek() == ']') parser.at += 1;
                try parser.push_frame(.{ .kind = .line, .marker = parser.scratch_count });
            },
            0x700 => {
                frame.level |= 0x800;
                try parser.push_frame(.{
                    .kind = .weave,
                    .marker = parser.scratch_count,
                    .level = frame.level & 0xff,
                });
            },
            else => try parser.pop(.choice),
        }
    }

    /// `{ cond:` then a weave body, or `{ x:` then `- case:` branches, until `}`.
    fn block_step(parser: *Parser) Error!void {
        parser.skip_blank();
        const character = parser.peek();
        if (character == '}') {
            parser.at += 1;
            return parser.pop(.block_conditional);
        }
        if (character == 0) return error.Unexpected;
        try parser.push_frame(.{ .kind = .block_branch, .marker = parser.scratch_count });
        if (character == '-' and parser.block_branch_ahead()) {
            parser.at += 1;
            parser.skip_spaces();
            if (std.mem.startsWith(u8, parser.source[parser.at..], "else")) {
                parser.at += 4;
                parser.skip_spaces();
                parser.at += 1; // ':'
            } else try parser.expression(':');
        }
        try parser.push_frame(.{ .kind = .weave, .marker = parser.scratch_count, .level = 0 });
    }

    fn block_branch_step(parser: *Parser) Error!void {
        return parser.pop(.block_branch);
    }

    /// Text and inline braces until the frame's stop: a newline, `]`, or `|`/`}`.
    fn content_step(parser: *Parser) Error!void {
        const frame = parser.top().*;
        const start = parser.at;
        while (true) {
            const character = parser.peek();
            const stops = switch (frame.stop) {
                .line => character == '\n' or character == 0,
                .bracket => character == '\n' or character == 0 or character == '[' or
                    character == ']',
                .pipe_or_brace => character == '|' or character == '}' or character == 0,
            };
            if (stops or character == '{') break;
            parser.at += 1;
        }
        if (parser.at > start) try parser.leaf(.text, start);
        if (parser.peek() == '{') {
            parser.at += 1;
            try parser.push_frame(.{ .kind = .inline_brace, .marker = parser.scratch_count });
            return;
        }
        if (frame.kind == .line and frame.stop == .line and parser.peek() == '\n') parser.at += 1;
        try parser.pop(if (frame.kind == .branch) .branch else .line);
    }

    /// After `{`: a sequence (`&`, `!`, `~`, `$`), a conditional (`expr:`), or a value.
    fn brace_step(parser: *Parser) Error!void {
        const frame = parser.top();
        if (frame.level == 0) {
            frame.level = 1;
            parser.skip_spaces();
            const character = parser.peek();
            if (character == '&' or character == '!' or character == '~' or character == '$') {
                parser.at += 1;
                frame.level = 2;
                return parser.open_branch();
            }
            const colon = parser.colon_before_close();
            try parser.expression(if (colon) ':' else '}');
            if (colon) frame.level = 3 else return parser.close_brace(.inline_value);
            return parser.open_branch();
        }
        const character = parser.peek();
        if (character == '|') {
            parser.at += 1;
            return parser.open_branch();
        }
        if (character != '}') return error.Unexpected;
        return parser.close_brace(if (frame.level == 2) .sequence else .inline_conditional);
    }

    fn open_branch(parser: *Parser) Error!void {
        try parser.push_frame(.{
            .kind = .branch,
            .marker = parser.scratch_count,
            .stop = .pipe_or_brace,
        });
    }

    fn close_brace(parser: *Parser, tag: Tag) Error!void {
        if (parser.peek() == '}') parser.at += 1;
        try parser.pop(tag);
    }

    /// Whether a `:` comes before this brace's matching `}`, at this brace depth.
    fn colon_before_close(parser: *const Parser) bool {
        var depth: u32 = 0;
        var position = parser.at;
        while (position < parser.source.len) : (position += 1) {
            switch (parser.source[position]) {
                '{' => depth += 1,
                '}' => if (depth == 0) return false else {
                    depth -= 1;
                },
                ':' => if (depth == 0) return true,
                '|' => if (depth == 0) return false,
                else => {},
            }
        }
        return false;
    }

    /// An expression up to `end` (consumed), by shunting-yard: operands go to the scratch
    /// stack, operators wait on a local stack and wrap their operands when they leave it.
    fn expression(parser: *Parser, end: u8) Error!void {
        var operators: [depth_max]Tag = undefined;
        var count: u32 = 0;
        var markers: [depth_max]u32 = undefined;
        var expect_operand = true;
        while (true) {
            parser.skip_spaces();
            const character = parser.peek();
            if (character == 0 or character == '\n') return error.Unexpected;
            if (character == end and !expect_operand) {
                parser.at += 1;
                break;
            }
            if (expect_operand) {
                if (character == '(') {
                    parser.at += 1;
                    if (count == depth_max) return error.TooDeep;
                    operators[count] = .root; // a parenthesis
                    count += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, parser.source[parser.at..], "not ")) {
                    parser.at += 4;
                    if (count == depth_max) return error.TooDeep;
                    operators[count] = .not;
                    count += 1;
                    continue;
                }
                try parser.operand();
                expect_operand = false;
                continue;
            }
            if (character == ')') {
                parser.at += 1;
                while (count > 0 and operators[count - 1] != .root) : (count -= 1) try parser.apply(
                    operators[count - 1],
                    &markers,
                );
                if (count == 0) return error.Unexpected;
                count -= 1;
                try parser.reduce_prefix(&operators, &count);
                continue;
            }
            const operator = parser.binary_operator() orelse return error.Unexpected;
            while (count > 0 and binds_tighter(operators[count - 1], operator)) : (count -= 1) {
                try parser.apply(operators[count - 1], &markers);
            }
            if (count == depth_max) return error.TooDeep;
            operators[count] = operator;
            count += 1;
            expect_operand = true;
        }
        while (count > 0) : (count -= 1) {
            if (operators[count - 1] == .root) return error.Unexpected;
            try parser.apply(operators[count - 1], &markers);
        }
    }

    /// `not` applies to the operand just finished.
    fn reduce_prefix(parser: *Parser, operators: *[depth_max]Tag, count: *u32) Error!void {
        while (count.* > 0 and operators[count.* - 1] == .not) : (count.* -= 1) {
            try parser.wrap(.not, parser.scratch_count - 1);
        }
    }

    fn operand(parser: *Parser) Error!void {
        const start = parser.at;
        const character = parser.peek();
        if (std.ascii.isDigit(character)) {
            while (std.ascii.isDigit(parser.peek())) parser.at += 1;
            return parser.leaf(.number, start);
        }
        if (!std.ascii.isAlphabetic(character) and character != '_') return error.Unexpected;
        while (std.ascii.isAlphanumeric(parser.peek()) or parser.peek() == '_') parser.at += 1;
        try parser.leaf(.identifier, start);
    }

    fn binary_operator(parser: *Parser) ?Tag {
        const rest = parser.source[parser.at..];
        const words = [_]struct { []const u8, Tag }{
            .{ "and", .@"and" }, .{ "or", .@"or" },   .{ "==", .equal }, .{ "+", .add },
            .{ "-", .subtract }, .{ "*", .multiply }, .{ "/", .divide }, .{ ">", .greater },
            .{ "<", .less },
        };
        for (words) |word| {
            if (std.mem.startsWith(u8, rest, word[0])) {
                parser.at += @intCast(word[0].len);
                return word[1];
            }
        }
        return null;
    }

    /// An operator leaves the stack: its operands are the top values (one for `not`).
    fn apply(parser: *Parser, operator: Tag, markers: *[depth_max]u32) Error!void {
        _ = markers;
        const arity: u32 = if (operator == .not) 1 else 2;
        if (parser.scratch_count < arity) return error.Unexpected;
        try parser.wrap(operator, parser.scratch_count - arity);
    }
};

fn binds_tighter(waiting: Tag, incoming: Tag) bool {
    return precedence(waiting) >= precedence(incoming);
}

fn precedence(operator: Tag) u8 {
    return switch (operator) {
        .root => 0,
        .@"or" => 1,
        .@"and" => 2,
        .equal => 3,
        .greater, .less => 4,
        .add, .subtract => 5,
        .multiply, .divide => 6,
        .not => 7,
        else => 0,
    };
}

pub fn parse(source: []const u8, parser: *Parser) Error!Ast {
    parser.* = .{ .source = source };
    return parser.run();
}

fn expect_tree(source: []const u8, expected: []const u8) !void {
    const parser = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(parser);
    const ast = try parse(source, parser);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try ast.write(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "spike: a block conditional holding a weave with nested choices" {
    try expect_tree(
        \\{ x > 1:
        \\    * [A {y}] chose {z: yes|no}
        \\    ** deeper [b] c
        \\    - gather
        \\- else:
        \\    other
        \\}
    ,
        "(root (weave (block_conditional (greater x 1) (block_branch (weave (choice " ++
            "(line) (branch \"A \" (inline_value y)) (line \" chose \" (inline_conditional z " ++
            "(branch \" yes\") (branch \"no\"))) (weave (choice (line \"deeper \") " ++
            "(branch \"b\") (line \" c\") (weave)))) (line \"gather\"))) (block_branch " ++
            "(weave (line \"other\"))))))",
    );
}

test "spike: sequences and conditionals nested inside each other" {
    try expect_tree(
        "Start {&one|{x: two {~a|b}|three}|four} end\n",
        "(root (weave (line \"Start \" (sequence (branch \"one\") (branch (inline_conditional x " ++
            "(branch \" two \" (sequence (branch \"a\") (branch \"b\"))) (branch \"three\"))) " ++
            "(branch \"four\")) \" end\")))",
    );
}

test "spike: precedence, parentheses and not in an expression" {
    try expect_tree(
        "{a + b * (c - d) > 3 and not e: yes}\n",
        "(root (weave (line (inline_conditional (and (greater (add a (multiply b " ++
            "(subtract c d))) " ++
            "3) (not e)) (branch \" yes\")))))",
    );
}

test "spike: a conditional choice with brackets and nested braces" {
    try expect_tree(
        "* {seen > 0} [Ask {about: {x}|nothing}] Asked\n- done\n",
        "(root (weave (choice (greater seen 0) (line) (branch \"Ask \" " ++
            "(inline_conditional about " ++
            "(branch \" \" (inline_value x)) (branch \"nothing\"))) (line \" Asked\") (weave)) " ++
            "(line \"done\")))",
    );
}

test "spike: a switch block with case branches holding choices" {
    try expect_tree(
        \\{ mood:
        \\- 1: Happy
        \\    * Smile
        \\- else: Sad {&a|b}
        \\}
    ,
        "(root (weave (block_conditional mood (block_branch 1 (weave (line \"Happy\") (choice " ++
            "(line \"Smile\") ? (line) (weave)))) (block_branch (weave (line \"Sad \" (sequence " ++
            "(branch \"a\") (branch \"b\"))))))))",
    );
}
