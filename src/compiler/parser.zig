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
        var list_defs = std.ArrayList(Parsed.ListDef).empty;

        // Root content: everything before the first knot marker.
        try self.parseContent(
            &root_content,
            &global_decls,
            &constants,
            &includes,
            &list_defs,
            false, // don't stop at stitch_marker in root
        );

        // Knots.
        while (self.cur().tag == .knot_marker) {
            const knot = try self.parseKnot(&global_decls, &constants, &includes, &list_defs);
            try knots.append(self.alloc, knot);
        }

        return Parsed.Story{
            .list_defs = try list_defs.toOwnedSlice(self.alloc),
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
        list_defs: *std.ArrayList(Parsed.ListDef),
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
                self.skipToEol();
                continue :parse self.cur().tag;
            },

            .left_brace => {
                // First try to parse as a conditional block.
                if (try self.parseBraceConditional()) |cond| {
                    try items.append(self.alloc, .{ .conditional = cond });
                } else if (try self.parseTextLine()) |item| {
                    // Handles inline expressions {x}{y} and falls back to skipBraceBlock.
                    try items.append(self.alloc, item);
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
    ) error{OutOfMemory}!Parsed.Knot {
        _ = self.eat(); // knot_marker

        // The rest of the header line is a text token like " knot_name ===" or
        // " function knot_name ===" (with optional "function" modifier keyword).
        var is_function = false;
        var knot_params: []Parsed.Param = &.{};
        const name = if (self.cur().tag == .text) blk: {
            const raw = self.eat().loc.slice(self.src);
            const t = trimLeft(raw);
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
        try self.parseContent(&content, global_decls, constants, includes, list_defs, true);

        // Parse stitches.
        var stitches = std.ArrayList(Parsed.Stitch).empty;
        while (self.cur().tag == .stitch_marker) {
            const stitch = try self.parseStitch(global_decls, constants, includes, list_defs);
            try stitches.append(self.alloc, stitch);
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
    ) error{OutOfMemory}!Parsed.Stitch {
        _ = self.eat(); // stitch_marker

        const name = if (self.cur().tag == .text)
            extractFirstIdentifier(self.eat().loc.slice(self.src))
        else
            "";
        self.skipToEol();

        var content = std.ArrayList(Parsed.FlowItem).empty;
        try self.parseContent(&content, global_decls, constants, includes, list_defs, true);

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
                    if (try self.parseBraceExpr()) |expr| {
                        try elements.append(self.alloc, .{ .inline_expr = expr });
                    } else {
                        self.skipBraceBlock();
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
                        defer arg_buf.deinit(self.alloc);
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
                const is_tunnel = self.cur().tag == .divert_arrow;
                if (is_tunnel) _ = self.eat();
                return .{ .target = target, .is_tunnel = is_tunnel, .is_thread = false, .args = args };
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
            // Strip parens: (name) means the item is "on" by default.
            if (item_str.len >= 2 and item_str[0] == '(' and item_str[item_str.len - 1] == ')') {
                item_name = item_str[1 .. item_str.len - 1];
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
                try items.append(self.alloc, .{ .name = clean_name, .value = item_val });
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

    // -- Logic lines ----------------------------------------------------------

    /// Parse a `~` logic line into a FlowItem.logic.
    /// Handles: `~ temp x = expr`, `~ x = expr`, `~ return [expr]`.
    /// Returns null (and skips the line) for unsupported or malformed forms.
    fn parseLogicLine(self: *Parser) error{OutOfMemory}!?Parsed.FlowItem {
        _ = self.eat(); // logic_line (~)
        // Grab the rest of the line as a single text token.
        const line_tok = if (self.cur().tag == .text) self.eat() else {
            self.skipToEol();
            return null;
        };
        self.skipToEol();
        const text = std.mem.trim(u8, line_tok.loc.slice(self.src), " \t");

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

        // ~ name++  →  name = name + 1
        if (std.mem.startsWith(u8, rest, "++")) {
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const one = try self.alloc.create(Parsed.Expression);
            one.* = .{ .int_lit = 1 };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .add, .lhs = lhs, .rhs = one } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp } } };
        }
        // ~ name--  →  name = name - 1
        if (std.mem.startsWith(u8, rest, "--")) {
            const lhs = try self.alloc.create(Parsed.Expression);
            lhs.* = .{ .var_ref = name };
            const one = try self.alloc.create(Parsed.Expression);
            one.* = .{ .int_lit = 1 };
            const rhs = try self.alloc.create(Parsed.Expression);
            rhs.* = .{ .binary = .{ .op = .sub, .lhs = lhs, .rhs = one } };
            const is_temp = self.isTempVar(name);
            return .{ .logic = .{ .assignment = .{ .name = name, .value = rhs, .is_temp = is_temp } } };
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
        // A simple expression: one text token followed immediately by }.
        if (self.cur().tag == .text) {
            const text_tok = self.eat();
            if (self.cur().tag == .right_brace) {
                _ = self.eat(); // }
                var ep = ExprParser.init(self.alloc, text_tok.loc.slice(self.src));
                if (try ep.parseExpr()) |expr| return expr;
            }
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
        if (self.cur().tag != .text) {
            self.restore(saved);
            return null;
        }
        const text_tok = self.eat();
        const text_raw = text_tok.loc.slice(self.src);

        // The colon separating condition from content is embedded in the text token.
        const colon_pos = std.mem.indexOfScalar(u8, text_raw, ':') orelse {
            // No colon → not a conditional (e.g. plain expression {x}).
            self.restore(saved);
            return null;
        };
        const expr_text = std.mem.trim(u8, text_raw[0..colon_pos], " \t");
        const after_colon = std.mem.trim(u8, text_raw[colon_pos + 1 ..], " \t");

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
    fn parseInlineBranchElems(self: *Parser) error{OutOfMemory}![]Parsed.InlineElement {
        var elems = std.ArrayList(Parsed.InlineElement).empty;
        while (true) {
            switch (self.cur().tag) {
                .pipe, .right_brace, .newline, .eof => break,
                .text => {
                    const t = self.eat();
                    const s = std.mem.trim(u8, t.loc.slice(self.src), " \t");
                    if (s.len > 0) try elems.append(self.alloc, .{ .text = s });
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
                    const after  = std.mem.trim(u8, text_val[cp + 1 ..], " \t");

                    if (isElseKeyword(before)) {
                        // - else: content  (else/fallthrough branch)
                        const branch_content = try self.parseGatherBranchBody(after);
                        try branches.append(self.alloc, .{ .condition = null, .content = branch_content });
                    } else {
                        // - expr: content  (condition branch for switch or multi-branch)
                        var ep2 = ExprParser.init(self.alloc, before);
                        const cond_expr = try ep2.parseExpr();
                        const branch_content = try self.parseGatherBranchBody(after);
                        try branches.append(self.alloc, .{ .condition = cond_expr, .content = branch_content });
                    }
                } else {
                    // - content  (no colon → no-condition content branch)
                    const branch_content = try self.parseGatherBranchBody(text_val);
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
            // Create a one-element text line from the inline text.
            const elem_slice = try self.alloc.dupe(Parsed.InlineElement, &.{.{ .text = same_line_text }});
            try items.append(self.alloc, .{ .text = .{ .elements = elem_slice } });
        }
        if (self.cur().tag == .newline) _ = self.eat();
        const more = try self.parseBranchContent();
        for (more) |item| try items.append(self.alloc, item);
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

        const after: []const u8 = if (std.mem.indexOfScalar(u8, text_val, ':')) |cp|
            std.mem.trim(u8, text_val[cp + 1 ..], " \t")
        else
            "";
        const content = try self.parseGatherBranchBody(after);
        return Parsed.Branch{ .condition = null, .content = content };
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

        // Optional label `(name)` — skip the text token that contains it so it
        // doesn't end up in start_content.  Labels look like `(ident)` as a text
        // token immediately after the `*` / `+` markers.
        if (self.cur().tag == .text) {
            const tok_text = self.cur().loc.slice(self.src);
            const trimmed = std.mem.trim(u8, tok_text, " \t");
            if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
                _ = self.eat(); // consume and discard the label token
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
                    _ = self.eat();
                    try following_content.append(self.alloc, .{ .divert = .{
                        .target = "->->",
                        .is_tunnel = false,
                        .is_thread = false,
                        .args = &.{},
                    } });
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
            .label = null,
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

        // If the gather has a `(label)` — for now we skip it.
        // (Labels appear as text tokens starting with "(" — ignore.)
        return .{ .gather = .{ .nesting = nesting, .label = null } };
    }

    /// Parse items for the body of a choice, stopping before the next
    /// choice/gather at nesting level ≤ `parent_nesting`.
    fn parseChoiceBodyContent(self: *Parser, parent_nesting: u8) error{OutOfMemory}![]Parsed.FlowItem {
        var items = std.ArrayList(Parsed.FlowItem).empty;
        while (true) {
            switch (self.cur().tag) {
                .eof, .knot_marker, .stitch_marker => break,

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
                    // Deeper gather — skip for now.
                    self.skipToEol();
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
                    if (try self.parseBraceConditional()) |cond| {
                        try items.append(self.alloc, .{ .conditional = cond });
                    } else if (try self.parseTextLine()) |item| {
                        try items.append(self.alloc, item);
                    }
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
        if (s[0] == '-' and (s.len < 2 or !std.ascii.isDigit(s[1]))) {
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
            self.pos += 1;
            const inner = (try self.parseBinary(0)) orelse return null;
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;
            return inner;
        }
        if (s[0] == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') self.pos += 1;
            const content = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            const node = try self.alloc.create(Parsed.Expression);
            node.* = .{ .string_lit = content };
            return node;
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
        .gt, .lt, .ge, .le => 4,
        .add, .sub => 5,
        .mul, .div, .mod => 6,
    };
}

/// Peek a binary operator at the start of `s`; write its byte-length into `out_len`.
fn epPeekBinaryOp(s: []const u8, out_len: *usize) ?Parsed.BinaryOp {
    if (s.len == 0) return null;
    if (std.mem.startsWith(u8, s, "==")) { out_len.* = 2; return .eq; }
    if (std.mem.startsWith(u8, s, "!=")) { out_len.* = 2; return .ne; }
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
