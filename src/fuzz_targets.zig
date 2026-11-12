//! Fuzz targets (plan P0.9), run with `zig build fuzz`: each one runs once on its seed corpus.
//! `zig build fuzz --fuzz` starts Zig's fuzzer on them. They target the old runtime and
//! compiler for now; the new code gets the same targets as it lands (P3.1, P6.2, P7.1).
//!
//! A target fails when the code under test crashes. Returning an error is fine: malformed input
//! must be rejected, never trusted.

const std = @import("std");
const assert = std.debug.assert;
const Tokenizer = @import("compiler/tokenizer.zig").Tokenizer;
const parser = @import("compiler/parser.zig");
const Story = @import("runtime/story.zig").Story;
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

fn tokenize_all(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const source = fuzz_input(smith, &buffer);
    assert(source.len <= input_bytes_max);
    var tokenizer = Tokenizer.init(source);
    var tokens: u32 = 0;
    // Every token consumes at least one byte, apart from the final end-of-input token.
    while (tokens <= source.len + 1) : (tokens += 1) {
        const token = tokenizer.next();
        assert(token.loc.start <= source.len);
        if (token.tag == .eof) return;
    }
    return error.TokenizerDidNotTerminate;
}

fn parse_all(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const source = fuzz_input(smith, &buffer);
    assert(source.len <= input_bytes_max);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = parser.parse(arena.allocator(), source) catch return;
    assert(source.len <= input_bytes_max);
}

fn load_json(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const json = fuzz_input(smith, &buffer);
    assert(json.len <= input_bytes_max);
    var story = Story.initFromJson(std.testing.allocator, json) catch return;
    defer story.deinit();
    assert(json.len > 0);
}

/// Loads arbitrary bytes as a save into a valid story.
fn load_save(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const save = fuzz_input(smith, &buffer);
    assert(json_corpus[0].len > 0);
    var story = try Story.initFromJson(std.testing.allocator, json_corpus[0]);
    defer story.deinit();
    story.loadStateFromJson(save) catch return;
    assert(save.len <= input_bytes_max);
}

/// Plays a valid story a fuzzed number of steps, saves, loads the save into a fresh story
/// and saves again; both saves must be equal.
fn save_round_trip(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var story = try Story.initFromJson(gpa, json_corpus[0]);
    defer story.deinit();
    var continues = smith.value(u8) % 4;
    assert(continues < 4);
    while (continues > 0 and story.canContinue()) : (continues -= 1) gpa.free(try story.cont());
    const first = try story.toJson(gpa);
    defer gpa.free(first);
    var fresh = try Story.initFromJson(gpa, json_corpus[0]);
    defer fresh.deinit();
    try fresh.loadStateFromJson(first);
    const second = try fresh.toJson(gpa);
    defer gpa.free(second);
    assert(first.len > 0);
    try std.testing.expectEqualStrings(first, second);
}

test "fuzz: tokenizer terminates on any input" {
    try std.testing.fuzz({}, tokenize_all, .{ .corpus = &ink_corpus });
}

test "fuzz: parser never crashes" {
    try std.testing.fuzz({}, parse_all, .{ .corpus = &ink_corpus });
}

test "fuzz: JSON loader never crashes" {
    try std.testing.fuzz({}, load_json, .{ .corpus = &json_corpus });
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

test "fuzz: new JSON loader never crashes" {
    try std.testing.fuzz({}, load_json_new, .{ .corpus = &json_corpus });
}

test "fuzz: loading a save never crashes" {
    try std.testing.fuzz({}, load_save, .{ .corpus = &.{"{}"} });
}

test "fuzz: a save survives a round trip" {
    try std.testing.fuzz({}, save_round_trip, .{ .corpus = &.{ "\x00", "\x03" } });
}

const NewStory = @import("vm/story.zig").Story;
const new_save = @import("vm/save.zig");
const new_load = @import("vm/load.zig");

/// The new runtime's load_json (P6.2): any bytes either load into a state that passes its
/// check, or fail and leave the state as it was.
fn load_save_new(_: void, smith: *std.testing.Smith) anyerror!void {
    assert(json_corpus[0].len > 0);
    var buffer: [input_bytes_max + 1]u8 = undefined;
    const save = fuzz_input(smith, &buffer);
    const gpa = std.testing.allocator;
    var program = try ink_json.load(gpa, json_corpus[0]);
    defer program.deinit(gpa);
    var story: NewStory = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    const before = story.state.hash();
    new_load.load_json(&story, save) catch {
        try std.testing.expectEqual(before, story.state.hash());
        return;
    };
    assert(story.state.check() == .ok);
}

test "fuzz: the new runtime's save loader never crashes" {
    var good: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&good);
    var program = try ink_json.load(std.testing.allocator, json_corpus[0]);
    defer program.deinit(std.testing.allocator);
    var story: NewStory = undefined;
    try story.init(std.testing.allocator, &program, .{});
    defer story.deinit(std.testing.allocator);
    try new_save.to_json(&story, &writer);
    try std.testing.fuzz({}, load_save_new, .{ .corpus = &.{ "{}", writer.buffered() } });
}
