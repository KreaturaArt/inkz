//! Structure-aware fuzz target for the JSON loader. Random bytes rarely make
//! JSON, so the raw target stops in the tokenizer; here every input starts as a valid ink
//! JSON (a generated story, compiled and serialized), and the fuzzer edits its tokens:
//! replaces a number or a string (with ink's control words among the choices), deletes or
//! duplicates a token, swaps a bracket, or cuts the text short. Each input first draws its
//! operators (a swarm over operators, plan §3.6); the save target uses the same ones.

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

pub const Mutation = enum {
    number,
    string,
    word,
    delete,
    duplicate,
    bracket,
    truncate,
    /// A token replaced by a boundary number: 0, -1, the extremes of i32 and u32.
    number_boundary,
    /// A token replaced by a name the stories use (a variable, knot, list item or flow).
    pool_name,
    /// An object key (a string before `:`) replaced by another key or name.
    key_rename,
};

pub const Mutations = std.EnumSet(Mutation);

const numbers_boundary = [_][]const u8{
    "0", "-1", "2147483647", "-2147483648", "4294967295", "4294967296", "1e40",
};
const names = [_][]const u8{
    "\"v0\"",  "\"k0\"",  "\"k0.s0\"", "\"l0\"",        "\"a\"",            "\"l0.a\"", "\"c-0\"",
    "\"g-0\"", "\"0\"",   "\"s0\"",    "\"f0\"",        "\"DEFAULT_FLOW\"", "\"x\"",    "\"$r\"",
    "\"$r1\"", "\"one\"", "\"flows\"", "\"callstack\"",
};

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

/// Applies one operator from `allowed` to a token of `json`; returns it.
pub fn mutate(
    choices: fuzz_ink.Choices,
    gpa: Allocator,
    json: *std.ArrayList(u8),
    spans: []const Span,
    allowed: Mutations,
) !Mutation {
    const mutation = fuzz_ink.pick_from(choices, Mutation, allowed);
    const span = if (mutation == .key_rename)
        key_span(choices, json.items, spans) orelse return mutation
    else
        spans[choices.below(spans.len)];
    assert(span.end <= json.items.len);
    const range = .{ span.start, span.end - span.start };
    switch (mutation) {
        .number => {
            var text: [16]u8 = undefined;
            const value = choices.choose(i32);
            const number = std.fmt.bufPrint(&text, "{d}", .{value}) catch unreachable;
            try json.replaceRange(gpa, range[0], range[1], number);
        },
        .string => {
            const string = strings[choices.below(strings.len)];
            try json.replaceRange(gpa, range[0], range[1], string);
        },
        .word => try json.replaceRange(gpa, range[0], range[1], words[choices.below(words.len)]),
        .number_boundary => {
            const number = numbers_boundary[choices.below(numbers_boundary.len)];
            try json.replaceRange(gpa, range[0], range[1], number);
        },
        .pool_name, .key_rename => {
            const pool = if (choices.choose(bool)) &names else &strings;
            try json.replaceRange(gpa, range[0], range[1], pool[choices.below(pool.len)]);
        },
        .delete => try json.replaceRange(gpa, range[0], range[1], ""),
        .duplicate => {
            var copy: [64]u8 = undefined;
            const length = @min(range[1], copy.len);
            @memcpy(copy[0..length], json.items[range[0]..][0..length]);
            try json.insertSlice(gpa, range[0], copy[0..length]);
        },
        .bracket => {
            const brackets = "{}[]";
            json.items[range[0]] = brackets[choices.below(brackets.len)];
        },
        .truncate => json.shrinkRetainingCapacity(range[0]),
    }
    return mutation;
}

/// One of the object keys (a string token followed by `:`), or null when there is none.
fn key_span(choices: fuzz_ink.Choices, json: []const u8, spans: []const Span) ?Span {
    var count: usize = 0;
    for (spans[0..spans.len -| 1], spans[1..]) |span, next| {
        if (json[span.start] == '"' and json[next.start] == ':') count += 1;
    }
    if (count == 0) return null;
    var skip = choices.below(count);
    for (spans[0 .. spans.len - 1], spans[1..]) |span, next| {
        if (json[span.start] != '"' or json[next.start] != ':') continue;
        if (skip == 0) return span;
        skip -= 1;
    }
    unreachable;
}

/// Applies up to `count_max` operators from `allowed` (drawn when null) to `json`; returns
/// the operators applied.
pub fn mutate_all(
    choices: fuzz_ink.Choices,
    gpa: Allocator,
    json: *std.ArrayList(u8),
    allowed_given: ?Mutations,
    count_max: u32,
) !Mutations {
    const allowed = allowed_given orelse fuzz_ink.draw_subset(choices, Mutation);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    var applied: Mutations = .empty;
    var count: u32 = 0;
    while (count < count_max and choices.more(1, 1)) : (count += 1) {
        try token_spans(gpa, json.items, &spans);
        if (spans.items.len == 0) break;
        applied.insert(try mutate(choices, gpa, json, spans.items, allowed));
    }
    assert(applied.subsetOf(allowed));
    return applied;
}

/// Mutates a copy of `base`, loads it, and returns the operators applied. A load returns
/// a checked program or an error.
fn check_mutated(choices: fuzz_ink.Choices, base: []const u8, allowed: ?Mutations) !Mutations {
    const gpa = std.testing.allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, base);
    const applied = try mutate_all(choices, gpa, &json, allowed, mutations_max);
    var program = ink_json.load(gpa, json.items) catch return applied;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    return applied;
}

fn load_mutated_json(base: []const u8, smith: *Smith) anyerror!void {
    _ = try check_mutated(.{ .smith = smith }, base, null);
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

test "fuzz: a mutated JSON applies only the operators it drew" {
    // 1,000 seeded inputs: the operators applied are in the drawn set; then each operator
    // alone, on 16 seeds, gives a checked program or an error.
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    const source = fuzz_ink.generate_seeded(1, &buffer, .{ .swarm = .classic });
    const json = try compile.compile_to_json(gpa, source);
    defer gpa.free(json);
    for (0..1000) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        var draw_prng = prng;
        const allowed = fuzz_ink.draw_subset(.{ .random = draw_prng.random() }, Mutation);
        const applied = try check_mutated(.{ .random = prng.random() }, json, null);
        try std.testing.expect(applied.subsetOf(allowed));
    }
    for (std.enums.values(Mutation)) |mutation| {
        for (0..16) |seed| {
            var prng: std.Random.DefaultPrng = .init(seed);
            const only: Mutations = .initOne(mutation);
            const applied = try check_mutated(.{ .random = prng.random() }, json, only);
            try std.testing.expect(applied.subsetOf(only));
        }
    }
}
