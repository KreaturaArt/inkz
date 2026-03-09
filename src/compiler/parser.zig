/// Ink source parser — converts a Token stream into a Parsed.Story tree.
///
/// The parser is purely recursive-descent with backtracking (save/restore).
/// All allocated memory is owned by the caller-supplied allocator (typically
/// an arena); the returned Parsed.Story borrows string slices directly from
/// the null-terminated source buffer (srcZ) owned by the same arena.
///
/// Parse errors (malformed declarations, etc.) are collected in the returned
/// `story.errors` slice rather than propagating as error values.  The only
/// error that can be returned is `error.OutOfMemory`.
const std = @import("std");
const Parsed = @import("parsed.zig");
const tok_mod = @import("tokenizer.zig");
const Token = tok_mod.Token;
const TokenTag = tok_mod.TokenTag;
const Tokenizer = tok_mod.Tokenizer;

// ── Public entry point ────────────────────────────────────────────────────────

/// Tokenise `src` and parse it into a Parsed.Story.
/// All allocations go into `alloc` (use an arena for easy teardown).
/// Only `error.OutOfMemory` can be returned; syntax errors go into `story.errors`.
pub fn parse(alloc: std.mem.Allocator, src: []const u8) error{OutOfMemory}!Parsed.Story {
    // Null-terminate so the tokenizer can use the NUL sentinel for EOF.
    const srcZ = try alloc.dupeZ(u8, src);
    // Tokenise the whole source up front.
    var tokens = std.ArrayList(Token).empty;
    var t = Tokenizer.init(srcZ);
    while (true) {
        const tk = t.next();
        try tokens.append(alloc, tk);
        if (tk.tag == .eof) break;
    }
    var p = Parser.init(alloc, srcZ, try tokens.toOwnedSlice(alloc));
    return p.parseStory();
}

// ── Parser ────────────────────────────────────────────────────────────────────

pub const Parser = struct {
    alloc: std.mem.Allocator,
    src: [:0]const u8,
    tokens: []const Token,
    pos: usize,
    errors: std.ArrayList(Parsed.ParseError),

    pub fn init(alloc: std.mem.Allocator, src: [:0]const u8, tokens: []const Token) Parser {
        return .{
            .alloc = alloc,
            .src = src,
            .tokens = tokens,
            .pos = 0,
            .errors = .empty,
        };
    }

    // -- Cursor helpers -------------------------------------------------------

    fn cur(self: *const Parser) Token {
        if (self.pos >= self.tokens.len)
            return .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 }, .line = 0 };
        return self.tokens[self.pos];
    }

    fn eat(self: *Parser) Token {
        const t = self.cur();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }

    fn save(self: *const Parser) usize {
        return self.pos;
    }

    fn restore(self: *Parser, s: usize) void {
        self.pos = s;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.cur().tag == .newline) _ = self.eat();
    }

    /// Consume all tokens up to (but not including) the next newline or eof.
    fn skipToEol(self: *Parser) void {
        while (true) {
            switch (self.cur().tag) {
                .newline, .eof => break,
                else => _ = self.eat(),
            }
        }
    }

    /// Consume a matching pair of { } and everything inside, including nesting.
    fn skipBraceBlock(self: *Parser) void {
        if (self.cur().tag != .left_brace) return;
        _ = self.eat();
        var depth: u32 = 1;
        while (depth > 0) {
            switch (self.cur().tag) {
                .eof => break,
                .left_brace => {
                    _ = self.eat();
                    depth += 1;
                },
                .right_brace => {
                    _ = self.eat();
                    depth -= 1;
                },
                else => _ = self.eat(),
            }
        }
    }

    fn addError(self: *Parser, tag: Parsed.ParseErrorTag, line: u32) error{OutOfMemory}!void {
        try self.errors.append(self.alloc, .{ .tag = tag, .line = line });
    }

    // -- Top-level parse ------------------------------------------------------

    pub fn parseStory(self: *Parser) error{OutOfMemory}!Parsed.Story {
        var root_content = std.ArrayList(Parsed.FlowItem).empty;
        var knots = std.ArrayList(Parsed.Knot).empty;
        var global_decls = std.ArrayList(Parsed.VarDecl).empty;
        var constants = std.ArrayList(Parsed.Constant).empty;
        var includes = std.ArrayList([]const u8).empty;

        // Root content: everything before the first knot marker.
        try self.parseContent(
            &root_content,
            &global_decls,
            &constants,
            &includes,
            false, // don't stop at stitch_marker in root
        );

        // Knots.
        while (self.cur().tag == .knot_marker) {
            const knot = try self.parseKnot(&global_decls, &constants, &includes);
            try knots.append(self.alloc, knot);
        }

        return Parsed.Story{
            .list_defs = &.{},
            .global_decls = try global_decls.toOwnedSlice(self.alloc),
            .constants = try constants.toOwnedSlice(self.alloc),
            .external_fns = &.{},
            .includes = try includes.toOwnedSlice(self.alloc),
            .knots = try knots.toOwnedSlice(self.alloc),
            .root_content = try root_content.toOwnedSlice(self.alloc),
            .errors = try self.errors.toOwnedSlice(self.alloc),
        };
    }

    // -- Content block --------------------------------------------------------

    /// Parse flow items into `items` until a stop condition is met:
    ///   • always stops at `eof` and `knot_marker`
    ///   • stops at `stitch_marker` when `stop_at_stitch` is true
    ///
    /// Uses a labeled-switch state machine: each case either returns (stop) or
    /// calls `continue :parse self.cur().tag` to re-enter for the next token.
    fn parseContent(
        self: *Parser,
        items: *std.ArrayList(Parsed.FlowItem),
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
        stop_at_stitch: bool,
    ) error{OutOfMemory}!void {
        parse: switch (self.cur().tag) {
            .eof, .knot_marker => {},

            .newline => {
                _ = self.eat();
                continue :parse self.cur().tag;
            },

            .stitch_marker => if (stop_at_stitch) {} else {
                self.skipToEol();
                continue :parse self.cur().tag;
            },

            .text => {
                const text = self.cur().loc.slice(self.src);
                if (startsWithKeyword(text, "VAR")) {
                    if (try self.parseVarLine()) |decl|
                        try global_decls.append(self.alloc, decl)
                    else
                        self.skipToEol();
                } else if (startsWithKeyword(text, "CONST")) {
                    if (try self.parseConstLine()) |c|
                        try constants.append(self.alloc, c)
                    else
                        self.skipToEol();
                } else if (startsWithKeyword(text, "INCLUDE")) {
                    if (self.parseIncludeLine()) |path|
                        try includes.append(self.alloc, path)
                    else
                        self.skipToEol();
                } else if (startsWithKeyword(text, "EXTERNAL")) {
                    self.skipToEol(); // handled in a later task
                } else {
                    if (try self.parseTextLine()) |item|
                        try items.append(self.alloc, item);
                }
                continue :parse self.cur().tag;
            },

            .divert_arrow, .divert_return => {
                if (try self.parseDivertLine()) |item|
                    try items.append(self.alloc, item);
                continue :parse self.cur().tag;
            },

            // These are handled in later tasks; skip for now.
            .logic_line, .choice_once, .choice_sticky, .gather,
            .thread_start, .hash => {
                self.skipToEol();
                continue :parse self.cur().tag;
            },

            .left_brace => {
                // Inline conditional / sequence at line start.
                self.skipBraceBlock();
                continue :parse self.cur().tag;
            },

            else => {
                _ = self.eat();
                continue :parse self.cur().tag;
            },
        }
    }

    // -- Knot / stitch --------------------------------------------------------

    fn parseKnot(
        self: *Parser,
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
    ) error{OutOfMemory}!Parsed.Knot {
        _ = self.eat(); // knot_marker

        // The rest of the header line is a text token like " knot_name ===".
        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().loc.slice(self.src))
        else
            "";
        self.skipToEol();

        // Parse knot-level content (before first stitch).
        var content = std.ArrayList(Parsed.FlowItem).empty;
        try self.parseContent(&content, global_decls, constants, includes, true);

        // Parse stitches.
        var stitches = std.ArrayList(Parsed.Stitch).empty;
        while (self.cur().tag == .stitch_marker) {
            const stitch = try self.parseStitch(global_decls, constants, includes);
            try stitches.append(self.alloc, stitch);
        }

        return Parsed.Knot{
            .name = name,
            .params = &.{},
            .is_function = false,
            .stitches = try stitches.toOwnedSlice(self.alloc),
            .content = try content.toOwnedSlice(self.alloc),
        };
    }

    fn parseStitch(
        self: *Parser,
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
    ) error{OutOfMemory}!Parsed.Stitch {
        _ = self.eat(); // stitch_marker

        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().loc.slice(self.src))
        else
            "";
        self.skipToEol();

        var content = std.ArrayList(Parsed.FlowItem).empty;
        try self.parseContent(&content, global_decls, constants, includes, true);

        return Parsed.Stitch{
            .name = name,
            .content = try content.toOwnedSlice(self.alloc),
        };
    }

    // -- Text lines -----------------------------------------------------------

    /// Parse a plain text line into FlowItem.text.
    /// Handles inline diverts (->), tags (#), and ignores {expr} blocks.
    fn parseTextLine(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        var elements = std.ArrayList(Parsed.InlineElement).empty;

        line: while (true) {
            switch (self.cur().tag) {
                .newline, .eof => break :line,

                .text => {
                    const t = self.eat();
                    const ttext = t.loc.slice(self.src);
                    // Skip empty/whitespace-only text tokens.
                    if (std.mem.indexOfNone(u8, ttext, " \t") != null)
                        try elements.append(self.alloc, .{ .text = ttext });
                },

                .left_brace => {
                    // Inline expression / conditional — skip for TASK-74.
                    self.skipBraceBlock();
                },

                .left_bracket, .right_bracket => _ = self.eat(),

                .divert_arrow => {
                    if (try self.parseDivertInline()) |d|
                        try elements.append(self.alloc, .{ .divert = d });
                    break :line;
                },

                .divert_return => {
                    _ = self.eat();
                    try elements.append(self.alloc, .{ .divert = .{
                        .target = "->->",
                        .is_tunnel = false,
                        .is_thread = false,
                        .args = &.{},
                    } });
                    break :line;
                },

                .hash => {
                    _ = self.eat();
                    const tag_text = if (self.cur().tag == .text)
                        std.mem.trim(u8, self.eat().loc.slice(self.src), " \t")
                    else
                        "";
                    if (tag_text.len > 0)
                        try elements.append(self.alloc, .{ .tag = tag_text });
                },

                // Pipe / other structural chars that can appear in text context.
                else => _ = self.eat(),
            }
        }

        if (self.cur().tag == .newline) _ = self.eat();
        if (elements.items.len == 0) return null;

        return .{ .text = .{ .elements = try elements.toOwnedSlice(self.alloc) } };
    }

    // -- Diverts --------------------------------------------------------------

    fn parseDivertLine(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        const d = try self.parseDivertInline() orelse return null;
        if (self.cur().tag == .newline) _ = self.eat();
        return .{ .divert = d };
    }

    fn parseDivertInline(self: *Parser) error{OutOfMemory}!?Parsed.Divert {
        switch (self.cur().tag) {
            .divert_return => {
                _ = self.eat();
                return .{ .target = "->->", .is_tunnel = false, .is_thread = false, .args = &.{} };
            },
            .divert_arrow => {
                _ = self.eat();
                // Target name is in the next text token.
                const target = if (self.cur().tag == .text)
                    extractFirstIdentifier(self.eat().loc.slice(self.src))
                else
                    "";
                // Trailing -> means tunnel call (e.g. "-> knot ->").
                const is_tunnel = self.cur().tag == .divert_arrow;
                if (is_tunnel) _ = self.eat();
                return .{ .target = target, .is_tunnel = is_tunnel, .is_thread = false, .args = &.{} };
            },
            else => return null,
        }
    }

    // -- Declarations ---------------------------------------------------------

    fn parseVarLine(self: *Parser) error{OutOfMemory}!?Parsed.VarDecl {
        const tok = self.eat(); // "VAR name = value ..."
        const line_text = tok.loc.slice(self.src);
        const tok_line = tok.line;
        self.skipToEol(); // consume any trailing tokens (shouldn't be any for simple literals)

        var rest = trimLeft(line_text[3..]); // skip "VAR"

        const name_end = identEnd(rest);
        if (name_end == 0) {
            try self.addError(.malformed_var_decl, tok_line);
            return null;
        }
        const name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') {
            try self.addError(.malformed_var_decl, tok_line);
            return null;
        }
        rest = trimLeft(rest[1..]);

        const expr = try parseLiteralExpr(self.alloc, rest) orelse return null;
        return .{ .name = name, .initial = expr };
    }

    fn parseConstLine(self: *Parser) error{OutOfMemory}!?Parsed.Constant {
        const tok = self.eat(); // "CONST name = value"
        const line_text = tok.loc.slice(self.src);
        const tok_line = tok.line;
        self.skipToEol();

        var rest = trimLeft(line_text[5..]); // skip "CONST"

        const name_end = identEnd(rest);
        if (name_end == 0) {
            try self.addError(.malformed_const_decl, tok_line);
            return null;
        }
        const name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') {
            try self.addError(.malformed_const_decl, tok_line);
            return null;
        }
        rest = trimLeft(rest[1..]);

        const expr = try parseLiteralExpr(self.alloc, rest) orelse return null;
        return .{ .name = name, .value = expr };
    }

    fn parseIncludeLine(self: *Parser) ?[]const u8 {
        const line_text = self.eat().loc.slice(self.src); // "INCLUDE path"
        self.skipToEol();

        const rest = std.mem.trim(u8, line_text[7..], " \t"); // skip "INCLUDE"
        if (rest.len == 0) return null;
        return rest;
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

/// True if `text` (trimmed of leading whitespace) starts with `kw` followed
/// by a space/tab or is exactly `kw`.
fn startsWithKeyword(text: []const u8, kw: []const u8) bool {
    const t = trimLeft(text);
    if (!std.mem.startsWith(u8, t, kw)) return false;
    if (t.len == kw.len) return true;
    return t[kw.len] == ' ' or t[kw.len] == '\t';
}

/// Return the length of the leading identifier in `s`
/// (alphanumeric, `_`, `.` for dotted paths).
fn identEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') break;
    }
    return i;
}

/// Extract the first identifier (alphanumeric + `_` + `.`) from text that
/// may have leading whitespace and trailing junk (e.g. " knot_name ===").
fn extractFirstIdentifier(text: []const u8) []const u8 {
    const trimmed = trimLeft(text);
    return trimmed[0..identEnd(trimmed)];
}

/// Parse a literal expression from a trimmed string value.
/// Handles: integers, floats, booleans, double-quoted strings, identifiers.
fn parseLiteralExpr(alloc: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?*Parsed.Expression {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    const e = try alloc.create(Parsed.Expression);

    // Boolean literals.
    if (std.mem.eql(u8, s, "true")) {
        e.* = .{ .bool_lit = true };
        return e;
    }
    if (std.mem.eql(u8, s, "false")) {
        e.* = .{ .bool_lit = false };
        return e;
    }

    // Double-quoted string literal.
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        e.* = .{ .string_lit = s[1 .. s.len - 1] };
        return e;
    }

    // Integer literal (including negative).
    if (std.fmt.parseInt(i64, s, 10)) |v| {
        e.* = .{ .int_lit = v };
        return e;
    } else |_| {}

    // Float literal.
    if (std.fmt.parseFloat(f64, s)) |v| {
        e.* = .{ .float_lit = v };
        return e;
    } else |_| {}

    // Identifier reference (for `VAR x = c` where c is a CONST).
    if (identEnd(s) == s.len) {
        e.* = .{ .var_ref = s };
        return e;
    }

    alloc.destroy(e);
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn readOriginalFixture(alloc: std.mem.Allocator, comptime rel: []const u8) ![]u8 {
    const path = "test/fixture/original/" ++ rel;
    const io = std.testing.io;
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
}

test "Compiler parser: hello_world.ink root_content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try readOriginalFixture(alloc, "runtime/misc/hello_world.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    try testing.expectEqual(@as(usize, 0), story.knots.len);

    const item = story.root_content[0];
    try testing.expect(item == .text);
    try testing.expectEqual(@as(usize, 1), item.text.elements.len);
    try testing.expect(item.text.elements[0] == .text);
    try testing.expectEqualStrings("Hello world", item.text.elements[0].text);
}

test "Compiler parser: end_of_content.ink knot name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // == test == \n Content \n -> END
    const src = try readOriginalFixture(alloc, "runtime/misc/end_of_content.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 1), story.knots.len);
    try testing.expectEqualStrings("test", story.knots[0].name);
}

test "Compiler parser: knot_do_not_gather.ink knot name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try readOriginalFixture(alloc, "runtime/knots/knot_do_not_gather.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 1), story.knots.len);
    try testing.expectEqualStrings("knot", story.knots[0].name);
    // root_content starts with a divert to "knot"
    try testing.expect(story.root_content.len > 0);
    try testing.expect(story.root_content[0] == .divert);
    try testing.expectEqualStrings("knot", story.root_content[0].divert.target);
}

test "Compiler parser: VAR declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // VAR x = 5 \n {x} \n ...
    const src = try readOriginalFixture(alloc, "runtime/variables/variable_get_set_api.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 1), story.global_decls.len);
    try testing.expectEqualStrings("x", story.global_decls[0].name);
    try testing.expect(story.global_decls[0].initial.* == .int_lit);
    try testing.expectEqual(@as(i64, 5), story.global_decls[0].initial.int_lit);
}

test "Compiler parser: CONST declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // VAR x = c \n CONST c = 5 \n {x}
    const src = try readOriginalFixture(alloc, "runtime/variables/const.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 1), story.constants.len);
    try testing.expectEqualStrings("c", story.constants[0].name);
    try testing.expect(story.constants[0].value.* == .int_lit);
    try testing.expectEqual(@as(i64, 5), story.constants[0].value.int_lit);
}

test "Compiler parser: INCLUDE paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try readOriginalFixture(alloc, "runtime/misc/include.ink");
    const story = try parse(alloc, src);

    try testing.expectEqual(@as(usize, 2), story.includes.len);
    try testing.expectEqualStrings("includes/included_file.ink", story.includes[0]);
    try testing.expectEqualStrings("includes/included_file_2.ink", story.includes[1]);
}

test "Compiler parser: knot_thread_interaction knot names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try readOriginalFixture(alloc, "runtime/knots/knot_thread_interaction.ink");
    const story = try parse(alloc, src);

    // Three knots: knot, tunnel, threadB
    try testing.expectEqual(@as(usize, 3), story.knots.len);
    try testing.expectEqualStrings("knot", story.knots[0].name);
    try testing.expectEqualStrings("tunnel", story.knots[1].name);
    try testing.expectEqualStrings("threadB", story.knots[2].name);
}

// ── Corner-case tests (inline source strings) ─────────────────────────────────

test "Compiler parser: empty source produces empty story" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), story.root_content.len);
    try testing.expectEqual(@as(usize, 0), story.knots.len);
    try testing.expectEqual(@as(usize, 0), story.global_decls.len);
}

test "Compiler parser: only newlines produces empty story" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "\n\n\n");
    try testing.expectEqual(@as(usize, 0), story.root_content.len);
    try testing.expectEqual(@as(usize, 0), story.knots.len);
}

test "Compiler parser: only comments produces empty story" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "// a comment\n/* block\ncomment */\n");
    try testing.expectEqual(@as(usize, 0), story.root_content.len);
}

test "Compiler parser: divert to END" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "-> END\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const d = story.root_content[0];
    try testing.expect(d == .divert);
    try testing.expectEqualStrings("END", d.divert.target);
    try testing.expect(!d.divert.is_tunnel);
}

test "Compiler parser: divert to DONE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "-> DONE\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    try testing.expectEqualStrings("DONE", story.root_content[0].divert.target);
}

test "Compiler parser: divert_return ->->" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "->->\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const d = story.root_content[0];
    try testing.expect(d == .divert);
    try testing.expectEqualStrings("->->", d.divert.target);
}

test "Compiler parser: tunnel call -> target ->" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "-> mytunnel ->\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const d = story.root_content[0];
    try testing.expect(d == .divert);
    try testing.expectEqualStrings("mytunnel", d.divert.target);
    try testing.expect(d.divert.is_tunnel);
}

test "Compiler parser: dotted divert path knot.stitch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "-> outer.inner\n");
    const d = story.root_content[0];
    try testing.expect(d == .divert);
    try testing.expectEqualStrings("outer.inner", d.divert.target);
}

test "Compiler parser: inline divert at end of text line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "go there -> target" — text stops before ->, then divert element.
    const story = try parse(arena.allocator(), "go there -> target\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const item = story.root_content[0];
    try testing.expect(item == .text);
    const elems = item.text.elements;
    try testing.expect(elems.len >= 2);
    try testing.expect(elems[0] == .text);
    try testing.expect(std.mem.indexOf(u8, elems[0].text, "go") != null);
    try testing.expect(elems[elems.len - 1] == .divert);
    try testing.expectEqualStrings("target", elems[elems.len - 1].divert.target);
}

test "Compiler parser: text line with hash tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "Some text # mytag\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const item = story.root_content[0];
    try testing.expect(item == .text);
    var found_tag = false;
    for (item.text.elements) |e| {
        if (e == .tag and std.mem.eql(u8, e.tag, "mytag")) found_tag = true;
    }
    try testing.expect(found_tag);
}

test "Compiler parser: brace block at line start is skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A bare {expr} line contributes no FlowItem (skipped for TASK-74).
    const story = try parse(arena.allocator(), "{2 + 3}\n");
    try testing.expectEqual(@as(usize, 0), story.root_content.len);
}

test "Compiler parser: nested braces skipped correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "{outer {inner} still}\ntext\n");
    // The brace block is skipped; "text" comes through as a FlowItem.
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    try testing.expect(story.root_content[0] == .text);
}

test "Compiler parser: VAR bool true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR flag = true\n");
    try testing.expectEqual(@as(usize, 1), story.global_decls.len);
    try testing.expectEqualStrings("flag", story.global_decls[0].name);
    try testing.expect(story.global_decls[0].initial.* == .bool_lit);
    try testing.expectEqual(true, story.global_decls[0].initial.bool_lit);
}

test "Compiler parser: VAR bool false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR flag = false\n");
    try testing.expect(story.global_decls[0].initial.* == .bool_lit);
    try testing.expectEqual(false, story.global_decls[0].initial.bool_lit);
}

test "Compiler parser: VAR float literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR pi = 3.14\n");
    try testing.expectEqual(@as(usize, 1), story.global_decls.len);
    try testing.expect(story.global_decls[0].initial.* == .float_lit);
    try testing.expectApproxEqAbs(@as(f64, 3.14), story.global_decls[0].initial.float_lit, 1e-9);
}

test "Compiler parser: VAR negative integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR debt = -42\n");
    try testing.expect(story.global_decls[0].initial.* == .int_lit);
    try testing.expectEqual(@as(i64, -42), story.global_decls[0].initial.int_lit);
}

test "Compiler parser: VAR string literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR name = \"Alice\"\n");
    try testing.expect(story.global_decls[0].initial.* == .string_lit);
    try testing.expectEqualStrings("Alice", story.global_decls[0].initial.string_lit);
}

test "Compiler parser: VAR identifier reference (CONST forwarding)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR x = MYCONST\n");
    try testing.expect(story.global_decls[0].initial.* == .var_ref);
    try testing.expectEqualStrings("MYCONST", story.global_decls[0].initial.var_ref);
}

test "Compiler parser: multiple VAR declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR a = 1\nVAR b = 2\nVAR c = 3\n");
    try testing.expectEqual(@as(usize, 3), story.global_decls.len);
    try testing.expectEqualStrings("a", story.global_decls[0].name);
    try testing.expectEqualStrings("b", story.global_decls[1].name);
    try testing.expectEqualStrings("c", story.global_decls[2].name);
    try testing.expectEqual(@as(i64, 1), story.global_decls[0].initial.int_lit);
    try testing.expectEqual(@as(i64, 2), story.global_decls[1].initial.int_lit);
    try testing.expectEqual(@as(i64, 3), story.global_decls[2].initial.int_lit);
}

test "Compiler parser: malformed VAR no equals — no crash, parse error recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "VAR x" with no = value — parser records an error and skips.
    const story = try parse(arena.allocator(), "VAR x\nsome text\n");
    try testing.expectEqual(@as(usize, 0), story.global_decls.len);
    // A parse error must be recorded.
    try testing.expectEqual(@as(usize, 1), story.errors.len);
    try testing.expectEqual(Parsed.ParseErrorTag.malformed_var_decl, story.errors[0].tag);
    // The text line after should still be parsed.
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
}

test "Compiler parser: malformed VAR no name — no crash, parse error recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "VAR = 5\ntext\n");
    try testing.expectEqual(@as(usize, 0), story.global_decls.len);
    try testing.expectEqual(@as(usize, 1), story.errors.len);
    try testing.expectEqual(Parsed.ParseErrorTag.malformed_var_decl, story.errors[0].tag);
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
}

test "Compiler parser: CONST all literal types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "CONST a = 7\nCONST b = 2.5\nCONST c = true\nCONST d = \"hi\"\n");
    try testing.expectEqual(@as(usize, 4), story.constants.len);
    try testing.expect(story.constants[0].value.* == .int_lit);
    try testing.expect(story.constants[1].value.* == .float_lit);
    try testing.expect(story.constants[2].value.* == .bool_lit);
    try testing.expect(story.constants[3].value.* == .string_lit);
}

test "Compiler parser: knot_marker === three-equals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "=== myknot ===\n");
    try testing.expectEqual(@as(usize, 1), story.knots.len);
    try testing.expectEqualStrings("myknot", story.knots[0].name);
}

test "Compiler parser: knot_marker == two-equals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "== myknot ==\n");
    try testing.expectEqual(@as(usize, 1), story.knots.len);
    try testing.expectEqualStrings("myknot", story.knots[0].name);
}

test "Compiler parser: knot with text and divert content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "=== myknot ===\nSome content\n-> END\n");
    try testing.expectEqual(@as(usize, 1), story.knots.len);
    const k = story.knots[0];
    try testing.expectEqualStrings("myknot", k.name);
    try testing.expectEqual(@as(usize, 2), k.content.len);
    try testing.expect(k.content[0] == .text);
    try testing.expect(k.content[1] == .divert);
    try testing.expectEqualStrings("END", k.content[1].divert.target);
}

test "Compiler parser: empty knot (no content before next knot)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "=== empty ===\n=== next ===\n");
    try testing.expectEqual(@as(usize, 2), story.knots.len);
    try testing.expectEqualStrings("empty", story.knots[0].name);
    try testing.expectEqual(@as(usize, 0), story.knots[0].content.len);
    try testing.expectEqual(@as(usize, 0), story.knots[0].stitches.len);
    try testing.expectEqualStrings("next", story.knots[1].name);
}

test "Compiler parser: knot with single stitch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "=== myknot ===\n= mystitch\nStitch text\n");
    try testing.expectEqual(@as(usize, 1), story.knots.len);
    const k = story.knots[0];
    try testing.expectEqual(@as(usize, 1), k.stitches.len);
    try testing.expectEqualStrings("mystitch", k.stitches[0].name);
    try testing.expectEqual(@as(usize, 1), k.stitches[0].content.len);
    try testing.expect(k.stitches[0].content[0] == .text);
}

test "Compiler parser: knot with multiple stitches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "=== k ===\n= s1\nA\n= s2\nB\n= s3\nC\n");
    const k = story.knots[0];
    try testing.expectEqual(@as(usize, 3), k.stitches.len);
    try testing.expectEqualStrings("s1", k.stitches[0].name);
    try testing.expectEqualStrings("s2", k.stitches[1].name);
    try testing.expectEqualStrings("s3", k.stitches[2].name);
}

test "Compiler parser: VAR inside stitch goes to global_decls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "=== k ===\n= s\nVAR counter = 0\n");
    try testing.expectEqual(@as(usize, 1), story.global_decls.len);
    try testing.expectEqualStrings("counter", story.global_decls[0].name);
    try testing.expectEqual(@as(i64, 0), story.global_decls[0].initial.int_lit);
}

test "Compiler parser: multiple knots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "=== a ===\ntext a\n=== b ===\ntext b\n=== c ===\ntext c\n");
    try testing.expectEqual(@as(usize, 3), story.knots.len);
    try testing.expectEqualStrings("a", story.knots[0].name);
    try testing.expectEqualStrings("b", story.knots[1].name);
    try testing.expectEqualStrings("c", story.knots[2].name);
    for (story.knots) |k| {
        try testing.expectEqual(@as(usize, 1), k.content.len);
        try testing.expect(k.content[0] == .text);
    }
}

test "Compiler parser: root content before first knot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(),
        "-> start\n=== start ===\nKnot text\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    try testing.expect(story.root_content[0] == .divert);
    try testing.expectEqualStrings("start", story.root_content[0].divert.target);
    try testing.expectEqual(@as(usize, 1), story.knots.len);
}

test "Compiler parser: glue <> preserved inside text element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // <> glue: < is not followed by -, so it stays in the text token.
    const story = try parse(arena.allocator(), "hello <> world\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const item = story.root_content[0];
    try testing.expect(item == .text);
    // The text element must contain the glue chars.
    var found_glue = false;
    for (item.text.elements) |e| {
        if (e == .text and std.mem.indexOf(u8, e.text, "<>") != null)
            found_glue = true;
    }
    try testing.expect(found_glue);
}

test "Compiler parser: whitespace-only text line produces no FlowItem" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A line with only spaces — the tokenizer skips leading whitespace, so
    // nothing remains and parseTextLine returns null.
    const story = try parse(arena.allocator(), "   \nreal text\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    try testing.expect(story.root_content[0] == .text);
}

// ── Fixture tests ─────────────────────────────────────────────────────────────

test "Compiler parser: stitch_gather_counts VAR in knot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try readOriginalFixture(alloc, "runtime/knots/knot_stitch_gather_counts.ink");
    const story = try parse(alloc, src);

    // Global decls include knotCount, stitchCount, and gatherCount (inside knot).
    const names = [_][]const u8{ "knotCount", "stitchCount", "gatherCount" };
    for (names) |name| {
        var found = false;
        for (story.global_decls) |d| {
            if (std.mem.eql(u8, d.name, name)) { found = true; break; }
        }
        try testing.expect(found);
    }
}
