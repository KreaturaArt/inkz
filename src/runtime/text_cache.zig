//! The cleaned text of the current line, kept between calls (plan P10.1). ink cleans the
//! whole output stream every time it needs the current text: after every step that output
//! something, for the newline lookahead, and for the line itself. Cleaning was about half of
//! play time, and most calls only add items to a stream that is already clean.
//!
//! The cache keeps the cleaned text, the cleaner's state after it, and a copy of the items
//! it came from. While the output still starts with those items and no heap string changed
//! (the heap's generation), only the new items are cleaned; anything else (items removed or
//! rewritten by glue, trimming, `/str`, a lookahead restore, a flow switch or a load, and
//! heap truncation or compaction) cleans from the start. Both buffers come from the state's
//! one allocation: `output_items_max` items and `output_bytes_max` bytes.

const std = @import("std");
const assert = std.debug.assert;
const output_module = @import("output.zig");
const Output = output_module.Output;
const Item = output_module.Item;
const Cleaner = output_module.Cleaner;

pub const Error = error{OutputLimit};

comptime {
    // Items are compared as bytes.
    assert(std.meta.hasUniqueRepresentation(Item));
}

pub const TextCache = struct {
    /// The items the text was cleaned from (a prefix of the output's items).
    items: []Item,
    /// The cleaned text of `items[0..count]`.
    text: []u8,
    count: u32 = 0,
    end: u32 = 0,
    /// The heap generation the text was cleaned at.
    generation: u32 = 0,
    in_tag: bool = false,
    // The cleaner's state after `text`.
    whitespace_start: ?u64 = null,
    line_start: u64 = 0,
    position: u64 = 0,

    pub const Fault = enum { ok, count_past_items, end_past_text };

    pub fn init(items: []Item, text: []u8) TextCache {
        assert(items.len > 0);
        assert(text.len > 0);
        return .{ .items = items, .text = text };
    }

    /// Forgets the cleaned text; the next `update` cleans from the start.
    pub fn clear(cache: *TextCache) void {
        assert(cache.count <= cache.items.len);
        cache.count = 0;
        cache.end = 0;
        cache.in_tag = false;
        cache.whitespace_start = null;
        cache.line_start = 0;
        cache.position = 0;
        assert(cache.check() == .ok);
    }

    /// The output's cleaned text (ink's currentText), valid until the next `update` or
    /// `clear`. `generation` is the string heap's.
    pub fn update(
        cache: *TextCache,
        output: *const Output,
        strings: anytype,
        generation: u32,
    ) Error![]const u8 {
        const items = output.items.slice();
        assert(items.len <= cache.items.len);
        if (!cache.reusable(items, generation)) {
            cache.clear();
            cache.generation = generation;
        }
        cache.clean_from(items, strings) catch {
            cache.clear();
            return error.OutputLimit;
        };
        assert(cache.count == items.len);
        return cache.text[0..cache.end];
    }

    /// Whether the cleaned prefix still holds: the output starts with the cached items and
    /// the heap's strings are as they were.
    fn reusable(cache: *const TextCache, items: []const Item, generation: u32) bool {
        assert(cache.count <= cache.items.len);
        assert(items.len <= cache.items.len);
        if (cache.generation != generation or cache.count > items.len) return false;
        const cached = std.mem.sliceAsBytes(cache.items[0..cache.count]);
        return std.mem.eql(u8, cached, std.mem.sliceAsBytes(items[0..cache.count]));
    }

    /// Cleans `items[count..]` after the cached text, as Output.write_text would.
    fn clean_from(cache: *TextCache, items: []const Item, strings: anytype) !void {
        assert(cache.count <= items.len);
        assert(cache.end <= cache.text.len);
        var writer: std.Io.Writer = .fixed(cache.text);
        writer.end = cache.end;
        var cleaner: Cleaner = .{
            .writer = &writer,
            .whitespace_start = cache.whitespace_start,
            .line_start = cache.line_start,
            .position = cache.position,
        };
        for (items[cache.count..]) |item| {
            switch (item.kind) {
                .begin_tag => cache.in_tag = true,
                .end_tag => cache.in_tag = false,
                .text => if (!cache.in_tag) try cleaner.write(item.bytes(strings)),
                else => {},
            }
        }
        @memcpy(cache.items[cache.count..items.len], items[cache.count..]);
        cache.count = @intCast(items.len);
        cache.end = @intCast(writer.end);
        cache.whitespace_start = cleaner.whitespace_start;
        cache.line_start = cleaner.line_start;
        cache.position = cleaner.position;
    }

    pub fn check(cache: *const TextCache) Fault {
        assert(cache.items.len > 0);
        assert(cache.text.len > 0);
        if (cache.count > cache.items.len) return .count_past_items;
        if (cache.end > cache.text.len) return .end_past_text;
        return .ok;
    }
};

// Tests: an output over a table of strings, cleaned by the cache and in full.

const value_module = @import("value.zig");
const call_stack = @import("call_stack.zig");
const StringReference = value_module.StringReference;

const TestStrings = struct {
    table: []const []const u8,

    pub fn get(strings: TestStrings, reference: StringReference) []const u8 {
        assert(reference.is_heap());
        assert(reference.heap_offset() < strings.table.len);
        return strings.table[reference.heap_offset()];
    }
};

const Fixture = struct {
    items: [32]Item = undefined,
    marks: [4]u32 = undefined,
    cache_items: [32]Item = undefined,
    cache_text: [256]u8 = undefined,
    frames: [1]call_stack.Frame = undefined,
    output: Output = undefined,
    cache: TextCache = undefined,
    strings: TestStrings,
    generation: u32 = 0,

    fn setup(fixture: *Fixture) void {
        assert(fixture.strings.table.len > 0);
        fixture.output = .init(&fixture.items, &fixture.marks);
        fixture.cache = .init(&fixture.cache_items, &fixture.cache_text);
        fixture.frames[0] = .{
            .pointer = .null,
            .temps_first = 0,
            .evaluation_height = 0,
            .function_start_in_output = 0,
            .temps_count = 0,
            .kind = .tunnel,
            .in_expression_evaluation = false,
        };
        assert(fixture.output.items.count == 0);
    }

    fn text(fixture: *Fixture, string: u32) !void {
        assert(string < fixture.strings.table.len);
        assert(fixture.output.items.count < fixture.items.len);
        const length: u32 = @intCast(fixture.strings.table[string].len);
        try fixture.output.push_text(fixture.strings, &fixture.frames, .heap(string), 0, length);
    }

    /// The cache's text must equal a full clean.
    fn expect_line(fixture: *Fixture, expected: []const u8) !void {
        assert(fixture.cache.check() == .ok);
        assert(expected.len < fixture.cache_text.len);
        const generation = fixture.generation;
        const cached = try fixture.cache.update(&fixture.output, fixture.strings, generation);
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try fixture.output.write_text(fixture.strings, &writer);
        try std.testing.expectEqualStrings(writer.buffered(), cached);
        try std.testing.expectEqualStrings(expected, cached);
    }
};

test "appended items are cleaned once, and the result equals a full clean" {
    // Goal: the incremental path. Method: text, whitespace and a newline added one item at a
    // time, the line read after each; the cleaned prefix is kept in between.
    var fixture: Fixture = .{ .strings = .{ .table = &.{ "Hello", "  ", "world", "\n" } } };
    fixture.setup();
    try fixture.text(0);
    try fixture.expect_line("Hello");
    try fixture.text(1);
    try fixture.expect_line("Hello");
    try fixture.text(2);
    try fixture.expect_line("Hello world");
    try std.testing.expectEqual(@as(u32, 3), fixture.cache.count);
    try fixture.text(3);
    try fixture.expect_line("Hello world\n");
}

test "removed or rewritten items clean from the start" {
    // Goal: invalidation by the items. Method: glue trims the newline (items removed), then
    // a truncation like `/str` and a restore that rewrites an item in place.
    var fixture: Fixture = .{ .strings = .{ .table = &.{ "One", "\n", "Two", "Three" } } };
    fixture.setup();
    try fixture.text(0);
    try fixture.text(1);
    try fixture.expect_line("One\n");
    try fixture.output.push_glue();
    try fixture.text(2);
    try fixture.expect_line("OneTwo");
    fixture.output.items.truncate(1);
    try fixture.expect_line("One");
    fixture.items[0].string = .heap(3);
    fixture.items[0].length = 5;
    try fixture.expect_line("Three");
}

test "a new heap generation cleans from the start" {
    // Goal: invalidation by the heap (truncation, compaction, reset). Method: the same items
    // whose string table changed, read with and without a new generation.
    var table = [_][]const u8{ "before", "\n" };
    var fixture: Fixture = .{ .strings = .{ .table = &table } };
    fixture.setup();
    try fixture.text(0);
    try fixture.expect_line("before");
    table[0] = "after!";
    fixture.generation += 1;
    try fixture.expect_line("after!");
}

test "tags are left out across updates, and overflow is a named error" {
    // Goal: the tag state survives between updates; a full text buffer fails cleanly.
    // Method: text inside a tag added after the tag began; then a tiny text buffer.
    var fixture: Fixture = .{ .strings = .{ .table = &.{ "Line", "tagged", "more" } } };
    fixture.setup();
    try fixture.text(0);
    try fixture.output.push_command(.begin_tag);
    try fixture.expect_line("Line");
    try fixture.text(1);
    try fixture.expect_line("Line");
    try fixture.output.push_command(.end_tag);
    try fixture.text(2);
    try fixture.expect_line("Linemore");
    var tiny: [2]u8 = undefined;
    fixture.cache = .init(&fixture.cache_items, &tiny);
    const result = fixture.cache.update(&fixture.output, fixture.strings, 0);
    try std.testing.expectError(error.OutputLimit, result);
    try std.testing.expectEqual(@as(u32, 0), fixture.cache.count);
}
