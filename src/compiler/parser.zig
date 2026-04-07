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
    /// Names declared with `~ temp` in the current scope, used to determine
    /// whether `~ name = expr` is a temp reassignment or a global assignment.
    temp_names: std.ArrayList([]const u8),
    /// When a gather label `(name)` is extracted from a text token that also has
    /// trailing content, this holds a synthetic token for the trailing text so
    /// subsequent parsing sees it.  Cleared by eat().
    overhang_tok: ?Token = null,

    pub fn init(alloc: std.mem.Allocator, src: [:0]const u8, tokens: []const Token) Parser {
        return .{
            .alloc = alloc,
            .src = src,
            .tokens = tokens,
            .pos = 0,
            .errors = .empty,
            .temp_names = .empty,
        };
    }

    // -- Cursor helpers -------------------------------------------------------

    fn cur(self: *const Parser) Token {
        if (self.overhang_tok) |ot| return ot;
        if (self.pos >= self.tokens.len)
            return .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 }, .line = 0 };
        return self.tokens[self.pos];
    }

    fn eat(self: *Parser) Token {
        if (self.overhang_tok) |ot| {
            self.overhang_tok = null;
            return ot;
        }
        const t = self.cur();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }

    fn save(self: *const Parser) usize {
        return self.pos;
    }

    fn restore(self: *Parser, s: usize) void {
        self.pos = s;
        self.overhang_tok = null;
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

    fn collectLineSource(self: *Parser) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        while (true) {
            switch (self.cur().tag) {
                .newline, .eof => break,
                else => {
                    const tok = self.eat();
                    try buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                },
            }
        }
        return buf.toOwnedSlice(self.alloc);
    }

    fn collectBraceHeaderUntilColon(self: *Parser) !?struct { expr_text: []const u8, after_colon: []const u8 } {
        var expr_buf = std.ArrayList(u8).empty;
        var after_buf = std.ArrayList(u8).empty;
        var found_colon = false;

        while (true) {
            switch (self.cur().tag) {
                .newline, .right_brace, .eof => break,
                .pipe => {
                    const tok = self.eat();
                    if (found_colon) {
                        try after_buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                    } else {
                        try expr_buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                    }
                },
                .colon => {
                    _ = self.eat();
                    found_colon = true;
                    break;
                },
                .text => {
                    const tok = self.eat();
                    const slice = tok.loc.slice(self.src);
                    if (found_colon) {
                        try after_buf.appendSlice(self.alloc, slice);
                    } else if (std.mem.indexOfScalar(u8, slice, ':')) |cp| {
                        try expr_buf.appendSlice(self.alloc, slice[0..cp]);
                        try after_buf.appendSlice(self.alloc, slice[cp + 1 ..]);
                        found_colon = true;
                        break;
                    } else {
                        try expr_buf.appendSlice(self.alloc, slice);
                    }
                },
                else => {
                    const tok = self.eat();
                    const slice = tok.loc.slice(self.src);
                    if (found_colon) {
                        try after_buf.appendSlice(self.alloc, slice);
                    } else {
                        try expr_buf.appendSlice(self.alloc, slice);
                    }
                },
            }
        }

        if (!found_colon) return null;
        return .{
            .expr_text = std.mem.trim(u8, try expr_buf.toOwnedSlice(self.alloc), " \t"),
            .after_colon = trimLeft(try after_buf.toOwnedSlice(self.alloc)),
        };
    }

    fn collectLineRemainder(self: *Parser) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        while (true) {
            switch (self.cur().tag) {
                .newline, .eof, .right_brace => break,
                else => {
                    const tok = self.eat();
                    try buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                },
            }
        }
        return trimLeft(try buf.toOwnedSlice(self.alloc));
    }

    /// Consume a matching pair of { } and everything inside, including nesting.
    /// Peek: returns true if the current `{` block contains a newline before its matching `}`.
    /// Does not consume any tokens.
    fn braceContainsNewline(self: *Parser) bool {
        if (self.cur().tag != .left_brace) return false;
        const saved = self.save();
        defer self.restore(saved);
        _ = self.eat(); // {
        var depth: u32 = 1;
        while (depth > 0) {
            switch (self.cur().tag) {
                .eof => return false,
                .newline => return true,
                .left_brace => { _ = self.eat(); depth += 1; },
                .right_brace => { _ = self.eat(); depth -= 1; },
                else => _ = self.eat(),
            }
        }
        return false;
    }

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
        var list_defs = std.ArrayList(Parsed.ListDef).empty;
        var external_fns = std.ArrayList(Parsed.ExternalFn).empty;

        // Root content: stop at knot_marker or stitch_marker.
        try self.parseContent(
            &root_content,
            &global_decls,
            &constants,
            &includes,
            &list_defs,
            &external_fns,
            true, // stop at stitch_marker so outer loop handles top-level stitches
        );

        // Knots (and top-level stitches, which behave like knots).
        while (self.cur().tag == .knot_marker or self.cur().tag == .stitch_marker) {
            const knot = try self.parseKnot(&global_decls, &constants, &includes, &list_defs, &external_fns);
            try knots.append(self.alloc, knot);
        }

        return Parsed.Story{
            .list_defs = try list_defs.toOwnedSlice(self.alloc),
            .global_decls = try global_decls.toOwnedSlice(self.alloc),
            .constants = try constants.toOwnedSlice(self.alloc),
            .external_fns = try external_fns.toOwnedSlice(self.alloc),
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
        list_defs: *std.ArrayList(Parsed.ListDef),
        external_fns: *std.ArrayList(Parsed.ExternalFn),
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
                } else if (startsWithKeyword(text, "LIST")) {
                    if (try self.parseListLine()) |ld|
                        try list_defs.append(self.alloc, ld)
                    else
                        self.skipToEol();
                } else if (startsWithKeyword(text, "INCLUDE")) {
                    if (self.parseIncludeLine()) |path|
                        try includes.append(self.alloc, path)
                    else
                        self.skipToEol();
                } else if (startsWithKeyword(text, "EXTERNAL")) {
                    if (self.parseExternalLine()) |ef|
                        try external_fns.append(self.alloc, ef)
                    else
                        self.skipToEol();
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

            .logic_line => {
                if (try self.parseLogicLine()) |item|
                    try items.append(self.alloc, item);
                continue :parse self.cur().tag;
            },

            .choice_once, .choice_sticky => {
                if (try self.parseChoiceItem()) |item|
                    try items.append(self.alloc, item);
                continue :parse self.cur().tag;
            },

            .gather => {
                if (try self.parseGatherItem()) |item|
                    try items.append(self.alloc, item);
                continue :parse self.cur().tag;
            },

            .hash => {
                _ = self.eat(); // consume #
                const tag_text = if (self.cur().tag == .text)
                    std.mem.trim(u8, self.eat().loc.slice(self.src), " \t")
                else
                    "";
                self.skipToEol();
                if (tag_text.len > 0)
                    try items.append(self.alloc, .{ .tag = tag_text });
                continue :parse self.cur().tag;
            },

            .thread_start => {
                _ = self.eat(); // <-
                const target = if (self.cur().tag == .text) blk: {
                    const t = self.eat();
                    break :blk std.mem.trim(u8, t.loc.slice(self.src), " \t");
                } else "";
                self.skipToEol();
                if (target.len > 0) {
                    try items.append(self.alloc, .{ .thread_start = target });
                }
                continue :parse self.cur().tag;
            },

            .left_brace => {
                // Try block sequence first (e.g. {stopping:\n - a\n}).
                if (try self.parseBraceSequenceBlock()) |seq| {
                    try items.append(self.alloc, .{ .sequence = seq });
                } else if (try self.parseBraceConditional()) |cond| {
                    try items.append(self.alloc, .{ .conditional = cond });
                } else if (try self.parseTextLine()) |item| {
                    // Handles inline expressions {x}{y}.
                    try items.append(self.alloc, item);
                } else {
                    // All block parsers failed — skip to prevent infinite loop.
                    self.skipBraceBlock();
                }
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
        list_defs: *std.ArrayList(Parsed.ListDef),
        external_fns: *std.ArrayList(Parsed.ExternalFn),
    ) error{OutOfMemory}!Parsed.Knot {
        const is_stitch = self.cur().tag == .stitch_marker;
        _ = self.eat(); // knot_marker or stitch_marker

        // The rest of the header line is a text token like " knot_name ===" or
        // " function knot_name ===" (with optional "function" modifier keyword).
        var is_function = false;
        var knot_params: []Parsed.Param = &.{};
        var header_buf = std.ArrayList(u8).empty;
        while (self.cur().tag != .newline and self.cur().tag != .eof) {
            switch (self.cur().tag) {
                .text => try header_buf.appendSlice(self.alloc, self.eat().loc.slice(self.src)),
                .divert_arrow => {
                    _ = self.eat();
                    try header_buf.appendSlice(self.alloc, "->");
                },
                .divert_return => {
                    _ = self.eat();
                    try header_buf.appendSlice(self.alloc, "->->");
                },
                else => _ = self.eat(),
            }
        }

        const name = if (header_buf.items.len > 0) blk: {
            const t = trimLeft(header_buf.items);
            // Check for "function" keyword modifier (e.g. "== function name ==").
            const name_part: []const u8 = if (std.mem.startsWith(u8, t, "function") and
                (t.len <= 8 or t[8] == ' ' or t[8] == '\t' or t[8] == '('))
            blk2: {
                is_function = true;
                const rest = trimLeft(t[8..]);
                break :blk2 rest;
            } else t;
            const name_end = identEnd(name_part);
            // Parse optional parameter list "(x, y, ref z)" after the name.
            const after_name = trimLeft(name_part[name_end..]);
            if (after_name.len > 0 and after_name[0] == '(') {
                knot_params = try parseParamList(self.alloc, after_name);
            }
            break :blk name_part[0..name_end];
        } else "";
        self.skipToEol();

        // Parse knot-level content (before first stitch).
        var content = std.ArrayList(Parsed.FlowItem).empty;
        try self.parseContent(&content, global_decls, constants, includes, list_defs, external_fns, true);

        // Parse stitches (knots only — stitches cannot have sub-stitches).
        var stitches = std.ArrayList(Parsed.Stitch).empty;
        if (!is_stitch) {
            while (self.cur().tag == .stitch_marker) {
                const stitch = try self.parseStitch(global_decls, constants, includes, list_defs, external_fns);
                try stitches.append(self.alloc, stitch);
            }
        }

        return Parsed.Knot{
            .name = name,
            .params = knot_params,
            .is_function = is_function,
            .stitches = try stitches.toOwnedSlice(self.alloc),
            .content = try content.toOwnedSlice(self.alloc),
        };
    }

    fn parseStitch(
        self: *Parser,
        global_decls: *std.ArrayList(Parsed.VarDecl),
        constants: *std.ArrayList(Parsed.Constant),
        includes: *std.ArrayList([]const u8),
        list_defs: *std.ArrayList(Parsed.ListDef),
        external_fns: *std.ArrayList(Parsed.ExternalFn),
    ) error{OutOfMemory}!Parsed.Stitch {
        _ = self.eat(); // stitch_marker

        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().loc.slice(self.src))
        else
            "";
        self.skipToEol();

        var content = std.ArrayList(Parsed.FlowItem).empty;
        try self.parseContent(&content, global_decls, constants, includes, list_defs, external_fns, true);

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
        var trailing_newline = true;

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
                    if (try self.parseBraceSequenceInline()) |seq| {
                        try elements.append(self.alloc, .{ .sequence = seq });
                    } else if (try self.parseBraceExpr()) |expr| {
                        try elements.append(self.alloc, .{ .inline_expr = expr });
                    } else {
                        // Non-expression brace content should be handled by the outer
                        // content parser as its own FlowItem (for example inline and
                        // block conditionals that appear after earlier text on a line).
                        trailing_newline = false;
                        break :line;
                    }
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

                // Block terminators — stop the line, don't consume.
                .right_brace, .gather, .knot_marker, .stitch_marker => break :line,

                // Pipe / other structural chars that can appear in text context.
                else => _ = self.eat(),
            }
        }

        if (self.cur().tag == .newline) _ = self.eat();
        if (elements.items.len == 0) return null;

        return .{ .text = .{
            .elements = try elements.toOwnedSlice(self.alloc),
            .trailing_newline = trailing_newline,
        } };
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
                // Check for "->-> target (args)" — tunnel-onwards with explicit target.
                if (self.cur().tag == .text) {
                    const raw = self.cur().loc.slice(self.src);
                    const t = trimLeft(raw);
                    const name_end = identEnd(t);
                    if (name_end > 0 and t[0] != '=') {
                        _ = self.eat(); // consume the text token
                        const target = t[0..name_end];
                        var args: []*Parsed.Expression = &.{};
                        const after_name = trimLeft(t[name_end..]);
                        if (after_name.len > 0 and after_name[0] == '(') {
                            // Parse arg list inline.
                            var arg_buf = std.ArrayList(u8).empty;
                            const initial = after_name[1..];
                            var close_found = false;
                            if (std.mem.indexOfScalar(u8, initial, ')')) |end| {
                                try arg_buf.appendSlice(self.alloc, initial[0..end]);
                                close_found = true;
                            } else {
                                try arg_buf.appendSlice(self.alloc, initial);
                                while (!close_found) {
                                    switch (self.cur().tag) {
                                    .newline, .eof => break,
                                    .text => {
                                        const more = self.eat().loc.slice(self.src);
                                        if (std.mem.indexOfScalar(u8, more, ')')) |end| {
                                            try arg_buf.appendSlice(self.alloc, more[0..end]);
                                            close_found = true;
                                            } else try arg_buf.appendSlice(self.alloc, more);
                                        },
                                        else => _ = self.eat(),
                                    }
                                }
                            }
                            if (close_found) {
                                var arg_list = std.ArrayList(*Parsed.Expression).empty;
                                var it = std.mem.splitScalar(u8, arg_buf.items, ',');
                                while (it.next()) |raw_arg| {
                                    const arg_s = std.mem.trim(u8, raw_arg, " \t");
                                    if (arg_s.len == 0) continue;
                                    var ep = ExprParser.init(self.alloc, arg_s);
                                    if (try ep.parseExpr()) |e| {
                                        try arg_list.append(self.alloc, e);
                                    } else if (std.mem.startsWith(u8, arg_s, "->")) {
                                        const divert_target = std.mem.trim(u8, arg_s[2..], " \t");
                                        const node = try self.alloc.create(Parsed.Expression);
                                        node.* = .{ .divert_target = divert_target };
                                        try arg_list.append(self.alloc, node);
                                    }
                                }
                                args = try arg_list.toOwnedSlice(self.alloc);
                            }
                        }
                        return .{ .target = target, .is_tunnel = false, .is_thread = false, .is_tunnel_onwards = true, .args = args };
                    }
                }
                return .{ .target = "->->", .is_tunnel = false, .is_thread = false, .args = &.{} };
            },
            .divert_arrow => {
                _ = self.eat();
                // Target name is in the next text token.
                var target: []const u8 = "";
                var args: []*Parsed.Expression = &.{};
                if (self.cur().tag == .text) {
                    const raw = self.eat().loc.slice(self.src);
                    const t = trimLeft(raw);
                    const name_end = identEnd(t);
                    target = t[0..name_end];
                    // Check for args: "(arg1, ...)" possibly spanning multiple tokens.
                    const after_name = trimLeft(t[name_end..]);
                    if (after_name.len > 0 and after_name[0] == '(') {
                        // Collect the args text across multiple tokens until ')'.
                        // Start with whatever is after '(' in the current token.
                        var arg_buf = std.ArrayList(u8).empty;
                        var close_found = false;
                        const initial = after_name[1..]; // after '('
                        if (std.mem.indexOfScalar(u8, initial, ')')) |end| {
                            try arg_buf.appendSlice(self.alloc, initial[0..end]);
                            close_found = true;
                        } else {
                            try arg_buf.appendSlice(self.alloc, initial);
                            // Collect more tokens until ')'.
                            while (!close_found) {
                                switch (self.cur().tag) {
                                    .newline, .eof => break,
                                    .divert_arrow => {
                                        _ = self.eat();
                                        try arg_buf.appendSlice(self.alloc, "->");
                                    },
                                    .text => {
                                        const more = self.eat().loc.slice(self.src);
                                        if (std.mem.indexOfScalar(u8, more, ')')) |end| {
                                            try arg_buf.appendSlice(self.alloc, more[0..end]);
                                            close_found = true;
                                        } else {
                                            try arg_buf.appendSlice(self.alloc, more);
                                        }
                                    },
                                    else => _ = self.eat(),
                                }
                            }
                        }
                        if (close_found) {
                            var arg_list = std.ArrayList(*Parsed.Expression).empty;
                            var it = std.mem.splitScalar(u8, arg_buf.items, ',');
                            while (it.next()) |raw_arg| {
                                const arg_s = std.mem.trim(u8, raw_arg, " \t");
                                if (arg_s.len == 0) continue;
                                var ep = ExprParser.init(self.alloc, arg_s);
                                if (try ep.parseExpr()) |e| {
                                    try arg_list.append(self.alloc, e);
                                } else if (std.mem.startsWith(u8, arg_s, "->")) {
                                    const divert_target = std.mem.trim(u8, arg_s[2..], " \t");
                                    const node = try self.alloc.create(Parsed.Expression);
                                    node.* = .{ .divert_target = divert_target };
                                    try arg_list.append(self.alloc, node);
                                }
                            }
                            args = try arg_list.toOwnedSlice(self.alloc);
                        }
                    }
                } else if (self.cur().tag == .divert_arrow) {
                    // -> -> means tunnel return
                    _ = self.eat();
                    return .{ .target = "->->", .is_tunnel = false, .is_thread = false, .args = &.{} };
                }
                // Trailing -> means tunnel call (e.g. "-> knot ->").
                // Trailing ->-> means tunnel-onwards (e.g. "-> knot ->->").
                var is_tunnel = self.cur().tag == .divert_arrow;
                var is_tunnel_onwards = false;
                var onward_target: ?[]const u8 = null;
                var onward_is_tunnel = false;
                var onward_args: []*Parsed.Expression = &.{};
                if (is_tunnel) {
                    _ = self.eat();
                    if (self.cur().tag == .text) {
                        const raw = self.eat().loc.slice(self.src);
                        const t = trimLeft(raw);
                        const onward_end = identEnd(t);
                        if (onward_end > 0) {
                            onward_target = t[0..onward_end];
                            const after_onward = trimLeft(t[onward_end..]);
                            if (after_onward.len > 0 and after_onward[0] == '(') {
                                var arg_buf = std.ArrayList(u8).empty;
                                var close_found = false;
                                const initial = after_onward[1..];
                                if (std.mem.indexOfScalar(u8, initial, ')')) |end| {
                                    try arg_buf.appendSlice(self.alloc, initial[0..end]);
                                    close_found = true;
                                } else {
                                    try arg_buf.appendSlice(self.alloc, initial);
                                    while (!close_found) {
                                        switch (self.cur().tag) {
                                            .newline, .eof => break,
                                            .divert_arrow => {
                                                _ = self.eat();
                                                try arg_buf.appendSlice(self.alloc, "->");
                                            },
                                            .text => {
                                                const more = self.eat().loc.slice(self.src);
                                                if (std.mem.indexOfScalar(u8, more, ')')) |end| {
                                                    try arg_buf.appendSlice(self.alloc, more[0..end]);
                                                    close_found = true;
                                                } else {
                                                    try arg_buf.appendSlice(self.alloc, more);
                                                }
                                            },
                                            else => _ = self.eat(),
                                        }
                                    }
                                }
                                if (close_found) {
                                    var arg_list = std.ArrayList(*Parsed.Expression).empty;
                                    var it = std.mem.splitScalar(u8, arg_buf.items, ',');
                                    while (it.next()) |raw_arg| {
                                        const arg_s = std.mem.trim(u8, raw_arg, " \t");
                                        if (arg_s.len == 0) continue;
                                        var ep = ExprParser.init(self.alloc, arg_s);
                                        if (try ep.parseExpr()) |e| {
                                            try arg_list.append(self.alloc, e);
                                        } else if (std.mem.startsWith(u8, arg_s, "->")) {
                                            const divert_target = std.mem.trim(u8, arg_s[2..], " \t");
                                            const node = try self.alloc.create(Parsed.Expression);
                                            node.* = .{ .divert_target = divert_target };
                                            try arg_list.append(self.alloc, node);
                                        }
                                    }
                                    onward_args = try arg_list.toOwnedSlice(self.alloc);
                                }
                            }
                            if (self.cur().tag == .divert_arrow) {
                                _ = self.eat();
                                is_tunnel_onwards = true;
                                onward_is_tunnel = true;
                            }
                        }
                    }
                } else if (self.cur().tag == .divert_return) {
                    // -> target ->->  (tunnel onwards: tunnel then immediately return)
                    is_tunnel = true;
                    is_tunnel_onwards = true;
                    _ = self.eat();
                }
                return .{
                    .target = target,
                    .is_tunnel = is_tunnel,
                    .is_thread = false,
                    .is_tunnel_onwards = is_tunnel_onwards,
                    .onward_target = onward_target,
                    .onward_is_tunnel = onward_is_tunnel,
                    .onward_args = onward_args,
                    .args = args,
                };
            },
            else => return null,
        }
    }

    // -- Declarations ---------------------------------------------------------

    fn parseVarLine(self: *Parser) error{OutOfMemory}!?Parsed.VarDecl {
        const tok = self.eat(); // "VAR name = value ..." (stops before ->)
        const line_text = tok.loc.slice(self.src);
        const tok_line = tok.line;

        var rest = trimLeft(line_text[3..]); // skip "VAR"

        const name_end = identEnd(rest);
        if (name_end == 0) {
            self.skipToEol();
            try self.addError(.malformed_var_decl, tok_line);
            return null;
        }
        const name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') {
            self.skipToEol();
            try self.addError(.malformed_var_decl, tok_line);
            return null;
        }
        rest = trimLeft(rest[1..]);

        // Check if after `=` we have a divert_arrow token (VAR x = -> knot).
        if (rest.len == 0) {
            // The `=` used up the text token; look ahead for -> target.
            if (self.cur().tag == .divert_arrow) {
                _ = self.eat(); // ->
                const target = if (self.cur().tag == .text)
                    extractFirstIdentifier(self.eat().loc.slice(self.src))
                else
                    "";
                self.skipToEol();
                const e = try self.alloc.create(Parsed.Expression);
                e.* = .{ .divert_target = target };
                return .{ .name = name, .initial = e };
            }
        }

        self.skipToEol(); // consume any trailing tokens
        var ep = ExprParser.init(self.alloc, rest);
        const expr = (try ep.parseExpr()) orelse return null;
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

        var ep = ExprParser.init(self.alloc, rest);
        const expr = (try ep.parseExpr()) orelse return null;
        return .{ .name = name, .value = expr };
    }

    fn parseListLine(self: *Parser) error{OutOfMemory}!?Parsed.ListDef {
        const tok = self.eat(); // "LIST name = a, (b), c"
        const line_text = tok.loc.slice(self.src);
        self.skipToEol();

        var rest = trimLeft(line_text[4..]); // skip "LIST"

        const name_end = identEnd(rest);
        if (name_end == 0) return null;
        const list_name = rest[0..name_end];
        rest = trimLeft(rest[name_end..]);

        if (rest.len == 0 or rest[0] != '=') return null;
        rest = trimLeft(rest[1..]);

        var items = std.ArrayList(Parsed.ListItem).empty;
        var auto_val: i32 = 1;
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |raw_item| {
            const item_str = std.mem.trim(u8, raw_item, " \t");
            if (item_str.len == 0) continue;
            // Check for selected value: "(name)" means value is pre-selected (starts at 1+).
            // Also handle "name = value" explicit numbering.
            var item_name = item_str;
            var item_val: ?i32 = null;
            var is_selected = false;
            // Strip parens: (name) means the item is "on" by default.
            if (item_str.len >= 2 and item_str[0] == '(' and item_str[item_str.len - 1] == ')') {
                item_name = item_str[1 .. item_str.len - 1];
                is_selected = true;
            }
            // Check for explicit value: "name = N"
            if (std.mem.indexOf(u8, item_name, "=")) |eq_idx| {
                const val_str = std.mem.trim(u8, item_name[eq_idx + 1 ..], " \t");
                item_name = std.mem.trim(u8, item_name[0..eq_idx], " \t");
                item_val = std.fmt.parseInt(i32, val_str, 10) catch null;
                if (item_val) |v| auto_val = v + 1;
            } else {
                item_val = auto_val;
                auto_val += 1;
            }
            const clean_name = std.mem.trim(u8, item_name, " \t");
            if (clean_name.len > 0)
                try items.append(self.alloc, .{ .name = clean_name, .value = item_val, .is_selected = is_selected });
        }
        return Parsed.ListDef{
            .name = list_name,
            .items = try items.toOwnedSlice(self.alloc),
        };
    }

    fn parseIncludeLine(self: *Parser) ?[]const u8 {
        const line_text = self.eat().loc.slice(self.src); // "INCLUDE path"
        self.skipToEol();

        const rest = std.mem.trim(u8, line_text[7..], " \t"); // skip "INCLUDE"
        if (rest.len == 0) return null;
        return rest;
    }

    /// Parse `EXTERNAL name(param, param, ...)` → ExternalFn.
    /// The param count is what matters at runtime (not names).
    fn parseExternalLine(self: *Parser) ?Parsed.ExternalFn {
        const line_text = self.eat().loc.slice(self.src); // "EXTERNAL name(params)"
        self.skipToEol();

        const rest = std.mem.trim(u8, line_text[8..], " \t"); // skip "EXTERNAL"
        // Find opening paren — everything before it is the function name.
        const paren_pos = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
        const name = std.mem.trim(u8, rest[0..paren_pos], " \t");
        if (name.len == 0) return null;
        // Count commas in the param list to determine arity.
        const close_pos = std.mem.indexOfScalar(u8, rest[paren_pos..], ')') orelse return null;
        const params_str = std.mem.trim(u8, rest[paren_pos + 1 .. paren_pos + close_pos], " \t");
        const param_count: u32 = if (params_str.len == 0)
            0
        else
            @intCast(std.mem.count(u8, params_str, ",") + 1);
        return .{ .name = name, .param_count = param_count };
    }

    // -- Logic lines ----------------------------------------------------------

    /// Parse a `~` logic line into a FlowItem.logic.
    /// Handles: `~ temp x = expr`, `~ x = expr`, `~ return [expr]`.
    /// Returns null (and skips the line) for unsupported or malformed forms.
    fn parseLogicLine(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        _ = self.eat(); // logic_line (~)
        const line_source = self.collectLineSource() catch return error.OutOfMemory;
        if (line_source.len == 0) {
            self.skipToEol();
            return null;
        }
        self.skipToEol();
        const text = std.mem.trim(u8, line_source, " \t");

        // ~ return [expr]
        if (startsWithKeyword(text, "return")) {
            const after = trimLeft(text[6..]);
            if (after.len == 0) {
                return .{ .logic = .{ .return_stmt = null } };
            }
            var ep = ExprParser.init(self.alloc, after);
            const expr = try ep.parseExpr();
            return .{ .logic = .{ .return_stmt = expr } };
        }

        // ~ temp name = expr
        if (startsWithKeyword(text, "temp")) {
            var rest = trimLeft(text[4..]);
            const name_end = identEnd(rest);
            if (name_end == 0) return null;
            const name = rest[0..name_end];
            rest = trimLeft(rest[name_end..]);
            if (rest.len == 0 or rest[0] != '=') return null;
            rest = trimLeft(rest[1..]);
            var ep = ExprParser.init(self.alloc, rest);
            const expr = (try ep.parseExpr()) orelse return null;
            try self.temp_names.append(self.alloc, name);
            return .{ .logic = .{ .temp_decl = .{ .name = name, .initial = expr } } };
        }

        // ~ name = expr  (assignment — not `==`)
        const name_end = identEnd(text);
        if (name_end == 0) return null;
        const name = text[0..name_end];
        var rest = trimLeft(text[name_end..]);

        // ~ name++  →  name = name + 1  (compound)
        if (std.mem.startsWith(u8, rest, "++")) {
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const one = try self.alloc.create(Parsed.Expression);
            one.* = .{ .int_lit = 1 };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .add, .lhs = lhs, .rhs = one } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp, .is_compound = true } } };
        }
        // ~ name--  →  name = name - 1  (compound)
        if (std.mem.startsWith(u8, rest, "--")) {
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const one = try self.alloc.create(Parsed.Expression);
            one.* = .{ .int_lit = 1 };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .sub, .lhs = lhs, .rhs = one } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp, .is_compound = true } } };
        }
        // ~ name += expr  →  name = name + expr
        if (std.mem.startsWith(u8, rest, "+=")) {
            const operand_str = trimLeft(rest[2..]);
            var ep = ExprParser.init(self.alloc, operand_str);
            const operand = (try ep.parseExpr()) orelse return null;
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .add, .lhs = lhs, .rhs = operand } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp, .is_compound = true } } };
        }
        // ~ name -= expr  →  name = name - expr
        if (std.mem.startsWith(u8, rest, "-=")) {
            const operand_str = trimLeft(rest[2..]);
            var ep = ExprParser.init(self.alloc, operand_str);
            const operand = (try ep.parseExpr()) orelse return null;
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .sub, .lhs = lhs, .rhs = operand } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp, .is_compound = true } } };
        }

        if (rest.len > 0 and rest[0] == '(') {
            // ~ func(args) — standalone function call (expr_stmt)
            var ep = ExprParser.init(self.alloc, text);
            const expr = (try ep.parseExpr()) orelse return null;
            return .{ .logic = .{ .expr_stmt = expr } };
        }

        if (rest.len == 0 or rest[0] != '=') return null;
        if (rest.len > 1 and rest[1] == '=') return null; // equality, not assignment
        rest = trimLeft(rest[1..]);
        var ep = ExprParser.init(self.alloc, rest);
        const expr = (try ep.parseExpr()) orelse return null;
        const is_temp = self.isTempVar(name);
        return .{ .logic = .{ .assignment = .{ .name = name, .value = expr, .is_temp = is_temp } } };
    }

    fn isTempVar(self: *const Parser, name: []const u8) bool {
        for (self.temp_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    // -- Brace expression -----------------------------------------------------

    /// Try to parse `{expr}` as a single Expression.
    /// Returns the expression on success (having consumed `{`, text, `}`).
    /// Returns null if the content is not a simple expression (conditional,
    /// sequence, divert-target, etc.); the parser position is fully restored
    /// so the caller can use `skipBraceBlock` instead.
    fn parseBraceExpr(self: *Parser) error{OutOfMemory}!?*Parsed.Expression {
        if (self.cur().tag != .left_brace) return null;
        const saved = self.save();
        _ = self.eat(); // {
        var depth: u32 = 1;
        var buf = std.ArrayList(u8).empty;
        while (depth > 0) {
            switch (self.cur().tag) {
                .eof => {
                    self.restore(saved);
                    return null;
                },
                .left_brace => {
                    depth += 1;
                    const tok = self.eat();
                    try buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                },
                .right_brace => {
                    depth -= 1;
                    if (depth == 0) {
                        _ = self.eat();
                        break;
                    }
                    const tok = self.eat();
                    try buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                },
                else => {
                    const tok = self.eat();
                    try buf.appendSlice(self.alloc, tok.loc.slice(self.src));
                },
            }
        }
        var ep = ExprParser.init(self.alloc, buf.items);
        if (try ep.parseExpr()) |expr| {
            ep.skipWs();
            if (ep.pos == ep.src.len) return expr;
        }
        self.restore(saved);
        return null;
    }

    // -- Conditionals ---------------------------------------------------------
    //
    // NOTE on tokenizer behaviour: the `:` character is a structural delimiter
    // only when the tokenizer is in its `.start` state (i.e., when it is the
    // FIRST character of a new token).  When `:` appears in the middle of a
    // run of text it is consumed by `scanText` and bundled into the text token.
    // Consequently patterns like `{false:not true|true}` tokenise as:
    //   left_brace, text("false:not true"), pipe, text("true"), right_brace
    // and `{- 4 > 5: not true\n}` tokenises as:
    //   left_brace, newline, gather, text("4 > 5: not true"), newline, right_brace
    //
    // All conditional parsing therefore splits text tokens at the first `:`.

    // ── Sequence (alternative) parsing ───────────────────────────────────────

    /// Try to parse `{keyword:\n - branch\n ...}` as a block Sequence.
    /// Returns null (restoring position) if this is not a block sequence.
    fn parseBraceSequenceBlock(self: *Parser) error{OutOfMemory}!?Parsed.Sequence {
        if (self.cur().tag != .left_brace) return null;
        const saved = self.save();
        _ = self.eat(); // {
        if (self.cur().tag != .text) { self.restore(saved); return null; }
        const tok_text = self.eat().loc.slice(self.src);
        const trimmed = std.mem.trim(u8, tok_text, " \t");
        // Detect keyword (text ends with ':' and keyword before ':' is a sequence keyword).
        const kind: Parsed.SequenceKind = blk: {
            if (sequenceKeywordKind(trimmed)) |k| break :blk k;
            self.restore(saved);
            return null;
        };
        // Must be followed by newline (block form only).
        if (self.cur().tag != .newline) { self.restore(saved); return null; }
        _ = self.eat(); // newline after keyword line
        self.skipNewlines();
        // Parse gather-delimited branches.
        var branches = std.ArrayList([]Parsed.FlowItem).empty;
        while (self.cur().tag == .gather) {
            _ = self.eat(); // -
            const content = try self.parseBranchContent();
            try branches.append(self.alloc, content);
        }
        self.skipNewlines();
        if (self.cur().tag != .right_brace) { self.restore(saved); return null; }
        _ = self.eat(); // }
        if (self.cur().tag == .newline) _ = self.eat();
        return Parsed.Sequence{
            .kind = kind,
            .is_inline = false,
            .branches = try branches.toOwnedSlice(self.alloc),
        };
    }

    /// Returns the SequenceKind if `text` is a sequence keyword like "stopping:".
    /// The text must end with ':'.
    fn sequenceKeywordKind(text: []const u8) ?Parsed.SequenceKind {
        // Strip trailing whitespace and colon to get the keyword
        var end = text.len;
        while (end > 0 and (text[end - 1] == ':' or text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
        const kw = text[0..end];
        if (std.mem.eql(u8, kw, "stopping")) return .stopping;
        if (std.mem.eql(u8, kw, "once")) return .once_only;
        if (std.mem.eql(u8, kw, "cycle")) return .cycle;
        if (std.mem.eql(u8, kw, "shuffle")) return .shuffle;
        // Combined forms: treat as shuffle (simplified)
        if (std.mem.eql(u8, kw, "shuffle stopping") or
            std.mem.eql(u8, kw, "stopping shuffle") or
            std.mem.eql(u8, kw, "shuffle once") or
            std.mem.eql(u8, kw, "once shuffle")) return .shuffle;
        return null;
    }

    /// Try to parse `{a|b}`, `{&a|b}`, `{!a|b}`, `{~a|b}` as an inline Sequence.
    /// Returns null (restoring position) if not an inline sequence.
    fn parseBraceSequenceInline(self: *Parser) error{OutOfMemory}!?Parsed.Sequence {
        if (self.cur().tag != .left_brace) return null;
        const saved = self.save();
        _ = self.eat(); // {

        var kind = Parsed.SequenceKind.stopping;
        var prefix_stripped: ?[]const u8 = null; // first branch text after stripping kind prefix

        if (self.cur().tag == .pipe) {
            // {|...} → stopping, empty first branch
            kind = .stopping;
            prefix_stripped = ""; // empty first branch
        } else if (self.cur().tag == .text) {
            const tok = self.cur().loc.slice(self.src);
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len > 0 and t[0] == '&') {
                kind = .cycle;
                _ = self.eat();
                var skip: usize = 1;
                while (skip < t.len and (t[skip] == ' ' or t[skip] == '\t')) skip += 1;
                prefix_stripped = t[skip..];
            } else if (t.len > 0 and t[0] == '!') {
                kind = .once_only;
                _ = self.eat();
                var skip: usize = 1;
                while (skip < t.len and (t[skip] == ' ' or t[skip] == '\t')) skip += 1;
                prefix_stripped = t[skip..];
            } else if (t.len > 0 and t[0] == '~') {
                kind = .shuffle;
                _ = self.eat();
                var skip: usize = 1;
                while (skip < t.len and (t[skip] == ' ' or t[skip] == '\t')) skip += 1;
                prefix_stripped = t[skip..];
            } else if (std.mem.indexOfScalar(u8, t, ':') != null) {
                // Has colon → not an inline sequence (could be conditional or block seq)
                self.restore(saved);
                return null;
            } else {
                // Check if followed by pipe → stopping inline sequence
                // Peek: don't eat the text token yet (we'll parse it as first branch)
                const peek_saved = self.save();
                _ = self.eat(); // eat text token
                const next_is_pipe = self.cur().tag == .pipe;
                self.restore(peek_saved);
                if (!next_is_pipe) {
                    self.restore(saved);
                    return null;
                }
                // Stopping sequence — first branch starts with this text token
                kind = .stopping;
                // Don't pre-strip; let first branch parsing handle it
            }
        } else if (self.cur().tag == .thread_start) {
            // {<- knot | ...} → stopping sequence with thread first branch
            kind = .stopping;
        } else if (self.cur().tag == .divert_arrow or self.cur().tag == .divert_return) {
            // { -> target | ... } → stopping sequence with divert first branch.
            // Only treat as sequence if there's a | separator ahead.
            // Peek: consume -> and target text, check for |.
            const peek_saved = self.save();
            _ = self.eat(); // ->
            if (self.cur().tag == .text) _ = self.eat(); // target name
            const next_is_pipe = self.cur().tag == .pipe;
            self.restore(peek_saved);
            if (!next_is_pipe) {
                self.restore(saved);
                return null;
            }
            kind = .stopping;
        } else {
            self.restore(saved);
            return null;
        }

        // Parse branches
        var branches = std.ArrayList([]Parsed.FlowItem).empty;

        // First branch (might have prefix_stripped content)
        if (prefix_stripped) |ps| {
            // Build first branch from prefix text + remaining inline elements
            var elems = std.ArrayList(Parsed.InlineElement).empty;
            if (ps.len > 0) try elems.append(self.alloc, .{ .text = ps });
            const more = try self.parseInlineBranchElems();
            for (more) |e| try elems.append(self.alloc, e);
            const branch = try self.inlineElemsToFlowItems(try elems.toOwnedSlice(self.alloc));
            try branches.append(self.alloc, branch);
        } else {
            // No prefix stripping — parse first branch normally
            const branch = try self.parseInlineSequenceBranch();
            try branches.append(self.alloc, branch);
        }

        // Remaining branches separated by |
        while (self.cur().tag == .pipe) {
            _ = self.eat(); // |
            const branch = try self.parseInlineSequenceBranch();
            try branches.append(self.alloc, branch);
        }

        self.skipNewlines();
        if (self.cur().tag != .right_brace) { self.restore(saved); return null; }
        _ = self.eat(); // }
        return Parsed.Sequence{
            .kind = kind,
            .is_inline = true,
            .branches = try branches.toOwnedSlice(self.alloc),
        };
    }

    /// Wrap a list of InlineElement into a single-item []FlowItem (a TextLine).
    fn inlineElemsToFlowItems(self: *Parser, elems: []Parsed.InlineElement) ![]Parsed.FlowItem {
        const text_item = Parsed.FlowItem{ .text = .{ .elements = elems } };
        const items = try self.alloc.dupe(Parsed.FlowItem, &.{text_item});
        return items;
    }

    /// Try to parse `{...}` as a Parsed.Conditional.
    /// Returns null (restoring position) if the brace block is not a conditional.
    fn parseBraceConditional(self: *Parser) error{OutOfMemory}!?Parsed.Conditional {
        if (self.cur().tag != .left_brace) return null;
        const saved = self.save();
        _ = self.eat(); // {
        self.skipNewlines();

        // CASE A: multi-branch block { \n - branches }  (no outer condition)
        if (self.cur().tag == .gather) {
            const branches = try self.parseGatherBranches();
            self.skipNewlines();
            if (self.cur().tag == .right_brace) {
                _ = self.eat(); // }
                if (self.cur().tag == .newline) _ = self.eat();
                return Parsed.Conditional{
                    .outer_condition = null,
                    .is_inline = false,
                    .branches = branches,
                };
            }
            self.restore(saved);
            return null;
        }

        // CASE B & C: starts with a text token (outer condition or inline).
        if (self.cur().tag != .text and self.cur().tag != .pipe) {
            self.restore(saved);
            return null;
        }
        const header = (try self.collectBraceHeaderUntilColon()) orelse {
            self.restore(saved);
            return null;
        };
        const expr_text = header.expr_text;
        const after_colon = header.after_colon;

        // Parse the outer condition expression.
        var ep = ExprParser.init(self.alloc, expr_text);
        const outer_cond = (try ep.parseExpr()) orelse {
            self.restore(saved);
            return null;
        };

        // Determine form by what comes after the colon.
        if (after_colon.len == 0 and self.cur().tag == .newline) {
            // CASE B: block outer-condition form { cond:\n ... }
            _ = self.eat(); // newline
            self.skipNewlines();

            if (self.cur().tag == .gather) {
                // { cond:\n - branch\n ... }
                const branches = try self.parseGatherBranches();
                self.skipNewlines();
                if (self.cur().tag != .right_brace) {
                    self.restore(saved);
                    return null;
                }
                _ = self.eat(); // }
                if (self.cur().tag == .newline) _ = self.eat();
                // Detect switch: outer_cond + any branch has its own condition.
                var is_switch = false;
                for (branches) |b| {
                    if (b.condition != null) { is_switch = true; break; }
                }
                return Parsed.Conditional{
                    .outer_condition = outer_cond,
                    .is_switch = is_switch,
                    .is_inline = false,
                    .branches = branches,
                };
            }

            // { cond:\n content lines\n [- else: ...] }
            const content = try self.parseBranchContent();
            var branch_list = std.ArrayList(Parsed.Branch).empty;
            try branch_list.append(self.alloc, .{ .condition = null, .content = content });
            if (self.cur().tag == .gather) {
                if (try self.parseElseGatherBranch()) |b|
                    try branch_list.append(self.alloc, b);
            }
            self.skipNewlines();
            if (self.cur().tag != .right_brace) {
                self.restore(saved);
                return null;
            }
            _ = self.eat(); // }
            if (self.cur().tag == .newline) _ = self.eat();
            return Parsed.Conditional{
                .outer_condition = outer_cond,
                .is_switch = false,
                .is_inline = false,
                .branches = try branch_list.toOwnedSlice(self.alloc),
            };
        }

        // CASE C: inline form { cond: true_text | false_text }
        // after_colon holds the true-branch text from the same token.
        var branch_list = std.ArrayList(Parsed.Branch).empty;
        {
            var true_elems = std.ArrayList(Parsed.InlineElement).empty;
            if (after_colon.len > 0)
                try true_elems.append(self.alloc, .{ .text = after_colon });
            // Handle \| escape at the boundary: if after_colon ends with \ and next is |,
            // treat that pipe as a literal character.
            while (true_elems.items.len > 0 and
                true_elems.items[true_elems.items.len - 1] == .text and
                blk: {
                    const t = true_elems.items[true_elems.items.len - 1].text;
                    break :blk t.len > 0 and t[t.len - 1] == '\\';
                } and self.cur().tag == .pipe)
            {
                _ = self.eat(); // consume escaped |
                const prev = true_elems.items[true_elems.items.len - 1].text;
                var buf = std.ArrayList(u8).empty;
                try buf.appendSlice(self.alloc, prev[0 .. prev.len - 1]);
                try buf.append(self.alloc, '|');
                // Consume any following text token.
                if (self.cur().tag == .text) {
                    const t2 = self.eat();
                    try buf.appendSlice(self.alloc, std.mem.trim(u8, t2.loc.slice(self.src), " \t"));
                }
                true_elems.items[true_elems.items.len - 1] = .{ .text = try buf.toOwnedSlice(self.alloc) };
            }
            // Collect any additional text tokens before `|` or `}`.
            const more = try self.parseInlineBranchElems();
            for (more) |e| try true_elems.append(self.alloc, e);
            try branch_list.append(self.alloc, .{
                .condition = null,
                .content = &.{},
                .inline_elems = try true_elems.toOwnedSlice(self.alloc),
            });
        }
        if (self.cur().tag == .pipe) {
            _ = self.eat(); // |
            const false_elems = try self.parseInlineBranchElems();
            try branch_list.append(self.alloc, .{
                .condition = null,
                .content = &.{},
                .inline_elems = false_elems,
            });
        }
        // Skip any trailing newlines before `}`.
        self.skipNewlines();
        if (self.cur().tag != .right_brace) {
            self.restore(saved);
            return null;
        }
        _ = self.eat(); // }
        if (self.cur().tag == .newline) _ = self.eat();
        return Parsed.Conditional{
            .outer_condition = outer_cond,
            .is_switch = false,
            .is_inline = true,
            .branches = try branch_list.toOwnedSlice(self.alloc),
        };
    }

    /// Parse inline elements (text/etc.) until `|`, `}`, newline, or eof.
    /// Parse a single branch of an inline sequence.
    /// Handles thread_start (<- knot) as a FlowItem.thread_start.
    /// Normal inline text/exprs are wrapped as a single FlowItem.text.
    fn parseInlineSequenceBranch(self: *Parser) error{OutOfMemory}![]Parsed.FlowItem {
        // Check for thread_start at the beginning of the branch.
        if (self.cur().tag == .thread_start) {
            _ = self.eat(); // <-
            const target = if (self.cur().tag == .text) blk: {
                const t = self.eat();
                break :blk std.mem.trim(u8, t.loc.slice(self.src), " \t");
            } else "";
            // Eat any remaining content before | or }
            while (self.cur().tag != .pipe and self.cur().tag != .right_brace and
                self.cur().tag != .newline and self.cur().tag != .eof)
            {
                _ = self.eat();
            }
            if (target.len > 0) {
                return self.alloc.dupe(Parsed.FlowItem, &.{.{ .thread_start = target }});
            }
            return &.{};
        }
        // Normal inline branch: parse inline elements.
        const elems = try self.parseInlineBranchElems();
        return self.inlineElemsToFlowItems(elems);
    }

    fn parseInlineBranchElems(self: *Parser) error{OutOfMemory}![]Parsed.InlineElement {
        var elems = std.ArrayList(Parsed.InlineElement).empty;
        while (true) {
            switch (self.cur().tag) {
                .right_brace, .newline, .eof => break,
                .pipe => {
                    // Check for \| escape: if the last elem is .text ending with \,
                    // treat this pipe as a literal '|' character.
                    if (elems.items.len > 0 and elems.items[elems.items.len - 1] == .text) {
                        const prev = elems.items[elems.items.len - 1].text;
                        if (prev.len > 0 and prev[prev.len - 1] == '\\') {
                            _ = self.eat(); // consume the |
                            // Replace trailing \ with |.
                            var buf = std.ArrayList(u8).empty;
                            try buf.appendSlice(self.alloc, prev[0 .. prev.len - 1]);
                            try buf.append(self.alloc, '|');
                            elems.items[elems.items.len - 1] = .{ .text = try buf.toOwnedSlice(self.alloc) };
                            continue;
                        }
                    }
                    break;
                },
                .text => {
                    const t = self.eat();
                    const s = std.mem.trim(u8, t.loc.slice(self.src), " \t");
                    if (s.len > 0) try elems.append(self.alloc, .{ .text = s });
                },
                .divert_arrow, .divert_return => {
                    if (try self.parseDivertInline()) |d|
                        try elems.append(self.alloc, .{ .divert = d });
                },
                .left_brace => {
                    if (try self.parseBraceSequenceInline()) |seq| {
                        try elems.append(self.alloc, .{ .sequence = seq });
                    } else if (try self.parseBraceExpr()) |expr| {
                        try elems.append(self.alloc, .{ .inline_expr = expr });
                    } else {
                        self.skipBraceBlock();
                    }
                },
                else => _ = self.eat(),
            }
        }
        return elems.toOwnedSlice(self.alloc);
    }

    /// Parse gather-based branches: one or more `- [cond:] content` blocks.
    /// The colon separator (if any) is embedded inside the text token after `-`.
    fn parseGatherBranches(self: *Parser) error{OutOfMemory}![]Parsed.Branch {
        var branches = std.ArrayList(Parsed.Branch).empty;
        while (self.cur().tag == .gather) {
            _ = self.eat(); // -

            if (self.cur().tag == .text) {
                const text_tok = self.eat();
                const text_raw = text_tok.loc.slice(self.src);
                const text_val = std.mem.trim(u8, text_raw, " \t");

                if (std.mem.indexOfScalar(u8, text_val, ':')) |cp| {
                    const before = std.mem.trim(u8, text_val[0..cp], " \t");
                    const after_head = std.mem.trim(u8, text_val[cp + 1 ..], " \t");
                    const after_tail = try self.collectLineRemainder();
                    const after = if (after_head.len == 0)
                        after_tail
                    else if (after_tail.len == 0)
                        after_head
                    else
                        try std.fmt.allocPrint(self.alloc, "{s} {s}", .{ after_head, after_tail });

                    if (isElseKeyword(before)) {
                        // - else: content  (else/fallthrough branch)
                        const branch_content = try self.parseGatherBranchBody(after);
                        try branches.append(self.alloc, .{ .condition = null, .is_else = true, .content = branch_content });
                    } else {
                        // - expr: content  (condition branch for switch or multi-branch)
                        var ep2 = ExprParser.init(self.alloc, before);
                        const cond_expr = try ep2.parseExpr();
                        const branch_content = try self.parseGatherBranchBody(after);
                        try branches.append(self.alloc, .{ .condition = cond_expr, .content = branch_content });
                    }
                } else {
                    // - content  (no colon → no-condition content branch)
                    const tail = try self.collectLineRemainder();
                    const same_line = if (tail.len == 0)
                        text_val
                    else
                        try std.fmt.allocPrint(self.alloc, "{s} {s}", .{ text_val, tail });
                    const branch_content = try self.parseGatherBranchBody(same_line);
                    try branches.append(self.alloc, .{ .condition = null, .content = branch_content });
                }
            } else {
                // No text token at all after `-` (empty branch or starts with `{`).
                if (self.cur().tag == .newline) _ = self.eat();
                const content = try self.parseBranchContent();
                try branches.append(self.alloc, .{ .condition = null, .content = content });
            }
            self.skipNewlines();
        }
        return branches.toOwnedSlice(self.alloc);
    }

    /// Build the FlowItem list for a gather branch body.
    /// `same_line_text` is the text from the SAME line as the `-` (after `:` if any).
    /// Additional lines are parsed via parseBranchContent.
    fn parseGatherBranchBody(self: *Parser, same_line_text: []const u8) error{OutOfMemory}![]Parsed.FlowItem {
        var items = std.ArrayList(Parsed.FlowItem).empty;
        if (same_line_text.len > 0) {
            const inline_items = try self.parseStandaloneFlowItems(same_line_text);
            for (inline_items) |item| try items.append(self.alloc, item);
        }
        if (self.cur().tag == .newline) _ = self.eat();
        const more = try self.parseBranchContent();
        for (more) |item| try items.append(self.alloc, item);
        return items.toOwnedSlice(self.alloc);
    }

    fn parseStandaloneFlowItems(self: *Parser, text: []const u8) error{OutOfMemory}![]Parsed.FlowItem {
        const owned = try self.alloc.dupeZ(u8, text);
        var tokens = std.ArrayList(Token).empty;
        var t = Tokenizer.init(owned);
        while (true) {
            const tk = t.next();
            try tokens.append(self.alloc, tk);
            if (tk.tag == .eof) break;
        }

        var sub = Parser.init(self.alloc, owned, try tokens.toOwnedSlice(self.alloc));
        var items = std.ArrayList(Parsed.FlowItem).empty;
        while (true) {
            switch (sub.cur().tag) {
                .eof => break,
                .newline => _ = sub.eat(),
                .text => {
                    if (try sub.parseTextLine()) |item|
                        try items.append(self.alloc, item);
                },
                .divert_arrow, .divert_return => {
                    if (try sub.parseDivertLine()) |item|
                        try items.append(self.alloc, item);
                },
                .logic_line => {
                    if (try sub.parseLogicLine()) |item|
                        try items.append(self.alloc, item);
                },
                .choice_once, .choice_sticky => {
                    if (try sub.parseChoiceItem()) |item|
                        try items.append(self.alloc, item);
                },
                .gather => {
                    if (try sub.parseGatherItem()) |item|
                        try items.append(self.alloc, item);
                },
                .left_brace => {
                    if (try sub.parseBraceSequenceBlock()) |seq| {
                        try items.append(self.alloc, .{ .sequence = seq });
                    } else if (try sub.parseBraceConditional()) |cond| {
                        try items.append(self.alloc, .{ .conditional = cond });
                    } else if (try sub.parseTextLine()) |item| {
                        try items.append(self.alloc, item);
                    } else {
                        sub.skipBraceBlock();
                    }
                },
                else => _ = sub.eat(),
            }
        }
        return items.toOwnedSlice(self.alloc);
    }

    /// Parse a `- else: content` block that follows direct content lines.
    fn parseElseGatherBranch(self: *Parser) error{OutOfMemory}!?Parsed.Branch {
        if (self.cur().tag != .gather) return null;
        _ = self.eat(); // -
        if (self.cur().tag != .text) return null;
        const text_tok = self.eat();
        const text_val = std.mem.trim(u8, text_tok.loc.slice(self.src), " \t");

        // Accept "else: content" or just "else".
        const before: []const u8 = if (std.mem.indexOfScalar(u8, text_val, ':')) |cp|
            std.mem.trim(u8, text_val[0..cp], " \t")
        else
            text_val;
        if (!isElseKeyword(before)) return null;

        const after: []const u8 = if (std.mem.indexOfScalar(u8, text_val, ':')) |cp| blk: {
            const head = std.mem.trim(u8, text_val[cp + 1 ..], " \t");
            const tail = try self.collectLineRemainder();
            break :blk if (head.len == 0)
                tail
            else if (tail.len == 0)
                head
            else
                try std.fmt.allocPrint(self.alloc, "{s} {s}", .{ head, tail });
        } else "";
        const content = try self.parseGatherBranchBody(after);
        return Parsed.Branch{ .condition = null, .is_else = true, .content = content };
    }

    // -- Choices & gathers ----------------------------------------------------

    /// Parse one choice item: counts `*`/`+` nesting, parses choice text, then
    /// collects the body lines (inner_content) until the next same-nesting choice
    /// or gather.  Returns null only if the current token is not a choice marker.
    fn parseChoiceItem(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        if (self.cur().tag != .choice_once and self.cur().tag != .choice_sticky)
            return null;

        // Count nesting level and whether sticky.
        var nesting: u8 = 0;
        var is_sticky = false;
        while (self.cur().tag == .choice_once or self.cur().tag == .choice_sticky) {
            is_sticky = self.cur().tag == .choice_sticky;
            nesting += 1;
            _ = self.eat();
        }

        // Optional label `(name)` at the start of the choice text.
        // Handles both `* (label)` and `* (label) rest of choice`.
        var label: ?[]const u8 = null;
        if (self.cur().tag == .text) {
            const orig_tok = self.cur();
            const tok_text = orig_tok.loc.slice(self.src);
            const trimmed = trimLeft(tok_text);
            if (trimmed.len >= 2 and trimmed[0] == '(') {
                if (std.mem.indexOfScalar(u8, trimmed, ')')) |close| {
                    label = trimmed[1..close];
                    _ = self.eat();
                    const rest = trimLeft(trimmed[close + 1 ..]);
                    if (rest.len > 0) {
                        const rest_start = @intFromPtr(rest.ptr) - @intFromPtr(self.src.ptr);
                        self.overhang_tok = .{
                            .tag = .text,
                            .loc = .{ .start = @intCast(rest_start), .end = orig_tok.loc.end },
                            .line = orig_tok.line,
                        };
                    }
                }
            }
        }

        // Conditions: zero or more consecutive `{expr}` blocks before any visible
        // text.  Multiple conditions are ANDed together.
        var condition: ?*Parsed.Expression = null;
        while (self.cur().tag == .left_brace) {
            const saved = self.save();
            const next_cond = try self.parseBraceExpr();
            if (next_cond == null) {
                // Not a simple expression — restore and treat as inline text later.
                self.restore(saved);
                break;
            }
            const cond_expr = next_cond.?;
            if (condition) |existing| {
                const combined = try self.alloc.create(Parsed.Expression);
                combined.* = .{ .binary = .{ .op = .and_, .lhs = existing, .rhs = cond_expr } };
                condition = combined;
            } else {
                condition = cond_expr;
            }
        }

        // Parse the choice text: start [ choice_only ] following
        var start_content = std.ArrayList(Parsed.InlineElement).empty;
        var choice_only_content = std.ArrayList(Parsed.InlineElement).empty;
        var following_content = std.ArrayList(Parsed.InlineElement).empty;
        var phase: enum { start, in_bracket, after_bracket } = .start;

        scan: while (true) {
            switch (self.cur().tag) {
                .text => {
                    // Only trim leading whitespace — trailing spaces before {expr}
                    // are part of the prose and must be preserved in the output.
                    const t = trimLeft(self.eat().loc.slice(self.src));
                    if (t.len == 0) continue :scan;
                    switch (phase) {
                        .start => try start_content.append(self.alloc, .{ .text = t }),
                        .in_bracket => try choice_only_content.append(self.alloc, .{ .text = t }),
                        .after_bracket => try following_content.append(self.alloc, .{ .text = t }),
                    }
                },
                .left_bracket => {
                    _ = self.eat();
                    phase = .in_bracket;
                },
                .right_bracket => {
                    _ = self.eat();
                    phase = .after_bracket;
                },
                .left_brace => {
                    if (try self.parseBraceExpr()) |expr| {
                        switch (phase) {
                            .start => try start_content.append(self.alloc, .{ .inline_expr = expr }),
                            .in_bracket => try choice_only_content.append(self.alloc, .{ .inline_expr = expr }),
                            .after_bracket => try following_content.append(self.alloc, .{ .inline_expr = expr }),
                        }
                    } else self.skipBraceBlock();
                },
                .divert_arrow => {
                    if (try self.parseDivertInline()) |d|
                        try following_content.append(self.alloc, .{ .divert = d });
                    break :scan;
                },
                .divert_return => {
                    if (try self.parseDivertInline()) |d|
                        try following_content.append(self.alloc, .{ .divert = d });
                    break :scan;
                },
                .newline, .eof => break :scan,
                else => _ = self.eat(),
            }
        }

        if (self.cur().tag == .newline) _ = self.eat();

        // Collect body content until next same-nesting choice/gather.
        const inner_content = try self.parseChoiceBodyContent(nesting);

        return .{ .choice = .{
            .nesting = nesting,
            .is_sticky = is_sticky,
            .condition = condition,
            .start_content = try start_content.toOwnedSlice(self.alloc),
            .choice_only_content = try choice_only_content.toOwnedSlice(self.alloc),
            .following_content = try following_content.toOwnedSlice(self.alloc),
            .label = label,
            .inner_content = inner_content,
        } };
    }

    /// Parse a gather marker (`-` or `- -`) into a Parsed.Gather.
    /// The gather's same-line text is left in the token stream so that
    /// subsequent iterations of parseContent will pick it up as a text item.
    fn parseGatherItem(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        if (self.cur().tag != .gather) return null;

        var nesting: u8 = 0;
        while (self.cur().tag == .gather) {
            nesting += 1;
            _ = self.eat();
        }

        // Optional label `(name)` — extract if present.
        // Handles: `- (name)` (label only), `- (name) text` (label + same-line text).
        var label: ?[]const u8 = null;
        if (self.cur().tag == .text) {
            const orig_tok = self.cur();
            const tok_text = orig_tok.loc.slice(self.src);
            const trimmed = trimLeft(tok_text);
            if (trimmed.len >= 2 and trimmed[0] == '(') {
                if (std.mem.indexOfScalar(u8, trimmed, ')')) |close| {
                    label = trimmed[1..close];
                    _ = self.eat();
                    // If there's text after the closing `)`, store it as an overhang token
                    // so the content parser still sees it as a text token.
                    const rest = trimLeft(trimmed[close + 1 ..]);
                    if (rest.len > 0) {
                        const rest_start = @intFromPtr(rest.ptr) - @intFromPtr(self.src.ptr);
                        self.overhang_tok = .{
                            .tag = .text,
                            .loc = .{ .start = @intCast(rest_start), .end = orig_tok.loc.end },
                            .line = orig_tok.line,
                        };
                    }
                }
            }
        }
        return .{ .gather = .{ .nesting = nesting, .label = label } };
    }

    /// Parse items for the body of a choice, stopping before the next
    /// choice/gather at nesting level ≤ `parent_nesting`.
    fn parseChoiceBodyContent(self: *Parser, parent_nesting: u8) error{OutOfMemory}![]Parsed.FlowItem {
        var items = std.ArrayList(Parsed.FlowItem).empty;
        while (true) {
            switch (self.cur().tag) {
                .eof, .knot_marker, .stitch_marker, .right_brace => break,

                .newline => _ = self.eat(),

                .text => {
                    if (try self.parseTextLine()) |item|
                        try items.append(self.alloc, item);
                },

                .divert_arrow, .divert_return => {
                    if (try self.parseDivertLine()) |item|
                        try items.append(self.alloc, item);
                },

                .logic_line => {
                    if (try self.parseLogicLine()) |item|
                        try items.append(self.alloc, item);
                },

                .left_brace => {
                    if (try self.parseBraceConditional()) |cond| {
                        try items.append(self.alloc, .{ .conditional = cond });
                    } else if (try self.parseTextLine()) |item| {
                        try items.append(self.alloc, item);
                    }
                },

                .choice_once, .choice_sticky => {
                    // Peek nesting level.
                    var cnt: u8 = 0;
                    const sv = self.save();
                    while (self.cur().tag == .choice_once or self.cur().tag == .choice_sticky) {
                        cnt += 1;
                        _ = self.eat();
                    }
                    self.restore(sv);
                    if (cnt <= parent_nesting) break; // same or parent level → stop
                    // Deeper nested choice — include in body.
                    if (try self.parseChoiceItem()) |item|
                        try items.append(self.alloc, item);
                },

                .gather => {
                    // Peek nesting.
                    var cnt: u8 = 0;
                    const sv = self.save();
                    while (self.cur().tag == .gather) {
                        cnt += 1;
                        _ = self.eat();
                    }
                    self.restore(sv);
                    if (cnt <= parent_nesting) break; // same or parent level → stop
                    // Deeper gather — include as FlowItem.gather.
                    if (try self.parseGatherItem()) |gitem|
                        try items.append(self.alloc, gitem);
                },

                .hash, .thread_start => self.skipToEol(),

                else => _ = self.eat(),
            }
        }
        return items.toOwnedSlice(self.alloc);
    }

    /// Parse flow items inside a branch body, stopping before:
    ///   gather (`-`), `}`, `knot_marker`, `eof`.
    fn parseBranchContent(self: *Parser) error{OutOfMemory}![]Parsed.FlowItem {
        var items = std.ArrayList(Parsed.FlowItem).empty;
        loop: while (true) {
            switch (self.cur().tag) {
                .eof, .knot_marker, .right_brace, .gather => break :loop,

                .newline => _ = self.eat(),

                .text => {
                    if (try self.parseTextLine()) |item|
                        try items.append(self.alloc, item);
                },

                .divert_arrow, .divert_return => {
                    if (try self.parseDivertLine()) |item|
                        try items.append(self.alloc, item);
                },

                .logic_line => {
                    if (try self.parseLogicLine()) |item|
                        try items.append(self.alloc, item);
                },

                .left_brace => {
                    if (try self.parseBraceSequenceBlock()) |seq| {
                        try items.append(self.alloc, .{ .sequence = seq });
                    } else if (try self.parseBraceConditional()) |cond| {
                        try items.append(self.alloc, .{ .conditional = cond });
                    } else if (try self.parseTextLine()) |item| {
                        try items.append(self.alloc, item);
                    } else {
                        // All block parsers failed — skip to prevent infinite loop.
                        self.skipBraceBlock();
                    }
                },

                .choice_once, .choice_sticky => {
                    if (try self.parseChoiceItem()) |item|
                        try items.append(self.alloc, item);
                },

                else => _ = self.eat(),
            }
        }
        return items.toOwnedSlice(self.alloc);
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

/// True when `s` (already trimmed) equals "else" (case-sensitive exact match).
fn isElseKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "else");
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

/// Parse a parameter list like "(x, ref y, -> z)" from a string starting with '('.
fn parseParamList(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]Parsed.Param {
    var params = std.ArrayList(Parsed.Param).empty;
    // Find matching paren.
    if (s.len == 0 or s[0] != '(') return params.toOwnedSlice(alloc);
    const end_paren = std.mem.indexOfScalar(u8, s, ')') orelse s.len;
    const inner = s[1..end_paren];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw_param| {
        const p = std.mem.trim(u8, raw_param, " \t");
        if (p.len == 0) continue;
        var is_ref = false;
        var is_divert = false;
        var param_name = p;
        if (std.mem.startsWith(u8, p, "ref ") or std.mem.startsWith(u8, p, "ref\t")) {
            is_ref = true;
            param_name = std.mem.trim(u8, p[4..], " \t");
        } else if (std.mem.startsWith(u8, p, "->")) {
            is_divert = true;
            param_name = std.mem.trim(u8, p[2..], " \t");
        }
        // Strip trailing junk (e.g. "==")
        const name_end = identEnd(param_name);
        if (name_end == 0) continue;
        try params.append(alloc, .{
            .name = param_name[0..name_end],
            .is_ref = is_ref,
            .is_divert = is_divert,
        });
    }
    return params.toOwnedSlice(alloc);
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

    // Double-quoted string literal, potentially with interpolation.
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        var ep = ExprParser.init(alloc, s);
        if (try ep.parseExpr()) |expr| {
            ep.skipWs();
            if (ep.pos == ep.src.len) {
                alloc.destroy(e);
                return expr;
            }
        }
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

// ── Expression parser ─────────────────────────────────────────────────────────

/// Character-level precedence-climbing expression parser.
/// Operates on the raw text slice inside a `{...}` brace block.
const ExprParser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    fn init(alloc: std.mem.Allocator, src: []const u8) ExprParser {
        return .{ .alloc = alloc, .src = src, .pos = 0 };
    }

    fn skipWs(self: *ExprParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
    }

    fn rest(self: *const ExprParser) []const u8 {
        return self.src[self.pos..];
    }

    pub fn parseExpr(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        self.skipWs();
        return self.parseBinary(0);
    }

    fn parseBinary(self: *ExprParser, min_prec: u8) error{OutOfMemory}!?*Parsed.Expression {
        var lhs = (try self.parseUnary()) orelse return null;
        while (true) {
            self.skipWs();
            var op_len: usize = undefined;
            const op = epPeekBinaryOp(self.rest(), &op_len) orelse break;
            const prec = binOpPrec(op);
            if (prec < min_prec) break;
            self.pos += op_len;
            self.skipWs();
            const rhs = (try self.parseBinary(prec + 1)) orelse break;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            lhs = node;
        }
        return lhs;
    }

    fn parseUnary(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        self.skipWs();
        const s = self.rest();
        if (s.len == 0) return null;

        if (epKwStartsWith(s, "not")) {
            self.pos += 3;
            self.skipWs();
            const operand = (try self.parseUnary()) orelse return null;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .unary = .{ .op = .not, .operand = operand } };
            return node;
        }
        if (s[0] == '!') {
            self.pos += 1;
            self.skipWs();
            const operand = (try self.parseUnary()) orelse return null;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .unary = .{ .op = .not, .operand = operand } };
            return node;
        }
        // Unary `-` only when NOT immediately followed by a digit
        // (negative numeric literals are handled in parsePrimary).
        if (s[0] == '-' and (s.len < 2 or (!std.ascii.isDigit(s[1]) and s[1] != '>'))) {
            self.pos += 1;
            self.skipWs();
            const operand = (try self.parseUnary()) orelse return null;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .unary = .{ .op = .negate, .operand = operand } };
            return node;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        self.skipWs();
        const s = self.rest();
        if (s.len == 0) return null;

        // Divert target value: -> target
        if (s.len >= 2 and s[0] == '-' and s[1] == '>') {
            self.pos += 2;
            self.skipWs();
            const start = self.pos;
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') break;
                self.pos += 1;
            }
            const target = self.src[start..self.pos];
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .divert_target = target };
            return node;
        }

        if (s[0] == '(') {
            // Try list literal first: () or (ident, ident, ...).
            if (try self.tryParseListLit()) |node| return node;
            // Fallback: grouped expression.
            self.pos += 1;
            const inner = (try self.parseBinary(0)) orelse return null;
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            return inner;
        }
        if (s[0] == '"') {
            self.pos += 1;
            const start = self.pos;
            var seg_start = self.pos;
            var parts = std.ArrayList(Parsed.StringPart).empty;
            while (self.pos < self.src.len) {
                switch (self.src[self.pos]) {
                    '"' => {
                        if (parts.items.len == 0) {
                            const content = self.src[start..self.pos];
                            self.pos += 1;
                            const node = try self.alloc.create(Parsed.Expression);
                            node.* = .{ .string_lit = content };
                            return node;
                        }
                        if (self.pos > seg_start) {
                            try parts.append(self.alloc, .{ .text = self.src[seg_start..self.pos] });
                        }
                        self.pos += 1;
                        const node = try self.alloc.create(Parsed.Expression);
                        node.* = .{ .interpolated_string = try parts.toOwnedSlice(self.alloc) };
                        return node;
                    },
                    '{' => {
                        if (self.pos > seg_start) {
                            try parts.append(self.alloc, .{ .text = self.src[seg_start..self.pos] });
                        }
                        self.pos += 1;
                        const expr_start = self.pos;
                        var depth: u32 = 1;
                        while (self.pos < self.src.len and depth > 0) {
                            switch (self.src[self.pos]) {
                                '{' => depth += 1,
                                '}' => {
                                    depth -= 1;
                                    if (depth == 0) break;
                                },
                                else => {},
                            }
                            self.pos += 1;
                        }
                        const inner = self.src[expr_start..self.pos];
                        var inner_ep = ExprParser.init(self.alloc, inner);
                        const inner_expr = (try inner_ep.parseExpr()) orelse return null;
                        inner_ep.skipWs();
                        if (inner_ep.pos != inner_ep.src.len) return null;
                        try parts.append(self.alloc, .{ .expr = inner_expr });
                        if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
                        seg_start = self.pos;
                    },
                    else => self.pos += 1,
                }
            }
            return null;
        }
        if (epKwStartsWith(s, "true")) {
            self.pos += 4;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .bool_lit = true };
            return node;
        }
        if (epKwStartsWith(s, "false")) {
            self.pos += 5;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .bool_lit = false };
            return node;
        }
        if (s[0] == '-' and s.len > 1 and std.ascii.isDigit(s[1])) {
            return self.parseNumberLiteral();
        }
        if (std.ascii.isDigit(s[0])) {
            // Check if the leading digits are part of an identifier (e.g. "512x2").
            // Ink allows identifiers that start with digits. Scan past leading digits;
            // if the next char is alphabetic or '_', it's an identifier, not a number.
            var di: usize = 0;
            while (di < s.len and std.ascii.isDigit(s[di])) di += 1;
            if (di < s.len and (std.ascii.isAlphabetic(s[di]) or s[di] == '_')) {
                return self.parseIdentOrCall();
            }
            return self.parseNumberLiteral();
        }
        if (std.ascii.isAlphabetic(s[0]) or s[0] == '_') {
            return self.parseIdentOrCall();
        }
        return null;
    }

    fn parseNumberLiteral(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            if (self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
            }
        }
        const num_str = self.src[start..self.pos];
        const node = try self.alloc.create(Parsed.Expression);
        if (is_float) {
            node.* = .{ .float_lit = std.fmt.parseFloat(f64, num_str) catch return null };
        } else {
            node.* = .{ .int_lit = std.fmt.parseInt(i64, num_str, 10) catch return null };
        }
        return node;
    }

    fn parseIdentOrCall(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') break;
            self.pos += 1;
        }
        const name = self.src[start..self.pos];
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            self.pos += 1;
            var args = std.ArrayList(*Parsed.Expression).empty;
            self.skipWs();
            while (self.pos < self.src.len and self.src[self.pos] != ')') {
                const arg = (try self.parseBinary(0)) orelse break;
                try args.append(self.alloc, arg);
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    self.skipWs();
                }
            }
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.alloc) } };
            return node;
        }
        const node = try self.alloc.create(Parsed.Expression);
        node.* = .{ .var_ref = name };
        return node;
    }

    /// Try to parse `()` or `(ident, ident, ...)` as an InkListLiteral expression.
    /// Returns null and restores position if not a valid list literal.
    fn tryParseListLit(self: *ExprParser) error{OutOfMemory}!?*Parsed.Expression {
        const saved = self.pos;
        if (self.pos >= self.src.len or self.src[self.pos] != '(') return null;
        self.pos += 1;
        self.skipWs();

        // Empty list: ()
        if (self.pos < self.src.len and self.src[self.pos] == ')') {
            self.pos += 1;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .list_lit = .{ .items = &.{} } };
            return node;
        }

        // Attempt to parse comma-separated identifiers (possibly "origin.item").
        // Items must start with a letter or underscore (not a digit).
        var items = std.ArrayList([]const u8).empty;
        while (true) {
            self.skipWs();
            const start = self.pos;
            // List item names must start with a letter or underscore, not a digit.
            if (self.pos >= self.src.len or
                (!std.ascii.isAlphabetic(self.src[self.pos]) and self.src[self.pos] != '_'))
            {
                self.pos = saved;
                return null;
            }
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') break;
                self.pos += 1;
            }
            if (self.pos == start) {
                self.pos = saved;
                return null;
            }
            try items.append(self.alloc, self.src[start..self.pos]);
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != ')') {
            // Has non-ident content — it's a grouped expression.
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        const node = try self.alloc.create(Parsed.Expression);
        node.* = .{ .list_lit = .{ .items = try items.toOwnedSlice(self.alloc) } };
        return node;
    }
};

/// True if `s` starts with keyword `kw` followed by a non-ident char (or end).
fn epKwStartsWith(s: []const u8, kw: []const u8) bool {
    if (!std.mem.startsWith(u8, s, kw)) return false;
    if (s.len == kw.len) return true;
    const c = s[kw.len];
    return !std.ascii.isAlphanumeric(c) and c != '_';
}

/// Binary operator precedence (higher = tighter binding).
fn binOpPrec(op: Parsed.BinaryOp) u8 {
    return switch (op) {
        .or_ => 1,
        .and_ => 2,
        .eq, .ne => 3,
        .has, .hasnt, .intersect => 3,
        .gt, .lt, .ge, .le => 4,
        .add, .sub => 5,
        .mul, .div, .mod => 6,
    };
}

/// Peek a binary operator at the start of `s`; write its byte-length into `out_len`.
fn epPeekBinaryOp(s: []const u8, out_len: *usize) ?Parsed.BinaryOp {
    if (s.len == 0) return null;
    if (std.mem.startsWith(u8, s, "==")) { out_len.* = 2; return .eq; }
    if (std.mem.startsWith(u8, s, "!?")) { out_len.* = 2; return .hasnt; }
    if (std.mem.startsWith(u8, s, "!=")) { out_len.* = 2; return .ne; }
    if (s[0] == '?') { out_len.* = 1; return .has; }
    if (s[0] == '^') { out_len.* = 1; return .intersect; }
    if (std.mem.startsWith(u8, s, ">=")) { out_len.* = 2; return .ge; }
    if (std.mem.startsWith(u8, s, "<=")) { out_len.* = 2; return .le; }
    if (std.mem.startsWith(u8, s, "&&")) { out_len.* = 2; return .and_; }
    if (std.mem.startsWith(u8, s, "||")) { out_len.* = 2; return .or_; }
    if (epKwStartsWith(s, "and")) { out_len.* = 3; return .and_; }
    if (epKwStartsWith(s, "or"))  { out_len.* = 2; return .or_; }
    if (epKwStartsWith(s, "mod")) { out_len.* = 3; return .mod; }
    switch (s[0]) {
        '+' => { out_len.* = 1; return .add; },
        '-' => { out_len.* = 1; return .sub; },
        '*' => { out_len.* = 1; return .mul; },
        '/' => { out_len.* = 1; return .div; },
        '%' => { out_len.* = 1; return .mod; },
        '>' => { out_len.* = 1; return .gt; },
        '<' => { out_len.* = 1; return .lt; },
        else => return null,
    }
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

test "Compiler parser: brace expr at line start produces inline_expr FlowItem" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const story = try parse(arena.allocator(), "{2 + 3}\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const item = story.root_content[0];
    try testing.expect(item == .text);
    try testing.expectEqual(@as(usize, 1), item.text.elements.len);
    try testing.expect(item.text.elements[0] == .inline_expr);
    const expr = item.text.elements[0].inline_expr;
    try testing.expect(expr.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.add, expr.binary.op);
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

// ── ExprParser unit tests ─────────────────────────────────────────────────────

test "Compiler parser: ExprParser int literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "42");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .int_lit);
    try testing.expectEqual(@as(i64, 42), expr.?.int_lit);
}

test "Compiler parser: ExprParser float literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "3.14");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .float_lit);
    try testing.expectApproxEqAbs(@as(f64, 3.14), expr.?.float_lit, 1e-9);
}

test "Compiler parser: ExprParser boolean true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "true");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .bool_lit);
    try testing.expectEqual(true, expr.?.bool_lit);
}

test "Compiler parser: ExprParser binary add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "2 + 3");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.add, expr.?.binary.op);
    try testing.expectEqual(@as(i64, 2), expr.?.binary.lhs.int_lit);
    try testing.expectEqual(@as(i64, 3), expr.?.binary.rhs.int_lit);
}

test "Compiler parser: ExprParser operator precedence mul before add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "2 * 3 + 5" should parse as (2*3)+5, not 2*(3+5).
    var ep = ExprParser.init(arena.allocator(), "2 * 3 + 5");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.add, expr.?.binary.op);
    try testing.expect(expr.?.binary.lhs.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.mul, expr.?.binary.lhs.binary.op);
}

test "Compiler parser: ExprParser unary not keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "not true");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .unary);
    try testing.expectEqual(Parsed.UnaryOp.not, expr.?.unary.op);
    try testing.expect(expr.?.unary.operand.* == .bool_lit);
    try testing.expectEqual(true, expr.?.unary.operand.bool_lit);
}

test "Compiler parser: ExprParser parenthesized expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "2 * (5 - 1)");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.mul, expr.?.binary.op);
    try testing.expect(expr.?.binary.rhs.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.sub, expr.?.binary.rhs.binary.op);
}

test "Compiler parser: ExprParser mod keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "8 mod 3");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.mod, expr.?.binary.op);
}

test "Compiler parser: ExprParser comparison operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ep = ExprParser.init(arena.allocator(), "3 > 1");
    const expr = try ep.parseExpr();
    try testing.expect(expr != null);
    try testing.expect(expr.?.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.gt, expr.?.binary.op);
}

test "Compiler parser: ExprParser inline brace expr with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "{ 2 * 3 + 5 * 6 }" — leading/trailing spaces inside braces are trimmed by ExprParser.
    const story = try parse(arena.allocator(), "{ 2 * 3 + 5 * 6 }\n");
    try testing.expectEqual(@as(usize, 1), story.root_content.len);
    const item = story.root_content[0];
    try testing.expect(item == .text);
    try testing.expectEqual(@as(usize, 1), item.text.elements.len);
    try testing.expect(item.text.elements[0] == .inline_expr);
    const expr = item.text.elements[0].inline_expr;
    try testing.expect(expr.* == .binary);
    try testing.expectEqual(Parsed.BinaryOp.add, expr.binary.op);
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
