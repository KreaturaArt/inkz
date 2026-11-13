//! Fuzz targets (plan P0.9), run with `zig build fuzz`: each one runs once on its seed corpus.
//! `zig build fuzz --fuzz` starts Zig's fuzzer on them: the JSON and save loaders, the
//! tokenizer, the compiler and the program image loader (P3.1, P6.2, P7.1, P9.2, P10.5, P10.7).
//!
//! A target fails when the code under test crashes. Returning an error is fine: malformed input
//! must be rejected, never trusted.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("core/ink_json.zig");

const input_bytes_max = 4096;

const ink_corpus = [_][]const u8{
    "Hello, world.\n",
    "* [Choice] Text -> knot\n=== knot ===\nKnot {x}.\n-> END\n",
    "VAR x = 5\n~ x = x + 1\n{x > 2: big|small}\n",
    "{~a|b|c} <> glue\n# tag\n",
};

const json_corpus = [_][]const u8{
    "{\"inkVersion\":21,\"root\":[[\"^Hello\",\"\\n\"," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}",
    "{\"inkVersion\":21,\"root\":[],\"listDefs\":{}}",
};

/// Copies the fuzzer's bytes into `buffer` with a terminating zero, as the tokenizer expects.
fn fuzz_input(smith: *std.testing.Smith, buffer: *[input_bytes_max + 1]u8) [:0]const u8 {
    const length = smith.slice(buffer[0..input_bytes_max]);
    assert(length <= input_bytes_max);
    buffer[length] = 0;
    // The tokenizer treats an embedded zero as the end; cut there so lengths agree.
    const end = std.mem.indexOfScalar(u8, buffer[0..length], 0) orelse length;
    assert(end <= length);
    return buffer[0..end :0];
}

/// The new loader (P3.1): any bytes either load into a program that passes its check, or
/// return an error.
fn load_json_new(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const json = fuzz_input(smith, &buffer);
    assert(json.len <= input_bytes_max);
    var program = ink_json.load(std.testing.allocator, json) catch return;
    defer program.deinit(std.testing.allocator);
    assert(program.check() == .ok);
}

test "fuzz: the JSON loader never crashes" {
    try std.testing.fuzz({}, load_json_new, .{ .corpus = &json_corpus });
}

const Story = @import("runtime/story.zig").Story;
const new_save = @import("runtime/save.zig");
const new_load = @import("runtime/load.zig");

/// The new runtime's load_json (P6.2): any bytes either load into a state that passes its
/// check, or fail and leave the state as it was.
fn load_save_new(_: void, smith: *std.testing.Smith) anyerror!void {
    assert(json_corpus[0].len > 0);
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const save = fuzz_input(smith, &buffer);
    const gpa = std.testing.allocator;
    var program = try ink_json.load(gpa, json_corpus[0]);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    const before = story.state.hash();
    new_load.load_json(&story, save) catch {
        try std.testing.expectEqual(before, story.state.hash());
        return;
    };
    assert(story.state.check() == .ok);
}

test "fuzz: the save loader never crashes" {
    var good: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&good);
    var program = try ink_json.load(std.testing.allocator, json_corpus[0]);
    defer program.deinit(std.testing.allocator);
    var story: Story = undefined;
    try story.init(std.testing.allocator, &program, .{});
    defer story.deinit(std.testing.allocator);
    try new_save.to_json(&story, &writer);
    try std.testing.fuzz({}, load_save_new, .{ .corpus = &.{ "{}", writer.buffered() } });
}

const NextTokenizer = @import("compiler/tokenizer.zig");

/// The new tokenizer (P7.1): in any mode sequence, every token but eof consumes input, so it
/// ends with eof at the input's end.
fn tokenize_next(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const source = fuzz_input(smith, &buffer);
    var tokenizer: NextTokenizer.Tokenizer = .init(source);
    var tokens: u32 = 0;
    while (tokens <= source.len + 1) : (tokens += 1) {
        const mode: NextTokenizer.Mode = @fromBackingInt(@intCast(smith.value(u8) % 5));
        const token = tokenizer.next(mode);
        assert(token.start <= token.end and token.end <= source.len);
        if (token.tag == .eof) {
            assert(token.start == source.len);
            return;
        }
    }
    return error.TokenizerDidNotTerminate;
}

test "fuzz: the tokenizer ends in every mode" {
    try std.testing.fuzz({}, tokenize_next, .{ .corpus = &ink_corpus });
}

const compile = @import("compiler/compile.zig");

/// The new compiler (P7, P8): any source either compiles or returns an error.
fn compile_all(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const source = fuzz_input(smith, &buffer);
    assert(source.len <= input_bytes_max);
    var program = compile.compile_source(std.testing.allocator, source) catch return;
    defer program.deinit(std.testing.allocator);
    assert(program.containers.len > 0);
}

test "fuzz: the compiler never crashes" {
    try std.testing.fuzz({}, compile_all, .{ .corpus = &ink_corpus });
}

const program_image = @import("core/program_image.zig");

/// The binary program image loader (P10.5): any bytes either load into a program that passes
/// its check, or return a named error.
fn load_image(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const length = smith.slice(buffer[0..input_bytes_max]);
    assert(length <= input_bytes_max);
    var program = program_image.load(std.testing.allocator, buffer[0..length]) catch return;
    defer program.deinit(std.testing.allocator);
    assert(program.check() == .ok);
}

test "fuzz: the program image loader never crashes" {
    // The corpus: images of the ink corpus' stories, small enough for the input limit.
    const gpa = std.testing.allocator;
    var images: [ink_corpus.len][]u8 = undefined;
    var count: usize = 0;
    defer for (images[0..count]) |image| gpa.free(image);
    for (ink_corpus) |source| {
        // Some corpus sources are fragments the compiler rejects; they have no image.
        var program = compile.compile_source(gpa, source) catch continue;
        defer program.deinit(gpa);
        var image: std.Io.Writer.Allocating = .init(gpa);
        errdefer image.deinit();
        try program_image.write(&program, &image.writer);
        if (image.written().len > input_bytes_max) {
            image.deinit();
            continue;
        }
        images[count] = try image.toOwnedSlice();
        count += 1;
    }
    assert(count > 0);
    const corpus: []const []const u8 = images[0..count];
    try std.testing.fuzz({}, load_image, .{ .corpus = corpus });
}

/// A valid image, mutated by the fuzzer (P10.7). Random bytes rarely pass the image's magic, so
/// the raw target stops at the header; here every input starts valid, and the fuzzer picks
/// what to change: an aligned word, a byte, a bit, or the length.
const Mutation = enum { word, byte, bit, truncate };
const mutations_max = 16;

fn load_mutated_image(image: []const u8, smith: *std.testing.Smith) anyerror!void {
    assert(image.len >= 8);
    assert(image.len % 4 == 0);
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, image);
    defer gpa.free(bytes);
    var length = bytes.len;
    var count: u32 = 0;
    while (count < mutations_max and length > 0 and !smith.eos()) : (count += 1) {
        switch (smith.value(Mutation)) {
            .word => {
                const word = smith.index(length / 4);
                std.mem.writeInt(u32, bytes[word * 4 ..][0..4], smith.value(u32), .little);
            },
            .byte => bytes[smith.index(length)] = smith.value(u8),
            .bit => bytes[smith.index(length)] ^= @as(u8, 1) << smith.value(u3),
            .truncate => length = smith.index(length),
        }
        if (length < 4) break;
    }
    assert(length <= bytes.len);
    var program = program_image.load(gpa, bytes[0..length]) catch return;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
}

test "fuzz: a mutated program image loads or is rejected" {
    // The base image: a story with knots, choices, variables, lists and an external, so that
    // every section has elements to mutate. The empty input leaves it valid.
    const gpa = std.testing.allocator;
    const source =
        \\EXTERNAL roll(sides)
        \\LIST mood = calm, (angry)
        \\VAR x = 5
        \\Hello {x}. # tag
        \\* [Go] -> knot
        \\=== knot ===
        \\~ x = roll(6)
        \\{mood ? angry: Grr|Fine} -> END
        \\=== function roll(sides) ===
        \\~ return 4
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(&program, &image.writer);
    var loaded = try program_image.load(gpa, image.written());
    defer loaded.deinit(gpa);
    assert(loaded.check() == .ok);
    try std.testing.fuzz(image.written(), load_mutated_image, .{ .corpus = &.{""} });
}

// One target per pipeline stage (plan P11), each in its own file.
test {
    _ = @import("fuzz/source.zig");
}
