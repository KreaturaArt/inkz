/// Ink source parser — converts a Token stream into a Parsed.Story tree.
///
/// The parser is purely recursive-descent with backtracking (save/restore).
/// All allocated memory is owned by the caller-supplied allocator (typically
/// an arena); the returned Parsed.Story borrows string slices directly from
/// the token text (which in turn point into the original source buffer).
const std = @import("std");
const Parsed = @import("parsed.zig");
const tok_mod = @import("tokenizer.zig");
const Token = tok_mod.Token;
const TokenTag = tok_mod.TokenTag;
const Tokenizer = tok_mod.Tokenizer;

// ── Public entry point ────────────────────────────────────────────────────────

/// Tokenise `src` and parse it into a Parsed.Story.
/// All allocations go into `alloc` (use an arena for easy teardown).
pub fn parse(alloc: std.mem.Allocator, src: []const u8) !Parsed.Story {
    // Tokenise the whole source up front.
    var tokens = std.ArrayList(Token).empty;
    var t = Tokenizer.init(src);
    while (true) {
        const tk = t.next();
        try tokens.append(alloc, tk);
        if (tk.tag == .eof) break;
    }
    var p = Parser.init(alloc, try tokens.toOwnedSlice(alloc));
    return p.parseStory();
}

// ── Parser ────────────────────────────────────────────────────────────────────

pub const Parser = struct {
    alloc: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,

    pub fn init(alloc: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .alloc = alloc, .tokens = tokens, .pos = 0 };
    }

    // -- Cursor helpers -------------------------------------------------------

    fn cur(self: *const Parser) Token {
        if (self.pos >= self.tokens.len)
            return .{ .tag = .eof, .text = "", .line = 0, .col = 0 };
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

    // -- Top-level parse ------------------------------------------------------

    pub fn parseStory(self: *Parser) !Parsed.Story {
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
        };
    }

    // -- Content block --------------------------------------------------------

    /// Parse flow items into `items` until a stop condition is met:
    ///   • always stops at `eof` and `knot_marker`
    ///   • stops at `stitch_marker` when `stop_at_stitch` is true
    fn parseContent(
        self: *Parser,
        items: *std.ArrayList(Parsed.FlowItem),
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
        stop_at_stitch: bool,
    ) !void {
        while (true) {
            self.skipNewlines();

            switch (self.cur().tag) {
                .eof, .knot_marker => break,
                .stitch_marker => if (stop_at_stitch) break else {
                    self.skipToEol();
                },

                .text => {
                    const text = self.cur().text;
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
                },

                .divert_arrow, .divert_return => {
                    if (try self.parseDivertLine()) |item|
                        try items.append(self.alloc, item);
                },

                // These are handled in later tasks; skip for now.
                .logic_line, .choice_once, .choice_sticky, .gather,
                .thread_start, .hash => self.skipToEol(),

                .left_brace => {
                    // Inline conditional / sequence at line start.
                    self.skipBraceBlock();
                    if (self.cur().tag == .newline) _ = self.eat();
                },

                else => _ = self.eat(),
            }
        }
    }

    // -- Knot / stitch --------------------------------------------------------

    fn parseKnot(
        self: *Parser,
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
    ) !Parsed.Knot {
        _ = self.eat(); // knot_marker

        // The rest of the header line is a text token like " knot_name ===".
        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().text)
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
    ) !Parsed.Stitch {
        _ = self.eat(); // stitch_marker

        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().text)
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
    fn parseTextLine(self: *Parser) !?Parsed.FlowItem {
        var elements = std.ArrayList(Parsed.InlineElement).empty;

        line: while (true) {
            switch (self.cur().tag) {
                .newline, .eof => break :line,

                .text => {
                    const t = self.eat();
                    // Skip empty/whitespace-only text tokens.
                    if (std.mem.indexOfNone(u8, t.text, " \t") != null)
                        try elements.append(self.alloc, .{ .text = t.text });
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
                        std.mem.trim(u8, self.eat().text, " \t")
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

    fn parseDivertLine(self: *Parser) !?Parsed.FlowItem {
        const d = try self.parseDivertInline() orelse return null;
        if (self.cur().tag == .newline) _ = self.eat();
        return .{ .divert = d };
    }

    fn parseDivertInline(self: *Parser) !?Parsed.Divert {
        switch (self.cur().tag) {
            .divert_return => {
                _ = self.eat();
                return .{ .target = "->->", .is_tunnel = false, .is_thread = false, .args = &.{} };
            },
            .divert_arrow => {
                _ = self.eat();
                // Target name is in the next text token.
                const target = if (self.cur().tag == .text)
                    extractFirstIdentifier(self.eat().text)
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

    fn parseVarLine(self: *Parser) !?Parsed.VarDecl {
        const line_text = self.eat().text; // "VAR name = value ..."
        self.skipToEol(); // consume any trailing tokens (shouldn't be any for simple literals)

        var rest = trimLeft(line_text[3..]); // skip "VAR"

        const name_end = identEnd(rest);
        if (name_end == 0) return null;
        const name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') return null;
        rest = trimLeft(rest[1..]);

        const expr = try parseLiteralExpr(self.alloc, rest) orelse return null;
        return .{ .name = name, .initial = expr };
    }

    fn parseConstLine(self: *Parser) !?Parsed.Constant {
        const line_text = self.eat().text; // "CONST name = value"
        self.skipToEol();

        var rest = trimLeft(line_text[5..]); // skip "CONST"

        const name_end = identEnd(rest);
        if (name_end == 0) return null;
        const name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') return null;
        rest = trimLeft(rest[1..]);

        const expr = try parseLiteralExpr(self.alloc, rest) orelse return null;
        return .{ .name = name, .value = expr };
    }

    fn parseIncludeLine(self: *Parser) ?[]const u8 {
        const line_text = self.eat().text; // "INCLUDE path"
        self.skipToEol();

        var rest = std.mem.trim(u8, line_text[7..], " \t"); // skip "INCLUDE"
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
fn parseLiteralExpr(alloc: std.mem.Allocator, raw: []const u8) !?*Parsed.Expression {
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
const builtin = @import("builtin");

fn readOriginalFixture(alloc: std.mem.Allocator, comptime rel: []const u8) ![]u8 {
    const path = "test/fixture/original/" ++ rel;
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
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
