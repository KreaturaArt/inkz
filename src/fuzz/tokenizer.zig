//! Fuzz target for the tokenizer (plan P11.3): bytes weighted toward ink's punctuation,
//! keywords' letters and multi-byte UTF-8 (and 0 bytes), read in fuzzer-chosen modes, with
//! rewinds as the parser's checkpoints make them.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const tokenizer_module = @import("../compiler/tokenizer.zig");
const Tokenizer = tokenizer_module.Tokenizer;
const Token = tokenizer_module.Token;
const Mode = tokenizer_module.Mode;

const input_bytes_max = 4096;
const history_max = 64;

const ink_weights = [_]Smith.Weight{
    .rangeAtMost(u8, 0, 255, 1),
    .rangeAtMost(u8, 'a', 'z', 4),
    .rangeAtMost(u8, '0', '9', 4),
    .rangeAtMost(u8, '!', '/', 12),
    .rangeAtMost(u8, ':', '@', 12),
    .rangeAtMost(u8, '[', '`', 12),
    .rangeAtMost(u8, '{', '~', 24),
    .value(u8, ' ', 64),
    .value(u8, '\t', 8),
    .value(u8, '\n', 48),
    .value(u8, '\r', 8),
    // UTF-8: lead bytes of two- and three-byte sequences, and continuation bytes.
    .rangeAtMost(u8, 0xC2, 0xD7, 2),
    .rangeAtMost(u8, 0xE3, 0xEA, 2),
    .rangeAtMost(u8, 0x80, 0xBF, 2),
};

const Read = struct { mode: Mode, token: Token };

/// Each token starts where the last one ended, and only eof is empty; eof comes at the end,
/// again and again. Reading from an earlier token's start in its mode gives the same token.
fn tokenize(_: void, smith: *Smith) anyerror!void {
    var source_buffer: [input_bytes_max]u8 = undefined;
    const source = source_buffer[0..smith.sliceWeightedBytes(&source_buffer, &ink_weights)];
    var tokenizer: Tokenizer = .init(source);
    var history: [history_max]Read = undefined;
    var history_count: u32 = 0;
    var written: u32 = 0;
    var rewinds: u32 = 0;
    // Every token but eof consumes a byte, so eof comes within `source.len + 1` reads.
    var reads: u32 = 0;
    while (reads <= source.len) {
        if (history_count > 0 and rewinds < history_max and smith.boolWeighted(15, 1)) {
            rewinds += 1;
            // A parser checkpoint: read an earlier token again, then go back to here.
            const here = tokenizer.at;
            const earlier = history[smith.index(history_count)];
            tokenizer.at = earlier.token.start;
            const again = tokenizer.next(earlier.mode);
            assert(std.meta.eql(again, earlier.token));
            tokenizer.at = here;
            continue;
        }
        const mode = smith.value(Mode);
        const start = tokenizer.at;
        const token = tokenizer.next(mode);
        reads += 1;
        check_token(source, start, token);
        if (token.tag == .eof) {
            assert(tokenizer.next(smith.value(Mode)).tag == .eof);
            return;
        }
        history[written % history_max] = .{ .mode = mode, .token = token };
        written += 1;
        history_count = @min(written, history_max);
    }
    return error.TokenizerDidNotTerminate;
}

fn check_token(source: []const u8, start: u32, token: Token) void {
    assert(token.start == start);
    assert(token.start <= token.end and token.end <= source.len);
    const text = token.slice(source);
    switch (token.tag) {
        .eof => assert(token.start == source.len),
        .newline => assert(std.mem.eql(u8, text, "\n") or std.mem.eql(u8, text, "\r\n")),
        .whitespace => assert(std.mem.trim(u8, text, " \t").len == 0 and text.len > 0),
        .word => assert(tokenizer_module.identifier_length(text) != null),
        else => assert(text.len > 0),
    }
}

test "fuzz: the tokenizer's tokens are contiguous and repeatable" {
    try std.testing.fuzz({}, tokenize, .{ .corpus = &.{
        "Hello, world.\n",
        "* [Choice] Text -> knot\n=== knot ===\n{x > 2: big|small} <> glue # tag\n",
        "~ x = (a + 1.5) * \"str\" != b && c || !d\n",
        "VAR é = 3\nINCLUDE file.ink\n\r\n\t",
    } });
}
