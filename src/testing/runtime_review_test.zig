//! Runtime fixes from the final review (P15.1), each checked through a whole story: the
//! lookahead's undo log, long tags, glue in choice tags, lists that print long, and ink's
//! list-and-int operation errors. The stories are compiled from the ink in each test.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const api = @import("../runtime/api.zig");
const Program = @import("../core/program.zig").Program;

/// A story on `program` with `limits`, owned by the caller.
fn start(gpa: std.mem.Allocator, program: *const Program, limits: api.Limits) !*api.Story {
    assert(program.containers.len > 0);
    const story = try gpa.create(api.Story);
    errdefer gpa.destroy(story);
    try story.init(gpa, program, .{ .limits = limits });
    return story;
}

fn stop(gpa: std.mem.Allocator, story: *api.Story) void {
    story.deinit(gpa);
    gpa.destroy(story);
}

/// The story's whole output until it stops or asks for a choice, owned by the caller.
fn play(gpa: std.mem.Allocator, story: *api.Story) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    var lines: u32 = 0;
    while (story.can_continue()) : (lines += 1) {
        assert(lines < 1000);
        try text.writer.writeAll((try story.cont()).get());
    }
    return text.toOwnedSlice();
}

/// The first story error's message, written into `buffer`.
fn first_error(story: *api.Story, buffer: []u8) ![]const u8 {
    assert(story.error_count() > 0);
    var writer: std.Io.Writer = .fixed(buffer);
    try story.write_error(0, &writer);
    return writer.buffered();
}

test "a loop that writes one variable 1100 times before the line ends fits the undo log" {
    // The newline after "Hello" starts a lookahead, and the loop runs inside it before
    // "World" ends it: 1100 writes each of `x`, the gather's visit count and its turn
    // index. With one log entry per write, the default 1024 entries ran out.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa,
        \\VAR x = 0
        \\Hello
        \\- (top)
        \\~ x++
        \\{ x < 1100: -> top }
        \\World
        \\-> END
        \\
    );
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    const text = try play(gpa, story);
    defer gpa.free(text);
    // ink 1.2.1 prints the same three lines: the branch's space makes the line after
    // "Hello" non-empty, so its newline is kept.
    try std.testing.expectEqualStrings("Hello\n\nWorld\n", text);
    try std.testing.expectEqual(@as(i32, 1100), story.get_variable("x").?.get().integer);
}

/// Keeps a copy of each tag it is given.
const TagRecorder = struct {
    gpa: std.mem.Allocator,
    tags: std.ArrayList([]u8) = .empty,

    pub fn tag(recorder: *TagRecorder, text: []const u8) !void {
        assert(recorder.tags.items.len < 16);
        const copy = try recorder.gpa.dupe(u8, text);
        errdefer recorder.gpa.free(copy);
        try recorder.tags.append(recorder.gpa, copy);
    }

    fn deinit(recorder: *TagRecorder) void {
        for (recorder.tags.items) |text| recorder.gpa.free(text);
        recorder.tags.deinit(recorder.gpa);
    }
};

/// "Hello #" and a tag of `length` letters, then "World", owned by the caller.
fn long_tag_source(gpa: std.mem.Allocator, length: u32) ![]u8 {
    assert(length > 0);
    const letters = try gpa.alloc(u8, length);
    defer gpa.free(letters);
    for (letters, 0..) |*letter, position| letter.* = 'a' + @as(u8, @intCast(position % 26));
    return std.fmt.allocPrint(gpa, "Hello #{s}\nWorld\n-> END\n", .{letters});
}

test "a tag longer than 1024 bytes reaches the sink whole, and the limit has its own error" {
    // A 1100-letter tag: the tag buffers were fixed 1024-byte arrays, so this returned
    // OutputLimit. With the default 4 KiB `tag_bytes_max` it comes through whole; with
    // `tag_bytes_max = 1000` the same story returns TagBytesLimit.
    const gpa = std.testing.allocator;
    const source = try long_tag_source(gpa, 1100);
    defer gpa.free(source);
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    try std.testing.expectEqualStrings("Hello\n", (try story.cont()).get());
    var recorder: TagRecorder = .{ .gpa = gpa };
    defer recorder.deinit();
    try story.current_tags(&recorder);
    try std.testing.expectEqual(@as(usize, 1), recorder.tags.items.len);
    try std.testing.expectEqualStrings(source[7..][0..1100], recorder.tags.items[0]);
    try std.testing.expectEqual(@as(u32, 1100), story.usage().tag_bytes);

    const tight = try start(gpa, &program, .{ .tag_bytes_max = 1000 });
    defer stop(gpa, tight);
    try std.testing.expectError(error.TagBytesLimit, tight.cont());
}

test "glue inside a choice tag is dropped, as ink does" {
    // `* [A #x <>] out`: the tag's content ends in glue. ink 1.2.1 skips everything but
    // text and control commands while it extracts the tag, giving choice "A" with tag "x"
    // and "out" after choosing; this runtime reported a story error.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, "Hi\n* [A #x <>] out\n-> END\n");
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    const before = try play(gpa, story);
    defer gpa.free(before);
    try std.testing.expectEqualStrings("Hi\n", before);
    try std.testing.expectEqual(@as(u32, 0), story.error_count());
    try std.testing.expectEqual(@as(u32, 1), story.current_choices_count());
    const choice = (try story.current_choice(0)).get();
    try std.testing.expectEqualStrings("A", choice.text);
    try std.testing.expectEqual(@as(u32, 1), choice.tags_count);
    try std.testing.expectEqualStrings("x", (try story.current_choice_tag(0, 0)).get());
    try story.choose_choice_index(0);
    const after = try play(gpa, story);
    defer gpa.free(after);
    try std.testing.expectEqualStrings("out\n", after);
}

test "assigning a popped string to a temp named like a list item allocates nothing first" {
    // Re-assigning a temp first checks whether it holds a variable pointer. For a name that
    // is also a list item, that check made a one-item list, and with `compact_always` the
    // compaction dropped the new, popped and unrooted, string. ink's compiler rejects such
    // a temp, so the story is compiled with the temp named `z`, renamed to `a` in the JSON.
    const gpa = std.testing.allocator;
    const json = try compile.compile_to_json(gpa,
        \\LIST l = a, b
        \\~ temp z = "x"
        \\~ z = "long" + " string"
        \\{z}
        \\-> END
        \\
    );
    defer gpa.free(json);
    const renamed = try std.mem.replaceOwned(u8, gpa, json, "\"z\"", "\"a\"");
    defer gpa.free(renamed);
    try std.testing.expect(!std.mem.eql(u8, json, renamed));
    const story = try gpa.create(api.Story);
    defer gpa.destroy(story);
    try story.init_from_json(gpa, renamed, .{});
    defer story.deinit(gpa);
    story.core.state.compact_always = true;
    const text = try play(gpa, story);
    defer gpa.free(text);
    // `{a}` reads the list item, as ink's GetRawVariableWithName looks for one before temps.
    try std.testing.expectEqualStrings("a\n", text);
    story.core.state.verify();
}

/// A line with one shuffle of `elements` alternatives, owned by the caller.
fn shuffle_source(gpa: std.mem.Allocator, elements: u32) ![]u8 {
    assert(elements > 1);
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    try source.writer.writeAll("{~");
    for (0..elements) |position| {
        if (position > 0) try source.writer.writeByte('|');
        try source.writer.print("e{d}", .{position});
    }
    try source.writer.writeAll("}\n-> END\n");
    return source.toOwnedSlice();
}

test "a shuffle past shuffle_elements_max returns ShuffleLimit" {
    // 1025 alternatives don't fit the shuffle's fixed buffer of unpicked indices: the
    // limit has its own error (it was the story error for a malformed shuffle). 1024 play.
    const gpa = std.testing.allocator;
    const too_many = try shuffle_source(gpa, 1025);
    defer gpa.free(too_many);
    var program = try compile.compile_source(gpa, too_many);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    try std.testing.expectError(error.ShuffleLimit, story.cont());
    try std.testing.expectEqual(@as(u32, 0), story.error_count());

    const most = try shuffle_source(gpa, 1024);
    defer gpa.free(most);
    var fits = try compile.compile_source(gpa, most);
    defer fits.deinit(gpa);
    const fitting = try start(gpa, &fits, .{});
    defer stop(gpa, fitting);
    const line = (try fitting.cont()).get();
    try std.testing.expect(line[0] == 'e');
}

/// Plays `source` until its story error and returns the first error's message.
fn list_error_of(gpa: std.mem.Allocator, source: []const u8, buffer: []u8) ![]const u8 {
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    var lines: u32 = 0;
    while (story.can_continue()) : (lines += 1) {
        assert(lines < 10);
        _ = story.cont() catch |err| {
            try std.testing.expectEqual(error.StoryError, err);
            return first_error(story, buffer);
        };
    }
    return error.TestUnexpectedResult;
}

test "lists meet ints only through + and -, as in ink" {
    // ink 1.2.1's CallBinaryListOperation: `x + 1` and `x - 1` move the list's items, but
    // `x == 2` and `2 + x` are errors, which this runtime allowed by coercing the int to a
    // list item. The messages are ink's, pointer prefix included.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa,
        \\LIST l = a, b, c
        \\VAR x = (b)
        \\{x + 1} {x - 1}
        \\-> END
        \\
    );
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    try std.testing.expectEqualStrings("c a\n", (try story.cont()).get());

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "RUNTIME ERROR: (0.3): Can not call use '==' operation on List and Int",
        try list_error_of(gpa, "LIST l = a, b, c\nVAR x = (b)\n{x == 2}\n-> END\n", &buffer),
    );
    try std.testing.expectEqualStrings(
        "RUNTIME ERROR: (0.3): Can not call use '+' operation on Int and List",
        try list_error_of(gpa, "LIST l = a, b, c\nVAR x = (b)\n{2 + x}\n-> END\n", &buffer),
    );
}

test "global reads and writes go through the slot, without a scan by name" {
    // 64 globals read and written by a story: `global_slot` never scans (P16.8, F2). A
    // write in the newline lookahead is undone with it, and a ref parameter passed a global
    // still assigns the global.
    const gpa = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    for (0..64) |index| try source.writer.print("VAR g{d} = {d}\n", .{ index, index });
    for (0..63) |index| try source.writer.print("~ g{d} = g{d} + 1\n", .{ index, index + 1 });
    try source.writer.writeAll("{g0} {g62}\n~ g1 = 100\nNext\n-> END\n");
    var program = try compile.compile_source(gpa, source.written());
    defer program.deinit(gpa);
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    const ops = @import("../runtime/ops.zig");
    const scans_before = ops.global_slot_calls;
    try std.testing.expectEqualStrings("2 64\n", (try story.cont()).get());
    // The lookahead ran `~ g1 = 100` and saw "Next": it restored g1.
    try std.testing.expectEqual(@as(i32, 3), story.get_variable("g1").?.get().integer);
    try std.testing.expectEqual(scans_before, ops.global_slot_calls);
    try std.testing.expectEqualStrings("Next\n", (try story.cont()).get());
    try std.testing.expectEqual(@as(i32, 100), story.get_variable("g1").?.get().integer);
    try std.testing.expectEqual(scans_before, ops.global_slot_calls);

    var ref_program = try compile.compile_source(gpa,
        \\VAR g = 1
        \\~ add(g)
        \\~ add(g)
        \\{g}
        \\=== function add(ref x) ===
        \\~ x = x + 10
        \\
    );
    defer ref_program.deinit(gpa);
    var ref_story: api.Story = undefined;
    try ref_story.init(gpa, &ref_program, .{});
    defer ref_story.deinit(gpa);
    try std.testing.expectEqualStrings("21\n", (try ref_story.cont()).get());
}
