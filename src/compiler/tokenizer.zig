/// Ink source tokenizer — character-level scanner that produces a flat Token
/// stream consumed by the parser.  The scanner is context-aware at the
/// line level: structural markers (* + - ~ = ===) are only recognised at
/// the start of a line (after optional leading whitespace).  Everything
/// else is either a structural delimiter ({} [] # | \n -> <-) or plain
/// text that the parser re-scans for finer-grained content.
const std = @import("std");

// ── Token types ───────────────────────────────────────────────────────────────

pub const TokenTag = enum {
    text,
    newline,
    knot_marker, // === or ==
    stitch_marker, // = (single)
    choice_once, // * at line start
    choice_sticky, // + at line start
    gather, // - at line start (not followed by >)
    logic_line, // ~ at line start
    divert_arrow, // ->
    divert_return, // ->->
    thread_start, // <-
    left_brace, // {
    right_brace, // }
    left_bracket, // [
    right_bracket, // ]
    hash, // #
    colon, // :  (structural inside {})
    pipe, // |
    eof,
    // Line-start declaration keywords
    kw_var, // VAR
    kw_const, // CONST
    kw_list, // LIST
    kw_include, // INCLUDE
    kw_external, // EXTERNAL
    // Expression / statement keywords (recognised inside their contexts)
    kw_ref, // ref
    kw_end, // END
    kw_done, // DONE
    kw_return, // return
    kw_temp, // temp
    kw_and, // and
    kw_or, // or
    kw_not, // not
    kw_mod, // mod
};

pub const Token = struct {
    tag: TokenTag,
    /// Slice of the original source string.  For structural single-char
    /// tokens this is a 1-byte slice; for `text` it may span many chars.
    text: []const u8,
    line: u32,
    col: u32,
};

// ── Tokenizer ─────────────────────────────────────────────────────────────────

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    /// True at the very start of a line (before any non-whitespace has been
    /// consumed on that line).  Structural markers are only emitted when
    /// this flag is set; once a non-marker token is produced it is cleared.
    at_line_start: bool,

    pub fn init(src: []const u8) Tokenizer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
            .col = 1,
            .at_line_start = true,
        };
    }

    // -- Low-level character helpers ------------------------------------------

    inline fn cur(self: *const Tokenizer) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    inline fn peek1(self: *const Tokenizer) ?u8 {
        if (self.pos + 1 >= self.src.len) return null;
        return self.src[self.pos + 1];
    }

    /// Advance one character, updating line/col tracking.
    inline fn eat(self: *Tokenizer) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    // -- Public API -----------------------------------------------------------

    /// Return the next token.  Never fails — at end of input returns .eof.
    pub fn next(self: *Tokenizer) Token {
        // We loop so that comment-consuming code can `continue` without
        // a recursive call.
        loop: while (true) {
            // At the start of a line, skip leading spaces and tabs so that
            // indented choices / gathers are recognised correctly.
            if (self.at_line_start) {
                while (self.cur()) |c| {
                    if (c == ' ' or c == '\t') self.eat() else break;
                }
            }

            const tl = self.line;
            const tc = self.col;
            const ts = self.pos;

            const c = self.cur() orelse {
                return .{ .tag = .eof, .text = "", .line = tl, .col = tc };
            };

            switch (c) {
                '\r' => {
                    self.eat();
                    if (self.cur() == '\n') self.eat();
                    self.at_line_start = true;
                    return tok(.newline, self.src[ts..self.pos], tl, tc);
                },
                '\n' => {
                    self.eat();
                    self.at_line_start = true;
                    return tok(.newline, self.src[ts..self.pos], tl, tc);
                },
                '{' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.left_brace, self.src[ts..self.pos], tl, tc);
                },
                '}' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.right_brace, self.src[ts..self.pos], tl, tc);
                },
                '[' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.left_bracket, self.src[ts..self.pos], tl, tc);
                },
                ']' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.right_bracket, self.src[ts..self.pos], tl, tc);
                },
                '#' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.hash, self.src[ts..self.pos], tl, tc);
                },
                '|' => {
                    self.eat();
                    self.at_line_start = false;
                    return tok(.pipe, self.src[ts..self.pos], tl, tc);
                },
                '-' => {
                    // Could be: ->  →  divert_arrow
                    //           ->-> →  divert_return
                    //           -     →  gather (only at line start)
                    //           -     →  text char otherwise
                    self.eat();
                    if (self.cur() == '>') {
                        self.eat(); // consume >
                        // Check for ->->
                        if (self.cur() == '-' and self.peek1() == '>') {
                            self.eat(); // consume second -
                            self.eat(); // consume second >
                            self.at_line_start = false;
                            return tok(.divert_return, self.src[ts..self.pos], tl, tc);
                        }
                        self.at_line_start = false;
                        return tok(.divert_arrow, self.src[ts..self.pos], tl, tc);
                    }
                    if (self.at_line_start) {
                        // Gather marker.  Keep at_line_start=true so that
                        // consecutive - chars are each emitted as gather.
                        return tok(.gather, self.src[ts..self.pos], tl, tc);
                    }
                    // Bare - in the middle of a line → treat as text.
                    return self.scanText(ts, tl, tc);
                },
                '<' => {
                    self.eat();
                    if (self.cur() == '-') {
                        self.eat();
                        self.at_line_start = false;
                        return tok(.thread_start, self.src[ts..self.pos], tl, tc);
                    }
                    // < as a text char (e.g. <> glue will be in text).
                    return self.scanText(ts, tl, tc);
                },
                '*' => {
                    if (self.at_line_start) {
                        self.eat();
                        // Keep at_line_start so "* * choice" works.
                        return tok(.choice_once, self.src[ts..self.pos], tl, tc);
                    }
                    return self.scanText(ts, tl, tc);
                },
                '+' => {
                    if (self.at_line_start) {
                        self.eat();
                        return tok(.choice_sticky, self.src[ts..self.pos], tl, tc);
                    }
                    return self.scanText(ts, tl, tc);
                },
                '~' => {
                    if (self.at_line_start) {
                        self.eat();
                        self.at_line_start = false;
                        return tok(.logic_line, self.src[ts..self.pos], tl, tc);
                    }
                    return self.scanText(ts, tl, tc);
                },
                '=' => {
                    if (self.at_line_start) {
                        self.eat();
                        var count: u8 = 1;
                        while (self.cur() == '=') {
                            self.eat();
                            count += 1;
                        }
                        self.at_line_start = false;
                        const tag: TokenTag = if (count >= 2) .knot_marker else .stitch_marker;
                        return tok(tag, self.src[ts..self.pos], tl, tc);
                    }
                    return self.scanText(ts, tl, tc);
                },
                '/' => {
                    self.eat();
                    if (self.cur() == '/') {
                        // Single-line comment — skip to EOL then restart.
                        self.eat();
                        while (self.cur()) |cc| {
                            if (cc == '\n') break;
                            self.eat();
                        }
                        continue :loop;
                    }
                    if (self.cur() == '*') {
                        // Block comment — skip to closing */.
                        self.eat();
                        while (self.cur() != null) {
                            if (self.cur() == '*' and self.peek1() == '/') {
                                self.eat();
                                self.eat();
                                break;
                            }
                            self.eat();
                        }
                        continue :loop;
                    }
                    // Bare / (division, path separator) → text.
                    return self.scanText(ts, tl, tc);
                },
                else => return self.scanText(ts, tl, tc),
            }
        }
    }

    /// Accumulate a `text` token starting at `ts` (some chars may already
    /// have been consumed from `ts` to `self.pos`).  Stops before the next
    /// structural delimiter so that the caller can emit it as its own token.
    fn scanText(self: *Tokenizer, ts: usize, tl: u32, tc: u32) Token {
        while (self.cur()) |c| {
            switch (c) {
                // Hard structural stops.
                '{', '}', '[', ']', '#', '|', '\n', '\r' => break,
                // Stop before -> (divert) but keep bare -.
                '-' => {
                    if (self.peek1() == '>') break;
                    self.eat();
                },
                // Stop before <- (thread) but keep bare <.
                '<' => {
                    if (self.peek1() == '-') break;
                    self.eat();
                },
                // Stop before // or /* comments.
                '/' => {
                    const p = self.peek1();
                    if (p == '/' or p == '*') break;
                    self.eat();
                },
                else => self.eat(),
            }
        }
        self.at_line_start = false;
        return tok(.text, self.src[ts..self.pos], tl, tc);
    }
};

// -- Helper -------------------------------------------------------------------

inline fn tok(tag: TokenTag, text: []const u8, line: u32, col: u32) Token {
    return .{ .tag = tag, .text = text, .line = line, .col = col };
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

/// Collect all tokens from a source string into a slice (caller frees).
fn tokenizeAll(alloc: std.mem.Allocator, src: []const u8) ![]Token {
    var list = std.ArrayList(Token).empty;
    var t = Tokenizer.init(src);
    while (true) {
        const tk = t.next();
        try list.append(alloc, tk);
        if (tk.tag == .eof) break;
    }
    return list.toOwnedSlice(alloc);
}

test "Compiler tokenizer: empty input" {
    var t = Tokenizer.init("");
    const tk = t.next();
    try testing.expectEqual(TokenTag.eof, tk.tag);
    // A second call must also be safe.
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: single newline" {
    var t = Tokenizer.init("\n");
    try testing.expectEqual(TokenTag.newline, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: CRLF treated as single newline" {
    var t = Tokenizer.init("\r\n");
    const nl = t.next();
    try testing.expectEqual(TokenTag.newline, nl.tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: structural delimiters" {
    const src = "{}[]#|";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.left_brace, t.next().tag);
    try testing.expectEqual(TokenTag.right_brace, t.next().tag);
    try testing.expectEqual(TokenTag.left_bracket, t.next().tag);
    try testing.expectEqual(TokenTag.right_bracket, t.next().tag);
    try testing.expectEqual(TokenTag.hash, t.next().tag);
    try testing.expectEqual(TokenTag.pipe, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: divert arrow ->" {
    var t = Tokenizer.init("-> knot");
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings(" knot", text.text);
}

test "Compiler tokenizer: divert return ->->" {
    var t = Tokenizer.init("->->");
    try testing.expectEqual(TokenTag.divert_return, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: -> and ->-> are distinct" {
    // "-> ->" must be two divert_arrows, not a divert_return.
    var t = Tokenizer.init("-> ->");
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    // space + -> : the space is part of a text token since at_line_start=false,
    // but actually ' ' before '->' — '-' is seen in outer switch, cur='>', yields arrow.
    // The space between them: after emitting arrow, at_line_start=false.
    // Next char ' ' → scanText(" ") then stops at '-' (peek1='>').
    const mid = t.next();
    try testing.expectEqual(TokenTag.text, mid.tag);
    try testing.expectEqualStrings(" ", mid.text);
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: thread_start <-" {
    var t = Tokenizer.init("<- knot");
    try testing.expectEqual(TokenTag.thread_start, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: choice_once * at line start" {
    var t = Tokenizer.init("* choice text");
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    // Leading space skipped (at_line_start still true after *), then "choice text".
    try testing.expectEqualStrings("choice text", text.text);
}

test "Compiler tokenizer: choice_sticky + at line start" {
    var t = Tokenizer.init("+ sticky");
    try testing.expectEqual(TokenTag.choice_sticky, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: nested choices * * preserve nesting" {
    // Two * at line start → two choice_once tokens, whitespace between is skipped.
    var t = Tokenizer.init("* * nested");
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("nested", text.text);
}

test "Compiler tokenizer: * in expression is plain text" {
    // * not at line start (inside braces) → text char.
    var t = Tokenizer.init("{2 * 3}");
    try testing.expectEqual(TokenTag.left_brace, t.next().tag);
    const expr = t.next();
    try testing.expectEqual(TokenTag.text, expr.tag);
    try testing.expect(std.mem.indexOf(u8, expr.text, "*") != null);
    try testing.expectEqual(TokenTag.right_brace, t.next().tag);
}

test "Compiler tokenizer: gather - at line start" {
    var t = Tokenizer.init("- gather");
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("gather", text.text);
}

test "Compiler tokenizer: nested gathers - -" {
    var t = Tokenizer.init("- - nested");
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: - in expression is plain text not gather" {
    // - inside {} is not at line start → included in text.
    var t = Tokenizer.init("{10 - 2}");
    try testing.expectEqual(TokenTag.left_brace, t.next().tag);
    const expr = t.next();
    try testing.expectEqual(TokenTag.text, expr.tag);
    try testing.expect(std.mem.indexOf(u8, expr.text, "-") != null);
    try testing.expectEqual(TokenTag.right_brace, t.next().tag);
}

test "Compiler tokenizer: divert arrow in mid-line text" {
    // Text that contains -> stops the text token before the arrow.
    var t = Tokenizer.init("go -> target");
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("go ", text.text);
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    const target = t.next();
    try testing.expectEqual(TokenTag.text, target.tag);
    try testing.expectEqualStrings(" target", target.text);
}

test "Compiler tokenizer: logic_line ~ at line start" {
    var t = Tokenizer.init("~ x = 1");
    try testing.expectEqual(TokenTag.logic_line, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: knot_marker === and ==" {
    {
        var t = Tokenizer.init("=== knot_name ===");
        try testing.expectEqual(TokenTag.knot_marker, t.next().tag);
    }
    {
        var t = Tokenizer.init("== knot_name");
        try testing.expectEqual(TokenTag.knot_marker, t.next().tag);
    }
}

test "Compiler tokenizer: stitch_marker single =" {
    var t = Tokenizer.init("= stitch_name");
    try testing.expectEqual(TokenTag.stitch_marker, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: line_comment // skipped" {
    // A standalone comment line produces no token (the newline is next).
    var t = Tokenizer.init("// this is a comment\ntext");
    const first = t.next();
    try testing.expectEqual(TokenTag.newline, first.tag);
    const second = t.next();
    try testing.expectEqual(TokenTag.text, second.tag);
    try testing.expectEqualStrings("text", second.text);
}

test "Compiler tokenizer: inline comment // stops text token" {
    // Content before // is a text token; the comment is discarded.
    var t = Tokenizer.init("Hello world // ignored\n");
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("Hello world ", text.text);
    // Comment consumed; next is newline.
    try testing.expectEqual(TokenTag.newline, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: block_comment /* */ skipped" {
    var t = Tokenizer.init("before /* block\ncomment */ after");
    const before = t.next();
    try testing.expectEqual(TokenTag.text, before.tag);
    try testing.expectEqualStrings("before ", before.text);
    const after = t.next();
    try testing.expectEqual(TokenTag.text, after.tag);
    try testing.expectEqualStrings(" after", after.text);
}

test "Compiler tokenizer: glue <> is plain text" {
    // <> must not produce thread_start tokens; < followed by > is just text.
    var t = Tokenizer.init("text <> more");
    const all = t.next();
    try testing.expectEqual(TokenTag.text, all.tag);
    try testing.expect(std.mem.indexOf(u8, all.text, "<>") != null);
}

test "Compiler tokenizer: indented choice has leading whitespace skipped" {
    // Four spaces + * → choice_once, not text.
    var t = Tokenizer.init("    * indented");
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("indented", text.text);
}

test "Compiler tokenizer: multiline sequence" {
    const src = "line one\n* choice\n- gather\n-> END\n";
    const alloc = testing.allocator;
    const tokens = try tokenizeAll(alloc, src);
    defer alloc.free(tokens);

    // line one \n
    try testing.expectEqual(TokenTag.text, tokens[0].tag);
    try testing.expectEqual(TokenTag.newline, tokens[1].tag);
    // * choice \n
    try testing.expectEqual(TokenTag.choice_once, tokens[2].tag);
    try testing.expectEqual(TokenTag.text, tokens[3].tag);
    try testing.expectEqual(TokenTag.newline, tokens[4].tag);
    // - gather \n
    try testing.expectEqual(TokenTag.gather, tokens[5].tag);
    try testing.expectEqual(TokenTag.text, tokens[6].tag);
    try testing.expectEqual(TokenTag.newline, tokens[7].tag);
    // -> END \n
    try testing.expectEqual(TokenTag.divert_arrow, tokens[8].tag);
    try testing.expectEqual(TokenTag.text, tokens[9].tag);
    try testing.expectEqual(TokenTag.newline, tokens[10].tag);
    try testing.expectEqual(TokenTag.eof, tokens[11].tag);
}

test "Compiler tokenizer: hello_world.ink" {
    const alloc = testing.allocator;
    const src = try readOriginalFixture(alloc, "runtime/misc/hello_world.ink");
    defer alloc.free(src);

    var t = Tokenizer.init(src);

    // First token must be a text token containing the story text.
    const t0 = t.next();
    try testing.expectEqual(TokenTag.text, t0.tag);
    try testing.expectEqualStrings("Hello world", t0.text);

    // Optional trailing newline, then EOF.
    const t1 = t.next();
    const last = if (t1.tag == .newline) t.next() else t1;
    try testing.expectEqual(TokenTag.eof, last.tag);
}

test "Compiler tokenizer: arithmetic.ink" {
    // arithmetic.ink has 7 lines, each of the form  { expr }
    const alloc = testing.allocator;
    const src = try readOriginalFixture(alloc, "runtime/evaluation/arithmetic.ink");
    defer alloc.free(src);

    var t = Tokenizer.init(src);

    var left_count: u32 = 0;
    var right_count: u32 = 0;
    var found_number = false;
    var found_operator = false;

    while (true) {
        const tk = t.next();
        switch (tk.tag) {
            .eof => break,
            .left_brace => left_count += 1,
            .right_brace => right_count += 1,
            .text => {
                // The text between braces must contain numbers and operators.
                if (std.mem.indexOfAny(u8, tk.text, "0123456789") != null)
                    found_number = true;
                if (std.mem.indexOfAny(u8, tk.text, "+-*/%") != null or
                    std.mem.indexOf(u8, tk.text, "mod") != null)
                    found_operator = true;
            },
            else => {},
        }
    }

    // One { } pair per expression line — arithmetic.ink has 7 lines.
    try testing.expectEqual(@as(u32, 7), left_count);
    try testing.expectEqual(@as(u32, 7), right_count);
    try testing.expect(found_number);
    try testing.expect(found_operator);
}
