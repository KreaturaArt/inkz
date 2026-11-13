//! The compiler's tokenizer (plan §4.11, P7.1). ink's grammar is context-sensitive, so the
//! parser asks for one token at a time in the mode it is in:
//! - `content`: text runs and the characters that end them, as InkParser's ContentText does
//!   (`{ } | # \ newline`, and `->`, `<-`, `<>`); `content_choice` adds `[ ]` and
//!   `content_string` adds `"`;
//! - `expression`: identifiers (any run of ink's identifier characters, digits included:
//!   the parser decides what is a number), operators, punctuation and whitespace;
//! - `rest_of_line`: everything up to the newline (INCLUDE paths, author warnings).
//! Whitespace and newlines are tokens, because ink's rules care where they are.
//!
//! Comments are removed first, as ink's CommentEliminator does (textually, keeping
//! newlines), into a buffer the caller provides. Tokens store `start` and `end` (T2
//! deviation). The scanner is a labeled switch (the D10 exception).

const std = @import("std");
const assert = std.debug.assert;

pub const Tag = enum(u8) {
    eof,
    newline,
    /// Spaces and tabs.
    whitespace,
    /// Content text; `escape` is `\` and the character after it.
    text,
    escape,
    /// A run of identifier characters (letters, digits, `_`, ink's Unicode ranges).
    word,
    brace_open,
    brace_close,
    bracket_open,
    bracket_close,
    paren_open,
    paren_close,
    pipe,
    hash,
    quote,
    divert,
    thread,
    glue,
    comma,
    dot,
    colon,
    tilde,
    dollar,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    question,
    equal,
    bang,
    less,
    greater,
    ampersand,
    equal_equal,
    bang_equal,
    less_equal,
    greater_equal,
    and_and,
    or_or,
    bang_question,
    plus_plus,
    minus_minus,
    plus_equal,
    minus_equal,
    /// A character no rule of the mode accepts.
    invalid,
};

pub const Mode = enum { content, content_choice, content_string, expression, rest_of_line };

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub fn slice(token: Token, source: []const u8) []const u8 {
        assert(source.len < std.math.maxInt(u32));
        assert(token.start <= token.end and token.end <= source.len);
        return source[token.start..token.end];
    }
};

/// ink's CommentEliminator: `//` to the end of the line and `/* ... */` are removed, a block
/// comment leaving its newlines. Writes into `out` (at least `source.len` bytes) and returns
/// the cleaned text.
pub fn eliminate_comments(source: []const u8, out: []u8) []const u8 {
    assert(out.len >= source.len);
    var read: usize = 0;
    var written: usize = 0;
    while (read < source.len) {
        if (std.mem.startsWith(u8, source[read..], "//")) {
            read = std.mem.indexOfAnyPos(u8, source, read, "\n\r") orelse source.len;
            continue;
        }
        if (std.mem.startsWith(u8, source[read..], "/*")) {
            const close = std.mem.indexOfPos(u8, source, read + 2, "*/");
            const end = if (close) |at| at + 2 else source.len;
            const newlines = std.mem.count(u8, source[read..end], "\n");
            @memset(out[written..][0..newlines], '\n');
            written += newlines;
            read = end;
            continue;
        }
        out[written] = source[read];
        written += 1;
        read += 1;
    }
    assert(written <= read);
    return out[0..written];
}

pub const Tokenizer = struct {
    source: []const u8,
    at: u32 = 0,

    pub fn init(source: []const u8) Tokenizer {
        assert(source.len < std.math.maxInt(u32));
        const tokenizer: Tokenizer = .{ .source = source };
        assert(tokenizer.at == 0);
        return tokenizer;
    }

    /// The next token in `mode`; at the end, `eof` at `source.len`, again and again.
    pub fn next(tokenizer: *Tokenizer, mode: Mode) Token {
        assert(tokenizer.at <= tokenizer.source.len);
        const start = tokenizer.at;
        const tag = if (start == tokenizer.source.len) Tag.eof else switch (mode) {
            .content, .content_choice, .content_string => tokenizer.content(mode),
            .expression => tokenizer.expression(),
            .rest_of_line => tokenizer.rest_of_line(),
        };
        const token: Token = .{ .tag = tag, .start = start, .end = tokenizer.at };
        // Every token but eof consumes input: the stream ends.
        assert(token.tag == .eof or token.end > token.start);
        return token;
    }

    fn peek(tokenizer: *const Tokenizer, offset: u32) u8 {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(offset <= 2);
        const at = tokenizer.at + offset;
        return if (at < tokenizer.source.len) tokenizer.source[at] else 0;
    }

    /// Newlines (`\n`, `\r\n`), whitespace and the shared punctuation of every mode.
    fn common(tokenizer: *Tokenizer) ?Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.at < tokenizer.source.len);
        const character = tokenizer.peek(0);
        if (character == '\n' or (character == '\r' and tokenizer.peek(1) == '\n')) {
            tokenizer.at += if (character == '\r') 2 else 1;
            return .newline;
        }
        if (character == ' ' or character == '\t') {
            while (tokenizer.peek(0) == ' ' or tokenizer.peek(0) == '\t') tokenizer.at += 1;
            return .whitespace;
        }
        return null;
    }

    fn content(tokenizer: *Tokenizer, mode: Mode) Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(mode == .content or mode == .content_choice or mode == .content_string);
        if (tokenizer.common()) |tag| {
            // Whitespace is part of content text, unless it is a line's end.
            const inline_space = tag == .whitespace and !tokenizer.at_line_end();
            if (inline_space) return tokenizer.text_from_here(mode);
            return tag;
        }
        const single: ?Tag = switch (tokenizer.peek(0)) {
            '{' => .brace_open,
            '}' => .brace_close,
            '|' => .pipe,
            '#' => .hash,
            '[' => if (mode == .content_choice) .bracket_open else null,
            ']' => if (mode == .content_choice) .bracket_close else null,
            '"' => if (mode == .content_string) .quote else null,
            else => null,
        };
        if (single) |tag| {
            tokenizer.at += 1;
            return tag;
        }
        if (tokenizer.peek(0) == '\\') {
            tokenizer.at += @min(2, tokenizer.source.len - tokenizer.at);
            return .escape;
        }
        if (tokenizer.arrow()) |tag| return tag;
        if (tokenizer.peek(0) == '\r') {
            // A lone `\r` is text in ink only when not before `\n`; it ends text runs.
            tokenizer.at += 1;
            return .text;
        }
        return tokenizer.text_from_here(mode);
    }

    /// After whitespace: whether only whitespace remains before the newline or the end
    /// (ink trims it; the parser sees it as `whitespace` then `newline`).
    fn at_line_end(tokenizer: *const Tokenizer) bool {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.source.len < std.math.maxInt(u32));
        const character = tokenizer.peek(0);
        const crlf = character == '\r' and tokenizer.peek(1) == '\n';
        // `peek` gives 0 at the end; a 0 byte inside the source is text.
        return character == '\n' or tokenizer.at == tokenizer.source.len or crlf;
    }

    fn arrow(tokenizer: *Tokenizer) ?Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.at < tokenizer.source.len);
        const pair = [2]u8{ tokenizer.peek(0), tokenizer.peek(1) };
        const tag: Tag = if (std.mem.eql(u8, &pair, "->"))
            .divert
        else if (std.mem.eql(u8, &pair, "<-"))
            .thread
        else if (std.mem.eql(u8, &pair, "<>"))
            .glue
        else
            return null;
        tokenizer.at += 2;
        return tag;
    }

    /// Text up to the next character that ends content in `mode`, or an arrow or glue.
    fn text_from_here(tokenizer: *Tokenizer, mode: Mode) Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(mode != .expression and mode != .rest_of_line);
        const ends: []const u8 = switch (mode) {
            .content => "{}|\n\r\\#",
            .content_choice => "{}|\n\r\\#[]",
            .content_string => "{}|\n\r\\#\"",
            else => unreachable,
        };
        scan: switch (tokenizer.peek(0)) {
            0 => if (tokenizer.at < tokenizer.source.len) {
                // A 0 byte inside the source is text; only the end stops here.
                tokenizer.at += 1;
                continue :scan tokenizer.peek(0);
            },
            '-', '<' => {
                const pair = [2]u8{ tokenizer.peek(0), tokenizer.peek(1) };
                const stops = std.mem.eql(u8, &pair, "->") or std.mem.eql(u8, &pair, "<-") or
                    std.mem.eql(u8, &pair, "<>");
                if (stops) break :scan;
                tokenizer.at += 1;
                continue :scan tokenizer.peek(0);
            },
            ' ', '\t' => {
                // Trailing whitespace before a line end isn't part of the text run.
                const saved = tokenizer.at;
                while (tokenizer.peek(0) == ' ' or tokenizer.peek(0) == '\t') tokenizer.at += 1;
                if (tokenizer.at_line_end()) {
                    tokenizer.at = saved;
                    break :scan;
                }
                continue :scan tokenizer.peek(0);
            },
            else => |character| {
                if (std.mem.indexOfScalar(u8, ends, character) != null) break :scan;
                tokenizer.at += 1;
                continue :scan tokenizer.peek(0);
            },
        }
        return .text;
    }

    fn expression(tokenizer: *Tokenizer) Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.at < tokenizer.source.len);
        if (tokenizer.common()) |tag| return tag;
        if (identifier_length(tokenizer.source[tokenizer.at..])) |length| {
            tokenizer.at += length;
            return .word;
        }
        if (tokenizer.arrow()) |tag| {
            // In expressions `<-` is `<` then `-`, and `<>` is `<` then `>`.
            if (tag == .divert) return tag;
            tokenizer.at -= 1;
            return .less;
        }
        return tokenizer.operator();
    }

    const operators = [_]struct { []const u8, Tag }{
        .{ "==", .equal_equal },   .{ "!=", .bang_equal },  .{ "<=", .less_equal },
        .{ ">=", .greater_equal }, .{ "&&", .and_and },     .{ "||", .or_or },
        .{ "!?", .bang_question }, .{ "++", .plus_plus },   .{ "--", .minus_minus },
        .{ "+=", .plus_equal },    .{ "-=", .minus_equal }, .{ "{", .brace_open },
        .{ "}", .brace_close },    .{ "[", .bracket_open }, .{ "]", .bracket_close },
        .{ "(", .paren_open },     .{ ")", .paren_close },  .{ "|", .pipe },
        .{ "#", .hash },           .{ "\"", .quote },       .{ ",", .comma },
        .{ ".", .dot },            .{ ":", .colon },        .{ "~", .tilde },
        .{ "$", .dollar },         .{ "+", .plus },         .{ "-", .minus },
        .{ "*", .star },           .{ "/", .slash },        .{ "%", .percent },
        .{ "^", .caret },          .{ "?", .question },     .{ "=", .equal },
        .{ "!", .bang },           .{ "<", .less },         .{ ">", .greater },
        .{ "&", .ampersand },
    };

    fn operator(tokenizer: *Tokenizer) Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.at < tokenizer.source.len);
        const rest = tokenizer.source[tokenizer.at..];
        for (operators) |entry| {
            if (!std.mem.startsWith(u8, rest, entry[0])) continue;
            tokenizer.at += @intCast(entry[0].len);
            return entry[1];
        }
        // Not ink: one UTF-8 sequence (or byte) is invalid.
        const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        tokenizer.at += @min(length, @as(u32, @intCast(rest.len)));
        return .invalid;
    }

    fn rest_of_line(tokenizer: *Tokenizer) Tag {
        assert(tokenizer.at <= tokenizer.source.len);
        assert(tokenizer.at < tokenizer.source.len);
        if (tokenizer.common()) |tag| {
            if (tag == .newline) return tag;
        }
        while (!tokenizer.at_line_end()) tokenizer.at += 1;
        return .text;
    }
};

/// The length of the identifier at the start of `text`: ink's identifier characters (ASCII
/// letters, digits, `_`, and its Unicode ranges), or null.
pub fn identifier_length(text: []const u8) ?u32 {
    assert(text.len < std.math.maxInt(u32));
    assert(@sizeOf(u21) <= 4);
    var at: u32 = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch break;
        if (at + length > text.len) break;
        const code = std.unicode.utf8Decode(text[at..][0..length]) catch break;
        if (!is_identifier_character(code)) break;
        at += length;
    }
    return if (at == 0) null else at;
}

/// InkParser's identifier character set: `A-Z a-z 0-9 _` and the ranges of
/// InkParser_CharacterRanges.cs.
pub fn is_identifier_character(code: u21) bool {
    assert(code <= 0x10FFFF);
    assert(@sizeOf(u21) <= 4);
    if (code < 0x80) return std.ascii.isAlphanumeric(@intCast(code)) or code == '_';
    const ranges = [_][2]u21{
        .{ 0x0080, 0x00FF }, .{ 0x0100, 0x017F }, .{ 0x0180, 0x024F }, .{ 0x0370, 0x03FF },
        .{ 0x0400, 0x04FF }, .{ 0x0530, 0x058F }, .{ 0x0590, 0x05FF }, .{ 0x0600, 0x06FF },
        .{ 0xAC00, 0xD7AF }, .{ 0x4E00, 0x9FFF }, .{ 0x3041, 0x3096 }, .{ 0x30A0, 0x30FC },
    };
    for (ranges) |range| {
        if (code >= range[0] and code <= range[1]) return !is_excluded(code);
    }
    return false;
}

/// The characters InkParser_CharacterRanges.cs excludes from its ranges.
fn is_excluded(code: u21) bool {
    assert(code >= 0x80);
    assert(code <= 0x10FFFF);
    return switch (code) {
        0x0378...0x0385, 0x0374, 0x0375, 0x0387, 0x038B, 0x038D, 0x03A2 => true,
        0x0482...0x0489 => true,
        0x0530, 0x0557...0x0560, 0x0588...0x058E => true,
        else => false,
    };
}

/// Line starts, for `line:column` in diagnostics.
pub const LineTable = struct {
    starts: []const u32,

    /// Fills `storage` with the offsets where lines start; returns the table.
    pub fn build(source: []const u8, storage: []u32) error{TooManyLines}!LineTable {
        assert(source.len < std.math.maxInt(u32));
        assert(storage.len > 0);
        storage[0] = 0;
        var count: u32 = 1;
        for (source, 0..) |character, position| {
            if (character != '\n') continue;
            if (count == storage.len) return error.TooManyLines;
            storage[count] = @intCast(position + 1);
            count += 1;
        }
        return .{ .starts = storage[0..count] };
    }

    /// The 1-based line and column of `offset`.
    pub fn locate(table: LineTable, offset: u32) struct { line: u32, column: u32 } {
        assert(table.starts[0] == 0);
        assert(table.starts.len > 0);
        var low: usize = 0;
        var high: usize = table.starts.len;
        while (high - low > 1) {
            const middle = (low + high) / 2;
            if (table.starts[middle] <= offset) low = middle else high = middle;
        }
        return .{ .line = @intCast(low + 1), .column = offset - table.starts[low] + 1 };
    }
};

fn expect_tokens(source: []const u8, mode: Mode, expected: []const Tag) !void {
    assert(expected.len > 0);
    assert(source.len > 0);
    var tokenizer: Tokenizer = .init(source);
    for (expected) |tag| {
        const token = tokenizer.next(mode);
        std.testing.expectEqual(tag, token.tag) catch |err| {
            std.debug.print("at {d}: {s}\n", .{ token.start, token.slice(source) });
            return err;
        };
    }
    try std.testing.expectEqual(Tag.eof, tokenizer.next(mode).tag);
}

test "content stops where ink's ContentText does" {
    try expect_tokens("Hello -> knot\n", .content, &.{ .text, .divert, .text, .newline });
    try expect_tokens("a {x} b | c # tag", .content, &.{
        .text,
        .brace_open,
        .text,
        .brace_close,
        .text,
        .pipe,
        .text,
        .hash,
        .text,
    });
    try expect_tokens("x - y < z <> w <- t", .content, &.{ .text, .glue, .text, .thread, .text });
    try expect_tokens("\\{ not logic", .content, &.{ .escape, .text });
    try expect_tokens("choice [only] rest", .content_choice, &.{
        .text,
        .bracket_open,
        .text,
        .bracket_close,
        .text,
    });
    try expect_tokens("in \"string\"", .content_string, &.{ .text, .quote, .text, .quote });
    try expect_tokens("trailing   \n", .content, &.{ .text, .whitespace, .newline });
}

test "expressions lex identifiers, operators and whitespace" {
    try expect_tokens("x >= 2 and not y", .expression, &.{
        .word,
        .whitespace,
        .greater_equal,
        .whitespace,
        .word,
        .whitespace,
        .word,
        .whitespace,
        .word,
        .whitespace,
        .word,
    });
    try expect_tokens("a<-b", .expression, &.{ .word, .less, .minus, .word });
    try expect_tokens("-> knot.stitch", .expression, &.{
        .divert,
        .whitespace,
        .word,
        .dot,
        .word,
    });
    try expect_tokens("count++ != 1.5", .expression, &.{
        .word,
        .plus_plus,
        .whitespace,
        .bang_equal,
        .whitespace,
        .word,
        .dot,
        .word,
    });
    try expect_tokens("café", .expression, &.{.word});
    try expect_tokens("@", .expression, &.{.invalid});
}

test "a 0 byte inside the source is text, not the end" {
    // Found by the tokenizer's fuzz target (P11.3): `peek` gives 0 at the end, and an
    // embedded 0 made an empty text token.
    try expect_tokens("a\x00b\n", .content, &.{ .text, .newline });
    try expect_tokens("\x00", .content_string, &.{.text});
    try expect_tokens("x \x00\n", .rest_of_line, &.{ .text, .newline });
    try expect_tokens("\x00", .expression, &.{.invalid});
}

test "comments are removed as ink's CommentEliminator removes them" {
    var buffer: [64]u8 = undefined;
    const cleaned = eliminate_comments("a // note\nb /* x\ny */ c\n", &buffer);
    try std.testing.expectEqualStrings("a \nb \n c\n", cleaned);
}

test "the line table locates offsets" {
    var storage: [8]u32 = undefined;
    const table = try LineTable.build("ab\ncd\n\nef", &storage);
    try std.testing.expectEqual(@as(u32, 4), @as(u32, @intCast(table.starts.len)));
    const located = table.locate(4);
    try std.testing.expectEqual(@as(u32, 2), located.line);
    try std.testing.expectEqual(@as(u32, 2), located.column);
}

/// Tokenizes `source` line by line as the parser would at a first approximation: logic,
/// declaration and knot lines in expression mode, other lines in content mode. Returns
/// how many invalid tokens it met, and checks the stream ends with eof at the end.
fn tokenize_by_lines(source: []const u8) !u32 {
    assert(source.len < std.math.maxInt(u32));
    var tokenizer: Tokenizer = .init(source);
    var invalid: u32 = 0;
    var at_line_start = true;
    var mode: Mode = .content;
    var tokens: u32 = 0;
    while (true) : (tokens += 1) {
        // The token count is bounded by the length plus the final eof.
        assert(tokens <= source.len + 1);
        if (at_line_start) mode = line_mode(source[tokenizer.at..]);
        const token = tokenizer.next(mode);
        if (token.tag == .eof) {
            try std.testing.expectEqual(@as(u32, @intCast(source.len)), token.start);
            return invalid;
        }
        if (token.tag == .invalid) invalid += 1;
        at_line_start = token.tag == .newline;
    }
}

fn line_mode(line: []const u8) Mode {
    assert(line.len < std.math.maxInt(u32));
    assert(@sizeOf(Mode) == 1);
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const logic = [_][]const u8{ "~", "=", "VAR ", "CONST ", "LIST ", "EXTERNAL " };
    for (logic) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return .expression;
    }
    if (std.mem.startsWith(u8, trimmed, "INCLUDE ")) return .rest_of_line;
    return .content;
}

test "every ink fixture tokenizes without invalid tokens" {
    // Goal: P7.1. Method: each .ink under test/, comments removed, tokenized by lines.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, "test", .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    var files: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ink")) continue;
        const source = try directory.readFileAlloc(io, entry.path, arena, .limited(16 << 20));
        const cleaned = eliminate_comments(source, try arena.alloc(u8, source.len));
        const invalid = try tokenize_by_lines(cleaned);
        std.testing.expectEqual(@as(u32, 0), invalid) catch |err| {
            std.debug.print("{s}: {d} invalid tokens\n", .{ entry.path, invalid });
            return err;
        };
        files += 1;
    }
    try std.testing.expect(files > 100);
}
