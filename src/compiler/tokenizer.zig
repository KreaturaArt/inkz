/// Ink source tokenizer — character-level scanner that produces a flat Token
/// stream consumed by the parser.  The scanner is context-aware at the
/// line level: structural markers (* + - ~ = ===) are only recognised at
/// the start of a line (after optional leading whitespace).  Everything
/// else is either a structural delimiter ({} [] # | \n -> <-) or plain
/// text that the parser re-scans for finer-grained content.
///
/// Design notes (matches sample/Tokenizer.zig idioms):
///   • Source is [:0]const u8 — the NUL sentinel is the EOF check, no
///     per-character bounds test needed.
///   • Token carries Loc{start,end: u32} offsets (8 bytes) instead of a
///     fat []const u8 slice (16 bytes).  Call tok.loc.slice(src) to get
///     the text.  Token total size: 16 bytes (was 32).
///   • The main scan loop is a labeled-switch state machine
///     (state: switch(State.start){ ... continue :state .foo; })
///     which makes state transitions explicit and avoids re-entry overhead.
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
    // Line-start declaration keywords (recognised as text-token content by parser)
    kw_var, // VAR
    kw_const, // CONST
    kw_list, // LIST
    kw_include, // INCLUDE
    kw_external, // EXTERNAL
    // Expression / statement keywords
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
    /// Byte-offset range into the source string.
    /// Use loc.slice(src) to recover the actual text.
    loc: Loc,
    /// Source line (1-based) where this token starts.
    line: u32,

    pub const Loc = struct {
        start: u32,
        end: u32,

        pub fn slice(loc: Loc, src: []const u8) []const u8 {
            return src[loc.start..loc.end];
        }
    };
};

// ── Tokenizer ─────────────────────────────────────────────────────────────────

const State = enum { start, slash, line_comment, block_comment };

pub const Tokenizer = struct {
    src: [:0]const u8,
    pos: u32,
    line: u32,
    /// True at the very start of a line (before any non-whitespace has been
    /// consumed on that line).  Structural markers are only emitted when
    /// this flag is set; once a non-marker token is produced it is cleared.
    at_line_start: bool,

    pub fn init(src: [:0]const u8) Tokenizer {
        return .{ .src = src, .pos = 0, .line = 1, .at_line_start = true };
    }

    // -- Public API -----------------------------------------------------------

    /// Return the next token.  Never fails — at end of input returns .eof.
    pub fn next(self: *Tokenizer) Token {
        // ts / tl are set in .start and used by .slash / scanText.
        var ts: u32 = 0;
        var tl: u32 = 0;

        state: switch (State.start) {
            .start => {
                // Skip leading whitespace at line start so that indented choices
                // and gathers are recognised correctly.  Mid-line whitespace is
                // significant (it stays part of text tokens).
                if (self.at_line_start) {
                    while (self.src[self.pos] == ' ' or self.src[self.pos] == '\t') {
                        self.pos += 1;
                    }
                }

                ts = self.pos;
                tl = self.line;

                switch (self.src[self.pos]) {
                    0 => return .{ .tag = .eof, .loc = .{ .start = ts, .end = ts }, .line = tl },

                    '\r' => {
                        self.pos += 1;
                        if (self.src[self.pos] == '\n') self.pos += 1;
                        self.line += 1;
                        self.at_line_start = true;
                        return .{ .tag = .newline, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    '\n' => {
                        self.pos += 1;
                        self.line += 1;
                        self.at_line_start = true;
                        return .{ .tag = .newline, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },

                    '{' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .left_brace, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    '}' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .right_brace, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    '[' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .left_bracket, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    ']' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .right_bracket, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    '#' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .hash, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    '|' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .pipe, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },
                    ':' => {
                        self.pos += 1;
                        self.at_line_start = false;
                        return .{ .tag = .colon, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                    },

                    '-' => {
                        self.pos += 1;
                        if (self.src[self.pos] == '>') {
                            self.pos += 1;
                            // Check for ->->
                            if (self.src[self.pos] == '-' and self.src[self.pos + 1] == '>') {
                                self.pos += 2;
                                self.at_line_start = false;
                                return .{ .tag = .divert_return, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                            }
                            self.at_line_start = false;
                            return .{ .tag = .divert_arrow, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        if (self.at_line_start) {
                            // Gather marker.  Keep at_line_start=true so that
                            // consecutive '-' chars are each emitted as gather.
                            return .{ .tag = .gather, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        // Bare '-' mid-line → accumulate as text.
                        return self.scanText(ts, tl);
                    },

                    '<' => {
                        self.pos += 1;
                        if (self.src[self.pos] == '-') {
                            self.pos += 1;
                            self.at_line_start = false;
                            return .{ .tag = .thread_start, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        // '<' as text char (e.g. '<>' glue stays in text).
                        return self.scanText(ts, tl);
                    },

                    '*' => {
                        if (self.at_line_start) {
                            self.pos += 1;
                            // Keep at_line_start so "* * choice" works.
                            return .{ .tag = .choice_once, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        return self.scanText(ts, tl);
                    },

                    '+' => {
                        if (self.at_line_start) {
                            self.pos += 1;
                            return .{ .tag = .choice_sticky, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        return self.scanText(ts, tl);
                    },

                    '~' => {
                        if (self.at_line_start) {
                            self.pos += 1;
                            self.at_line_start = false;
                            return .{ .tag = .logic_line, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        return self.scanText(ts, tl);
                    },

                    '=' => {
                        if (self.at_line_start) {
                            self.pos += 1;
                            var count: u8 = 1;
                            while (self.src[self.pos] == '=') {
                                self.pos += 1;
                                count += 1;
                            }
                            self.at_line_start = false;
                            const tag: TokenTag = if (count >= 2) .knot_marker else .stitch_marker;
                            return .{ .tag = tag, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
                        }
                        return self.scanText(ts, tl);
                    },

                    '/' => {
                        self.pos += 1;
                        continue :state .slash;
                    },

                    else => return self.scanText(ts, tl),
                }
            },

            .slash => {
                // ts/tl point to the leading '/' consumed in .start.
                if (self.src[self.pos] == '/') {
                    self.pos += 1;
                    continue :state .line_comment;
                }
                if (self.src[self.pos] == '*') {
                    self.pos += 1;
                    continue :state .block_comment;
                }
                // Bare '/' — include in text token.
                return self.scanText(ts, tl);
            },

            .line_comment => {
                // Consume characters until newline or EOF, then restart.
                // The newline itself is NOT consumed here so .start will emit
                // a newline token for it (preserving line structure).
                switch (self.src[self.pos]) {
                    0, '\n' => continue :state .start,
                    '\r' => {
                        // CRLF: skip the \r but leave \n for .start to emit.
                        self.pos += 1;
                        continue :state .start;
                    },
                    else => {
                        self.pos += 1;
                        continue :state .line_comment;
                    },
                }
            },

            .block_comment => {
                switch (self.src[self.pos]) {
                    0 => continue :state .start, // unterminated; best-effort
                    '\n' => {
                        self.line += 1;
                        self.pos += 1;
                        continue :state .block_comment;
                    },
                    '\r' => {
                        self.pos += 1;
                        if (self.src[self.pos] == '\n') {
                            self.line += 1;
                            self.pos += 1;
                        }
                        continue :state .block_comment;
                    },
                    '*' => {
                        self.pos += 1;
                        if (self.src[self.pos] == '/') {
                            self.pos += 1;
                            continue :state .start;
                        }
                        continue :state .block_comment;
                    },
                    else => {
                        self.pos += 1;
                        continue :state .block_comment;
                    },
                }
            },
        }

        comptime unreachable;
    }

    /// Accumulate a `text` token starting at `ts` (some chars may already
    /// have been consumed).  Stops before the next structural delimiter.
    fn scanText(self: *Tokenizer, ts: u32, tl: u32) Token {
        while (true) {
            switch (self.src[self.pos]) {
                // EOF or hard structural stops.
                0, '{', '}', '[', ']', '#', '|', '\n', '\r' => break,
                // Stop before -> but keep bare -.
                '-' => {
                    if (self.src[self.pos + 1] == '>') break;
                    self.pos += 1;
                },
                // Stop before <- but keep bare <.
                '<' => {
                    if (self.src[self.pos + 1] == '-') break;
                    self.pos += 1;
                },
                // Stop before // or /* comments.
                '/' => {
                    const p = self.src[self.pos + 1];
                    if (p == '/' or p == '*') break;
                    self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        self.at_line_start = false;
        return .{ .tag = .text, .loc = .{ .start = ts, .end = self.pos }, .line = tl };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");

fn readOriginalFixture(alloc: std.mem.Allocator, comptime rel: []const u8) ![:0]u8 {
    const path = "test/fixture/original/" ++ rel;
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(data);
    return alloc.dupeZ(u8, data);
}

/// Collect all tokens from a null-terminated source string (caller frees).
fn tokenizeAll(alloc: std.mem.Allocator, src: [:0]const u8) ![]Token {
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
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: Loc.slice" {
    var t = Tokenizer.init("Hello world");
    const tk = t.next();
    try testing.expectEqual(TokenTag.text, tk.tag);
    try testing.expectEqualStrings("Hello world", tk.loc.slice("Hello world"));
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
    const src = "-> knot";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings(" knot", text.loc.slice(src));
}

test "Compiler tokenizer: divert return ->->" {
    var t = Tokenizer.init("->->");
    try testing.expectEqual(TokenTag.divert_return, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: -> and ->-> are distinct" {
    const src = "-> ->";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    const mid = t.next();
    try testing.expectEqual(TokenTag.text, mid.tag);
    try testing.expectEqualStrings(" ", mid.loc.slice(src));
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: thread_start <-" {
    const src = "<- knot";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.thread_start, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: choice_once * at line start" {
    const src = "* choice text";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("choice text", text.loc.slice(src));
}

test "Compiler tokenizer: choice_sticky + at line start" {
    const src = "+ sticky";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.choice_sticky, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: nested choices * * preserve nesting" {
    const src = "* * nested";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("nested", text.loc.slice(src));
}

test "Compiler tokenizer: * in expression is plain text" {
    const src = "{2 * 3}";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.left_brace, t.next().tag);
    const expr = t.next();
    try testing.expectEqual(TokenTag.text, expr.tag);
    try testing.expect(std.mem.indexOf(u8, expr.loc.slice(src), "*") != null);
    try testing.expectEqual(TokenTag.right_brace, t.next().tag);
}

test "Compiler tokenizer: gather - at line start" {
    const src = "- gather";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("gather", text.loc.slice(src));
}

test "Compiler tokenizer: nested gathers - -" {
    var t = Tokenizer.init("- - nested");
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    try testing.expectEqual(TokenTag.gather, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: - in expression is plain text not gather" {
    const src = "{10 - 2}";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.left_brace, t.next().tag);
    const expr = t.next();
    try testing.expectEqual(TokenTag.text, expr.tag);
    try testing.expect(std.mem.indexOf(u8, expr.loc.slice(src), "-") != null);
    try testing.expectEqual(TokenTag.right_brace, t.next().tag);
}

test "Compiler tokenizer: divert arrow in mid-line text" {
    const src = "go -> target";
    var t = Tokenizer.init(src);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("go ", text.loc.slice(src));
    try testing.expectEqual(TokenTag.divert_arrow, t.next().tag);
    const target = t.next();
    try testing.expectEqual(TokenTag.text, target.tag);
    try testing.expectEqualStrings(" target", target.loc.slice(src));
}

test "Compiler tokenizer: logic_line ~ at line start" {
    const src = "~ x = 1";
    var t = Tokenizer.init(src);
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
    const src = "= stitch_name";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.stitch_marker, t.next().tag);
    try testing.expectEqual(TokenTag.text, t.next().tag);
}

test "Compiler tokenizer: line_comment // skipped" {
    const src = "// this is a comment\ntext";
    var t = Tokenizer.init(src);
    const first = t.next();
    try testing.expectEqual(TokenTag.newline, first.tag);
    const second = t.next();
    try testing.expectEqual(TokenTag.text, second.tag);
    try testing.expectEqualStrings("text", second.loc.slice(src));
}

test "Compiler tokenizer: inline comment // stops text token" {
    const src = "Hello world // ignored\n";
    var t = Tokenizer.init(src);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("Hello world ", text.loc.slice(src));
    try testing.expectEqual(TokenTag.newline, t.next().tag);
    try testing.expectEqual(TokenTag.eof, t.next().tag);
}

test "Compiler tokenizer: block_comment /* */ skipped" {
    const src = "before /* block\ncomment */ after";
    var t = Tokenizer.init(src);
    const before = t.next();
    try testing.expectEqual(TokenTag.text, before.tag);
    try testing.expectEqualStrings("before ", before.loc.slice(src));
    const after = t.next();
    try testing.expectEqual(TokenTag.text, after.tag);
    try testing.expectEqualStrings(" after", after.loc.slice(src));
}

test "Compiler tokenizer: glue <> is plain text" {
    const src = "text <> more";
    var t = Tokenizer.init(src);
    const all = t.next();
    try testing.expectEqual(TokenTag.text, all.tag);
    try testing.expect(std.mem.indexOf(u8, all.loc.slice(src), "<>") != null);
}

test "Compiler tokenizer: indented choice has leading whitespace skipped" {
    const src = "    * indented";
    var t = Tokenizer.init(src);
    try testing.expectEqual(TokenTag.choice_once, t.next().tag);
    const text = t.next();
    try testing.expectEqual(TokenTag.text, text.tag);
    try testing.expectEqualStrings("indented", text.loc.slice(src));
}

test "Compiler tokenizer: multiline sequence" {
    const src = "line one\n* choice\n- gather\n-> END\n";
    const alloc = testing.allocator;
    const tokens = try tokenizeAll(alloc, src);
    defer alloc.free(tokens);

    try testing.expectEqual(TokenTag.text, tokens[0].tag);
    try testing.expectEqual(TokenTag.newline, tokens[1].tag);
    try testing.expectEqual(TokenTag.choice_once, tokens[2].tag);
    try testing.expectEqual(TokenTag.text, tokens[3].tag);
    try testing.expectEqual(TokenTag.newline, tokens[4].tag);
    try testing.expectEqual(TokenTag.gather, tokens[5].tag);
    try testing.expectEqual(TokenTag.text, tokens[6].tag);
    try testing.expectEqual(TokenTag.newline, tokens[7].tag);
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

    const t0 = t.next();
    try testing.expectEqual(TokenTag.text, t0.tag);
    try testing.expectEqualStrings("Hello world", t0.loc.slice(src));

    const t1 = t.next();
    const last = if (t1.tag == .newline) t.next() else t1;
    try testing.expectEqual(TokenTag.eof, last.tag);
}

test "Compiler tokenizer: arithmetic.ink" {
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
                const text = tk.loc.slice(src);
                if (std.mem.indexOfAny(u8, text, "0123456789") != null)
                    found_number = true;
                if (std.mem.indexOfAny(u8, text, "+-*/%") != null or
                    std.mem.indexOf(u8, text, "mod") != null)
                    found_operator = true;
            },
            else => {},
        }
    }

    try testing.expectEqual(@as(u32, 7), left_count);
    try testing.expectEqual(@as(u32, 7), right_count);
    try testing.expect(found_number);
    try testing.expect(found_operator);
}
