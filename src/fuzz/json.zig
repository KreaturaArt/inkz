//! Structure-aware fuzz target for the JSON loader. Random bytes rarely make
//! JSON, so the raw target stops in the tokenizer; here every input starts as a valid ink
//! JSON (a generated story, compiled and serialized), and the fuzzer edits its tokens:
//! replaces a number or a string (with ink's control words among the choices), deletes or
//! duplicates a token, swaps a bracket, or cuts the text short.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");

const Allocator = std.mem.Allocator;
const mutations_max = 8;

pub const Span = struct { start: u32, end: u32 };

/// The JSON's tokens: strings, numbers and words, and single punctuation bytes.
pub fn token_spans(gpa: Allocator, json: []const u8, spans: *std.ArrayList(Span)) !void {
    spans.clearRetainingCapacity();
    var at: u32 = 0;
    while (at < json.len) {
        const start = at;
        switch (json[at]) {
            ' ', '\n', '\t', '\r' => {
                at += 1;
                continue;
            },
            '"' => {
                at += 1;
                while (at < json.len and json[at] != '"') : (at += 1) {
                    if (json[at] == '\\' and at + 1 < json.len) at += 1;
                }
                at = @min(at + 1, @as(u32, @intCast(json.len)));
            },
            '{', '}', '[', ']', ',', ':' => at += 1,
            else => {
                while (at < json.len and !is_delimiter(json[at])) at += 1;
            },
        }
        try spans.append(gpa, .{ .start = start, .end = at });
    }
    assert(at == json.len);
}

fn is_delimiter(byte: u8) bool {
    const delimiters = " \n\t\r\"{}[],:";
    assert(delimiters.len == 11);
    return std.mem.indexOfScalar(u8, delimiters, byte) != null;
}

const Mutation = enum { number, string, word, delete, duplicate, bracket, truncate };

/// ink's control words and keys, so replaced strings often still mean something.
const strings = [_][]const u8{
    "\"^text\"", "\"\\n\"",  "\"ev\"",  "\"/ev\"",  "\"out\"",   "\"pop\"",      "\"done\"",
    "\"end\"",   "\"->->\"", "\"str\"", "\"/str\"", "\"nop\"",   "\"du\"",       "\"+\"",
    "\"==\"",    "\"#\"",    "\"/#\"",  "\"<>\"",   "\"visit\"", "\"seq\"",      "\"turn\"",
    "\"#f\"",    "\"#n\"",   "\"->\"",  "\"^->\"",  "\"VAR=\"",  "\"VAR?\"",     "\"temp=\"",
    "\"f()\"",   "\"x()\"",  "\"*\"",   "\"CNT?\"", "\"c\"",     "\"var\"",      "\"re\"",
    "\"root\"",  "\"g-0\"",  "\"c-0\"", "\"knot\"", "\"\"",      "\"listDefs\"",
};
const words = [_][]const u8{ "null", "true", "false", "0", "-1", "1.5", "4294967295", "21" };

pub fn mutate(smith: *Smith, gpa: Allocator, json: *std.ArrayList(u8), spans: []const Span) !void {
    const span = spans[smith.index(spans.len)];
    assert(span.end <= json.items.len);
    const range = .{ span.start, span.end - span.start };
    switch (smith.value(Mutation)) {
        .number => {
            var text: [16]u8 = undefined;
            const number = std.fmt.bufPrint(&text, "{d}", .{smith.value(i32)}) catch unreachable;
            try json.replaceRange(gpa, range[0], range[1], number);
        },
        .string => {
            const string = strings[smith.index(strings.len)];
            try json.replaceRange(gpa, range[0], range[1], string);
        },
        .word => try json.replaceRange(gpa, range[0], range[1], words[smith.index(words.len)]),
        .delete => try json.replaceRange(gpa, range[0], range[1], ""),
        .duplicate => {
            var copy: [64]u8 = undefined;
            const length = @min(range[1], copy.len);
            @memcpy(copy[0..length], json.items[range[0]..][0..length]);
            try json.insertSlice(gpa, range[0], copy[0..length]);
        },
        .bracket => {
            const brackets = "{}[]";
            json.items[range[0]] = brackets[smith.index(brackets.len)];
        },
        .truncate => json.shrinkRetainingCapacity(range[0]),
    }
}

fn load_mutated_json(base: []const u8, smith: *Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, base);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    var count: u32 = 0;
    while (count < mutations_max and !smith.eosWeightedSimple(1, 1)) : (count += 1) {
        try token_spans(gpa, json.items, &spans);
        if (spans.items.len == 0) break;
        try mutate(smith, gpa, &json, spans.items);
    }
    assert(count <= mutations_max);
    var program = ink_json.load(gpa, json.items) catch return;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
}

test "fuzz: a mutated ink JSON loads or is rejected" {
    // The base: the first seeded story that compiles; the empty input leaves it valid.
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var seed: u64 = 0;
    const json = while (seed < 64) : (seed += 1) {
        const source = fuzz_ink.generate_seeded(seed, &buffer, .{});
        break compile.compile_to_json(gpa, source) catch continue;
    } else return error.NoSeedCompiles;
    defer gpa.free(json);
    var program = try ink_json.load(gpa, json);
    program.deinit(gpa);
    try std.testing.fuzz(@as([]const u8, json), load_mutated_json, .{ .corpus = &.{""} });
}
