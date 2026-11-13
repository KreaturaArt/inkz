//! Character classes the grammar scans with: ink's comment removal and identifier characters,
//! and line and column numbers. The grammar reads characters itself, so there is no token
//! stream.

const std = @import("std");
const assert = std.debug.assert;

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

/// The line and column (from 1) of `offset` in `text`.
pub fn line_and_column(text: []const u8, offset: u32) struct { line: u32, column: u32 } {
    assert(offset <= text.len);
    const before = text[0..offset];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |at| at + 1 else 0;
    return .{
        .line = @intCast(std.mem.count(u8, before, "\n") + 1),
        .column = @intCast(offset - line_start + 1),
    };
}

test "line_and_column counts from one" {
    // Diagnostics positions: offsets at the start, mid-line and after a newline.
    try std.testing.expectEqual(@as(u32, 1), line_and_column("ab\ncd", 0).column);
    try std.testing.expectEqual(@as(u32, 2), line_and_column("ab\ncd", 4).line);
    try std.testing.expectEqual(@as(u32, 2), line_and_column("ab\ncd", 4).column);
}

test "comments are removed as ink's CommentEliminator removes them" {
    var buffer: [64]u8 = undefined;
    const cleaned = eliminate_comments("a // note\nb /* x\ny */ c\n", &buffer);
    try std.testing.expectEqualStrings("a \nb \n c\n", cleaned);
}

test "identifiers are ink's identifier characters" {
    try std.testing.expectEqual(@as(?u32, 5), identifier_length("knot_ rest"));
    try std.testing.expectEqual(@as(?u32, 4), identifier_length("Ωμέγα"[0..4]));
    try std.testing.expectEqual(@as(?u32, null), identifier_length("-> x"));
    try std.testing.expect(!is_identifier_character(0x0378));
}
