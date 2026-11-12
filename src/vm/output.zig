//! The output stream (plan §4.5, P4.5), ported from ink's StoryState.cs: what the story has
//! printed since the last line was taken, with glue, `str` markers and tags.
//!
//! An item is 12 bytes. Text items are slices of a string (the program pool or the heap), so
//! splitting off leading and trailing whitespace allocates nothing; heap references in items
//! are compaction roots. `str` positions are kept on a mark stack, so whether the story is
//! evaluating a string is O(1).
//!
//! `strings` everywhere is an accessor with `get(StringReference) []const u8`.

const std = @import("std");
const assert = std.debug.assert;
const limits = @import("../core/limits.zig");
const fault = @import("../core/fault.zig");
const BoundedStack = @import("../core/bounded_stack.zig").BoundedStack;
const value_module = @import("value.zig");
const call_stack = @import("call_stack.zig");
const StringReference = value_module.StringReference;
const Frame = call_stack.Frame;

pub const Kind = enum(u8) { text, glue, begin_string, begin_tag, end_tag, tag };

/// How a text item reads, as ink's StringValue classifies it.
pub const Class = enum(u8) {
    newline,
    /// Only spaces and tabs, or empty.
    inline_whitespace,
    non_whitespace,

    pub fn of(text: []const u8) Class {
        assert(text.len < 1 << 20);
        if (std.mem.eql(u8, text, "\n")) return .newline;
        for (text) |character| {
            if (character != ' ' and character != '\t') return .non_whitespace;
        }
        assert(std.mem.indexOfScalar(u8, text, '\n') == null);
        return .inline_whitespace;
    }
};

pub const Item = struct {
    /// The string this item reads from, for `text` and `tag`.
    string: StringReference,
    start: u32,
    kind: Kind,
    class: Class,
    length: u16,

    pub fn bytes(item: Item, strings: anytype) []const u8 {
        assert(item.kind == .text or item.kind == .tag);
        const whole = strings.get(item.string);
        assert(item.start + item.length <= whole.len);
        return whole[item.start..][0..item.length];
    }

    pub fn command(kind: Kind) Item {
        assert(kind != .text and kind != .tag);
        const item: Item = .{
            .string = @fromBackingInt(@intCast(0)),
            .start = 0,
            .kind = kind,
            .class = .non_whitespace,
            .length = 0,
        };
        assert(item.length == 0);
        return item;
    }
};

comptime {
    assert(@sizeOf(Item) == limits.element_bytes.output_item);
}

/// `functionStartInOutputStream` of a frame that has none (ink's -1).
pub const no_function_start = std.math.maxInt(u32);

pub const Error = error{ OutputLimit, TextTooLong };

pub const Output = struct {
    items: BoundedStack(Item),
    string_marks: BoundedStack(u32),

    pub const Fault = enum { ok, storage, mark_not_begin_string, marks_unordered };

    pub fn init(items: []Item, marks: []u32) Output {
        assert(items.len > 0);
        assert(marks.len > 0);
        return .{ .items = .init(items), .string_marks = .init(marks) };
    }

    pub fn clear(output: *Output) void {
        assert(output.items.buffer.len > 0);
        output.items.clear();
        output.string_marks.clear();
        assert(output.items.is_empty());
    }

    pub fn in_string_evaluation(output: *const Output) bool {
        assert(output.string_marks.count <= output.string_marks.buffer.len);
        const result = output.string_marks.count > 0;
        assert(!result or output.items.count > 0);
        return result;
    }

    /// ink's PushToOutputStream for a slice of `string`: text containing newlines at its head
    /// or tail is split into whitespace, newline and inner pieces first.
    pub fn push_text(
        output: *Output,
        strings: anytype,
        frames: []Frame,
        string: StringReference,
        start: u32,
        length: u32,
    ) Error!void {
        assert(frames.len > 0);
        const text = strings.get(string)[start..][0..length];
        var pieces: [5]Piece = undefined;
        const count = split_head_tail_whitespace(text, &pieces);
        if (count == 0) return output.push_text_piece(strings, frames, string, start, length);
        for (pieces[0..count]) |piece| {
            try output.push_text_piece(strings, frames, string, start + piece.start, piece.length);
        }
        assert(count <= pieces.len);
    }

    fn push_text_piece(
        output: *Output,
        strings: anytype,
        frames: []Frame,
        string: StringReference,
        start: u32,
        length: u32,
    ) Error!void {
        assert(frames.len > 0);
        if (length > std.math.maxInt(u16)) return error.TextTooLong;
        const text = strings.get(string)[start..][0..length];
        const item: Item = .{
            .string = string,
            .start = start,
            .kind = .text,
            .class = Class.of(text),
            .length = @intCast(length),
        };
        if (!output.should_include_text(frames, item)) return;
        output.items.push(item) catch return error.OutputLimit;
        assert(output.items.count > 0);
    }

    /// ink's PushToOutputStreamIndividual for text: glue and function starts can swallow it.
    fn should_include_text(output: *Output, frames: []Frame, item: Item) bool {
        assert(frames.len > 0);
        assert(item.kind == .text);
        var function_trim: ?u32 = null;
        const current = frames[frames.len - 1];
        if (current.kind == .function and current.function_start_in_output != no_function_start) {
            function_trim = current.function_start_in_output;
        }
        var glue_trim: ?u32 = null;
        const items = output.items.slice();
        var position = items.len;
        while (position > 0) {
            position -= 1;
            if (items[position].kind == .glue) {
                glue_trim = @intCast(position);
                break;
            }
            if (items[position].kind == .begin_string) {
                if (function_trim) |trim| {
                    if (position >= trim) function_trim = null;
                }
                break;
            }
        }
        const trimming = glue_trim != null or function_trim != null;
        if (trimming) {
            if (item.class == .newline) return false;
            if (item.class == .non_whitespace) {
                if (glue_trim != null) output.remove_existing_glue();
                if (function_trim != null) clear_function_starts(frames);
            }
            return true;
        }
        if (item.class == .newline) {
            if (output.ends_in_newline() or !output.contains_content()) return false;
        }
        assert(item.kind == .text);
        return true;
    }

    /// Once real text is printed, enclosing functions no longer trim leading whitespace.
    fn clear_function_starts(frames: []Frame) void {
        assert(frames.len > 0);
        var position = frames.len;
        while (position > 0) {
            position -= 1;
            if (frames[position].kind != .function) break;
            frames[position].function_start_in_output = no_function_start;
        }
        assert(frames[frames.len - 1].kind != .function or
            frames[frames.len - 1].function_start_in_output == no_function_start);
    }

    /// Glue: newlines and whitespace after the last real text are removed, then the glue goes in.
    pub fn push_glue(output: *Output) Error!void {
        assert(output.items.count <= output.items.buffer.len);
        output.trim_newlines();
        output.items.push(.command(.glue)) catch return error.OutputLimit;
        assert(output.items.peek().?.kind == .glue);
    }

    /// `str`, `#` and `/#` markers.
    pub fn push_command(output: *Output, kind: Kind) Error!void {
        assert(kind == .begin_string or kind == .begin_tag or kind == .end_tag);
        if (kind == .begin_string) {
            output.string_marks.push(output.items.count) catch return error.OutputLimit;
        }
        output.items.push(.command(kind)) catch return error.OutputLimit;
        assert(output.items.count > 0);
    }

    /// A finished tag value (a v20 tag literal, or a tag rescued from string evaluation).
    pub fn push_tag(output: *Output, string: StringReference, start: u32, length: u32) Error!void {
        assert(output.items.count <= output.items.buffer.len);
        if (length > std.math.maxInt(u16)) return error.TextTooLong;
        output.items.push(.{
            .string = string,
            .start = start,
            .kind = .tag,
            .class = .non_whitespace,
            .length = @intCast(length),
        }) catch return error.OutputLimit;
        assert(output.items.peek().?.kind == .tag);
    }

    /// ink's TrimNewlinesFromOutputStream.
    fn trim_newlines(output: *Output) void {
        assert(output.items.count <= output.items.buffer.len);
        const items = output.items.slice();
        var remove_from: ?usize = null;
        var position = items.len;
        while (position > 0) {
            position -= 1;
            const item = items[position];
            if (item.kind != .text and item.kind != .tag) break;
            if (item.kind == .text and item.class == .non_whitespace) break;
            if (item.kind == .text and item.class == .newline) remove_from = position;
        }
        const from = remove_from orelse return;
        // Remove the text items from there on; tags stay.
        var kept: u32 = @intCast(from);
        for (items[from..]) |item| {
            if (item.kind == .text) continue;
            items[kept] = item;
            kept += 1;
        }
        output.items.truncate(kept);
        assert(output.items.count >= from);
    }

    /// ink's RemoveExistingGlue: glue after the last command goes.
    fn remove_existing_glue(output: *Output) void {
        assert(output.items.count <= output.items.buffer.len);
        const items = output.items.slice();
        var first_kept: usize = items.len;
        while (first_kept > 0 and items[first_kept - 1].kind != .begin_string and
            items[first_kept - 1].kind != .begin_tag and items[first_kept - 1].kind != .end_tag)
        {
            first_kept -= 1;
        }
        var kept: u32 = @intCast(first_kept);
        for (items[first_kept..]) |item| {
            if (item.kind == .glue) continue;
            items[kept] = item;
            kept += 1;
        }
        output.items.truncate(kept);
        assert(kept <= items.len);
    }

    /// ink's outputStreamEndsInNewline.
    pub fn ends_in_newline(output: *const Output) bool {
        assert(output.string_marks.count <= output.items.count);
        assert(output.items.count <= output.items.buffer.len);
        const items = output.items.slice();
        var position = items.len;
        while (position > 0) {
            position -= 1;
            const item = items[position];
            if (item.kind == .begin_string or item.kind == .begin_tag or item.kind == .end_tag) {
                return false;
            }
            if (item.kind != .text) continue;
            if (item.class == .newline) return true;
            if (item.class == .non_whitespace) return false;
        }
        return false;
    }

    /// ink's outputStreamContainsContent: any text at all.
    pub fn contains_content(output: *const Output) bool {
        assert(output.items.count <= output.items.buffer.len);
        for (output.items.slice()) |item| {
            if (item.kind == .text) return true;
        }
        assert(output.items.count < std.math.maxInt(u32));
        return false;
    }

    /// ink's TrimWhitespaceFromFunctionEnd, when a function returns.
    pub fn trim_function_end(output: *Output, function_start: u32) void {
        assert(output.items.count <= output.items.buffer.len);
        const start: usize = if (function_start == no_function_start) 0 else function_start;
        const items = output.items.slice();
        var position = items.len;
        while (position > start) {
            position -= 1;
            const item = items[position];
            if (item.kind != .text) continue;
            if (item.class == .non_whitespace) break;
            // Removing keeps the order of everything after it.
            std.mem.copyForwards(Item, items[position .. items.len - 1], items[position + 1 ..]);
            output.items.count -= 1;
            return output.trim_function_end_from(start, position);
        }
        assert(position >= start);
    }

    fn trim_function_end_from(output: *Output, start: usize, below: usize) void {
        assert(start <= below);
        assert(below <= output.items.count + 1);
        var position = below;
        while (position > start) {
            position -= 1;
            const items = output.items.slice();
            const item = items[position];
            if (item.kind != .text) continue;
            if (item.class == .non_whitespace) return;
            std.mem.copyForwards(Item, items[position .. items.len - 1], items[position + 1 ..]);
            output.items.count -= 1;
        }
    }

    /// `/str`: the text since the matching `str` (writes it to `writer`), with the items
    /// removed and any tags inside kept. Returns the bytes written.
    pub fn end_string(output: *Output, strings: anytype, writer: *std.Io.Writer) !u32 {
        const mark = output.string_marks.pop() orelse return error.UnmatchedEndString;
        const items = output.items.slice();
        assert(items[mark].kind == .begin_string);
        var written: u32 = 0;
        var tags_kept: u32 = 0;
        for (items[mark + 1 ..]) |item| {
            if (item.kind == .text) {
                try writer.writeAll(item.bytes(strings));
                written += item.length;
            } else if (item.kind == .tag) {
                items[mark + tags_kept] = item;
                tags_kept += 1;
            }
        }
        output.items.truncate(mark + tags_kept);
        assert(output.items.count == mark + tags_kept);
        return written;
    }

    /// The current text: text outside tags, cleaned as ink's CleanOutputWhitespace does.
    pub fn write_text(output: *const Output, strings: anytype, writer: *std.Io.Writer) !void {
        assert(output.items.count <= output.items.buffer.len);
        var cleaner: Cleaner = .{ .writer = writer };
        var in_tag = false;
        for (output.items.slice()) |item| {
            switch (item.kind) {
                .begin_tag => in_tag = true,
                .end_tag => in_tag = false,
                .text => if (!in_tag) try cleaner.write(item.bytes(strings)),
                else => {},
            }
        }
        assert(cleaner.writer == writer);
    }

    /// The current tags, as ink's currentTags builds them; `tag(text)` is called for each.
    pub fn collect_tags(output: *const Output, strings: anytype, sink: anytype) !void {
        assert(output.items.count <= output.items.buffer.len);
        var buffer: [1024]u8 = undefined;
        var pending: std.Io.Writer = .fixed(&buffer);
        var in_tag = false;
        for (output.items.slice()) |item| {
            switch (item.kind) {
                .begin_tag => {
                    if (in_tag and pending.end > 0) try flush_tag(&pending, sink);
                    in_tag = true;
                },
                .end_tag => {
                    if (pending.end > 0) try flush_tag(&pending, sink);
                    in_tag = false;
                },
                .text => if (in_tag) try pending.writeAll(item.bytes(strings)),
                .tag => if (!in_tag and item.length > 0) try sink.tag(item.bytes(strings)),
                else => {},
            }
        }
        if (pending.end > 0) try flush_tag(&pending, sink);
        assert(pending.end == 0);
    }

    fn flush_tag(pending: *std.Io.Writer, sink: anytype) !void {
        assert(pending.buffer.len > 0);
        assert(pending.end > 0);
        var buffer: [1024]u8 = undefined;
        var cleaned: std.Io.Writer = .fixed(&buffer);
        var cleaner: Cleaner = .{ .writer = &cleaned };
        try cleaner.write(pending.buffered());
        try sink.tag(cleaned.buffered());
        pending.end = 0;
    }

    pub fn check(output: *const Output) Fault {
        assert(output.items.buffer.len > 0);
        if (output.items.check() != .ok or output.string_marks.check() != .ok) return .storage;
        var previous: ?u32 = null;
        for (output.string_marks.slice()) |mark| {
            if (mark >= output.items.count) return .mark_not_begin_string;
            if (output.items.slice()[mark].kind != .begin_string) return .mark_not_begin_string;
            if (previous) |earlier| {
                if (mark <= earlier) return .marks_unordered;
            }
            previous = mark;
        }
        return .ok;
    }

    pub fn verify(output: *const Output) void {
        assert(output.items.buffer.len > 0);
        fault.verify(output.check());
    }
};

/// ink's CleanOutputWhitespace, streaming: inline whitespace at the start of a line goes, and
/// any other run of it becomes one space, written only when non-newline text follows. Feed it
/// the whole text in pieces.
pub const Cleaner = struct {
    writer: *std.Io.Writer,
    /// Index in the whole text of the current whitespace run's start, or null.
    whitespace_start: ?u64 = null,
    line_start: u64 = 0,
    position: u64 = 0,

    pub fn write(cleaner: *Cleaner, text: []const u8) !void {
        assert(cleaner.position >= cleaner.line_start);
        for (text) |character| {
            const is_inline_whitespace = character == ' ' or character == '\t';
            if (is_inline_whitespace and cleaner.whitespace_start == null) {
                cleaner.whitespace_start = cleaner.position;
            }
            if (!is_inline_whitespace) {
                if (cleaner.whitespace_start) |start| {
                    if (character != '\n' and start > 0 and start != cleaner.line_start) {
                        try cleaner.writer.writeByte(' ');
                    }
                }
                cleaner.whitespace_start = null;
                try cleaner.writer.writeByte(character);
            }
            if (character == '\n') cleaner.line_start = cleaner.position + 1;
            cleaner.position += 1;
        }
        assert(cleaner.line_start <= cleaner.position);
    }
};

const Piece = struct { start: u32, length: u32 };

/// ink's TrySplittingHeadTailWhitespace. Returns 0 when there is nothing to split (no newline
/// in the leading or trailing whitespace); otherwise the pieces, in order.
fn split_head_tail_whitespace(text: []const u8, pieces: *[5]Piece) u32 {
    assert(text.len < 1 << 20);
    var head_first: ?u32 = null;
    var head_last: ?u32 = null;
    for (text, 0..) |character, position| {
        if (character == '\n') {
            if (head_first == null) head_first = @intCast(position);
            head_last = @intCast(position);
        } else if (character != ' ' and character != '\t') break;
    }
    var tail_last: ?u32 = null;
    var tail_first: ?u32 = null;
    var position = text.len;
    while (position > 0) {
        position -= 1;
        const character = text[position];
        if (character == '\n') {
            if (tail_last == null) tail_last = @intCast(position);
            tail_first = @intCast(position);
        } else if (character != ' ' and character != '\t') break;
    }
    if (head_first == null and tail_last == null) return 0;
    var count: u32 = 0;
    var inner_start: u32 = 0;
    var inner_end: u32 = @intCast(text.len);
    if (head_first) |first| {
        if (first > 0) {
            pieces[count] = .{ .start = 0, .length = first };
            count += 1;
        }
        pieces[count] = .{ .start = first, .length = 1 };
        count += 1;
        inner_start = head_last.? + 1;
    }
    if (tail_last != null) inner_end = tail_first.?;
    if (inner_end > inner_start) {
        pieces[count] = .{ .start = inner_start, .length = inner_end - inner_start };
        count += 1;
    }
    const head_end: i64 = if (head_last) |last| last else -1;
    if (tail_last) |last| {
        if (tail_first.? > head_end) {
            pieces[count] = .{ .start = tail_first.?, .length = 1 };
            count += 1;
            if (last < text.len - 1) {
                pieces[count] = .{ .start = last + 1, .length = @intCast(text.len - last - 1) };
                count += 1;
            }
        }
    }
    assert(count > 0 and count <= pieces.len);
    return count;
}

/// Strings for the tests: each reference is an index into a fixed table.
const TestStrings = struct {
    table: []const []const u8,

    pub fn get(strings: TestStrings, reference: StringReference) []const u8 {
        assert(reference.is_heap());
        const position = reference.heap_offset();
        assert(position < strings.table.len);
        return strings.table[position];
    }
};

const TestOutput = struct {
    items: [32]Item = undefined,
    marks: [4]u32 = undefined,
    frames: [2]Frame = undefined,
    strings: TestStrings,
    output: Output = undefined,

    fn setup(test_output: *TestOutput) void {
        assert(test_output.strings.table.len > 0);
        test_output.output = Output.init(&test_output.items, &test_output.marks);
        test_output.frames[0] = .{
            .pointer = .null,
            .temps_first = 0,
            .evaluation_height = 0,
            .function_start_in_output = 0,
            .temps_count = 0,
            .kind = .tunnel,
            .in_expression_evaluation = false,
        };
        assert(test_output.output.items.count == 0);
    }

    fn text(test_output: *TestOutput, string: u32) !void {
        assert(string < test_output.strings.table.len);
        assert(test_output.output.items.count < test_output.items.len);
        const frames = test_output.frames[0..1];
        const length: u32 = @intCast(test_output.strings.table[string].len);
        try test_output.output.push_text(test_output.strings, frames, .heap(string), 0, length);
    }

    fn line(test_output: *TestOutput, buffer: []u8) ![]const u8 {
        assert(buffer.len > 0);
        assert(test_output.output.items.count <= test_output.items.len);
        var writer: std.Io.Writer = .fixed(buffer);
        try test_output.output.write_text(test_output.strings, &writer);
        return writer.buffered();
    }
};

test "head and tail whitespace splits like ink" {
    // Goal: TrySplittingHeadTailWhitespace. Method: leading and trailing newlines with spaces.
    var pieces: [5]Piece = undefined;
    try std.testing.expectEqual(@as(u32, 0), split_head_tail_whitespace("plain text", &pieces));
    const count = split_head_tail_whitespace("  \nHello\n  ", &pieces);
    try std.testing.expectEqual(@as(u32, 5), count);
    try std.testing.expectEqual(Piece{ .start = 0, .length = 2 }, pieces[0]);
    try std.testing.expectEqual(Piece{ .start = 2, .length = 1 }, pieces[1]);
    try std.testing.expectEqual(Piece{ .start = 3, .length = 5 }, pieces[2]);
    try std.testing.expectEqual(Piece{ .start = 8, .length = 1 }, pieces[3]);
    try std.testing.expectEqual(Piece{ .start = 9, .length = 2 }, pieces[4]);
}

test "newlines collapse, glue joins lines, and text is cleaned" {
    // Goal: the common output rules. Method: leading newline dropped, double newline dropped,
    // glue removing a newline, and whitespace runs collapsed.
    const table = [_][]const u8{ "\n", "Hello  ", "  world", "\n", "Again" };
    var test_output: TestOutput = .{ .strings = .{ .table = &table } };
    test_output.setup();
    try test_output.text(0);
    try test_output.text(1);
    try test_output.text(3);
    try test_output.text(3);
    try test_output.output.push_glue();
    try test_output.text(2);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world", try test_output.line(&buffer));
    try std.testing.expect(!test_output.output.ends_in_newline());
    try test_output.text(3);
    try std.testing.expect(test_output.output.ends_in_newline());
}

test "a function drops leading newlines and trailing whitespace" {
    // Goal: plan S10. Method: a function frame whose output starts with a newline and ends
    // with spaces and a newline.
    const table = [_][]const u8{ "Before ", "\n", "Inside", "   ", " after." };
    var test_output: TestOutput = .{ .strings = .{ .table = &table } };
    test_output.setup();
    try test_output.text(0);
    test_output.frames[1] = test_output.frames[0];
    test_output.frames[1].kind = .function;
    test_output.frames[1].function_start_in_output = test_output.output.items.count;
    const frames = test_output.frames[0..2];
    const strings = test_output.strings;
    try test_output.output.push_text(strings, frames, .heap(1), 0, 1);
    try test_output.output.push_text(strings, frames, .heap(2), 0, 6);
    try test_output.output.push_text(strings, frames, .heap(3), 0, 3);
    try test_output.output.push_text(strings, frames, .heap(1), 0, 1);
    test_output.output.trim_function_end(frames[1].function_start_in_output);
    try test_output.text(4);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Before Inside after.", try test_output.line(&buffer));
}

test "string evaluation returns its text and keeps tags" {
    // Goal: `/str` and the string mark stack. Method: text and a tag inside str ... /str.
    var test_output: TestOutput = .{ .strings = .{ .table = &.{ "A", "B", "tagged" } } };
    test_output.setup();
    try test_output.output.push_command(.begin_string);
    try std.testing.expect(test_output.output.in_string_evaluation());
    try test_output.text(0);
    try test_output.output.push_tag(.heap(2), 0, 6);
    try test_output.text(1);
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const written = try test_output.output.end_string(test_output.strings, &writer);
    try std.testing.expectEqual(@as(u32, 2), written);
    try std.testing.expectEqualStrings("AB", writer.buffered());
    try std.testing.expect(!test_output.output.in_string_evaluation());
    try std.testing.expectEqual(@as(u32, 1), test_output.output.items.count);
    try std.testing.expectEqual(Kind.tag, test_output.output.items.slice()[0].kind);
}

const TagSink = struct {
    seen: [4][16]u8 = undefined,
    lengths: [4]u32 = undefined,
    count: u32 = 0,

    pub fn tag(sink: *TagSink, text: []const u8) !void {
        assert(text.len <= 16);
        assert(sink.count < 4);
        @memcpy(sink.seen[sink.count][0..text.len], text);
        sink.lengths[sink.count] = @intCast(text.len);
        sink.count += 1;
    }
};

test "dynamic tags are assembled and cleaned" {
    // Goal: currentTags for v21 `#` ... `/#` tags. Method: a tag made of two text items with
    // extra spaces, then text after it, which is not part of the tag.
    const table = [_][]const u8{ "Line", "  big ", "  red  ", " after" };
    var test_output: TestOutput = .{ .strings = .{ .table = &table } };
    test_output.setup();
    try test_output.text(0);
    try test_output.output.push_command(.begin_tag);
    try test_output.text(1);
    try test_output.text(2);
    try test_output.output.push_command(.end_tag);
    try test_output.text(3);
    var sink: TagSink = .{};
    try test_output.output.collect_tags(test_output.strings, &sink);
    try std.testing.expectEqual(@as(u32, 1), sink.count);
    try std.testing.expectEqualStrings("big red", sink.seen[0][0..sink.lengths[0]]);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Line after", try test_output.line(&buffer));
}
