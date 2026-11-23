//! The swarm's mutate target (P19.3): the ground-truth stories as seeds. Each seed picks a
//! story and applies a few seeded mutations (lines, knots and choices deleted, duplicated or
//! swapped, literals and divert targets changed, ink tokens put in, bytes cut out), so the
//! compiler meets code it was written for, broken in the ways people break it, and reports
//! the diagnostics and recovers where the generator's own grammar never goes.
//!
//! The sources are read from disk once per run (`Corpus.load`, from the repository root),
//! not embedded.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("cases.zig");
const fuzz_ink = @import("fuzz_ink.zig");
const Choices = fuzz_ink.Choices;

/// The ground-truth stories' sources, by case id.
pub const Corpus = struct {
    ids: []const []const u8,
    sources: []const []const u8,

    /// The sources of the ground-truth cases (`cases.ids`), read into `arena`.
    pub fn load(arena: std.mem.Allocator, io: std.Io) !Corpus {
        return load_ids(arena, io, try cases.ids(arena, io));
    }

    /// The sources of cases `ids`, read into `arena`. Stories with an INCLUDE are left out:
    /// `compile_source` has no files to include (P19.4 covers them).
    pub fn load_ids(arena: std.mem.Allocator, io: std.Io, ids: []const []const u8) !Corpus {
        var kept_ids: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList([]const u8) = .empty;
        for (ids) |id| {
            const path = try cases.source_path(arena, io, id);
            const limit: std.Io.Limit = .limited(fuzz_ink.source_bytes_max);
            const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err|
                switch (err) {
                    error.StreamTooLong => continue,
                    else => return err,
                };
            if (std.mem.indexOf(u8, source, "INCLUDE ") != null) continue;
            try kept_ids.append(arena, id);
            try sources.append(arena, source);
        }
        if (kept_ids.items.len == 0) return error.EmptyCorpus;
        assert(kept_ids.items.len == sources.items.len);
        return .{ .ids = kept_ids.items, .sources = sources.items };
    }
};

pub const Mutation = enum {
    delete_line,
    duplicate_line,
    swap_lines,
    /// A knot or stitch: from its `=` header to the next one.
    delete_section,
    duplicate_section,
    swap_sections,
    /// A line that starts with `*` or `+`.
    delete_choice,
    duplicate_choice,
    /// `*` to `+` and back.
    toggle_sticky,
    /// A run of digits, to another number.
    change_number,
    /// `true` to `false` and back.
    flip_bool,
    /// The name after a `->`, to another name of the story, END, DONE or one it doesn't have.
    change_divert,
    /// A word, to another word of the story or one it doesn't have.
    change_name,
    /// A piece of ink syntax at a drawn place.
    insert_token,
    /// Up to 32 bytes.
    delete_bytes,
    /// The source from a drawn place on.
    truncate,
};

/// The mutations a seed applies at most.
pub const mutations_max = 4;

/// A seed's mutated story.
pub const Mutant = struct {
    id: []const u8,
    source: []const u8,
    applied: [mutations_max]Mutation = undefined,
    applied_count: u8 = 0,

    pub fn mutations(mutant: *const Mutant) []const Mutation {
        return mutant.applied[0..mutant.applied_count];
    }

    pub fn format(mutant: Mutant, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} with", .{mutant.id});
        if (mutant.applied_count == 0) return writer.writeAll(" none");
        for (mutant.mutations(), 0..) |mutation, index| {
            try writer.print("{s}{t}", .{ if (index == 0) " " else ", ", mutation });
        }
    }
};

/// Where a mutant is built: two buffers the mutations write in turn.
pub const Buffers = struct {
    a: [fuzz_ink.source_bytes_max]u8,
    b: [fuzz_ink.source_bytes_max]u8,
};

/// Mixed into the seed, so the mutations don't repeat the play plan's draws.
const salt = 0x3d7a_9e11;

/// Seed `seed`'s mutant: one of `corpus`'s stories with one to `mutations_max` mutations.
/// A mutation that doesn't apply (no knots to swap) or wouldn't fit the buffer is left out.
pub fn mutate(corpus: *const Corpus, seed: u64, buffers: *Buffers) Mutant {
    assert(corpus.ids.len > 0);
    var prng: std.Random.DefaultPrng = .init(seed ^ salt);
    const choices: Choices = .{ .random = prng.random() };
    const index = choices.below(corpus.ids.len);
    var mutant: Mutant = .{ .id = corpus.ids[index], .source = corpus.sources[index] };
    var count: u32 = 1;
    while (count < mutations_max and choices.more(1, 1)) count += 1;
    for (0..count) |_| {
        const mutation = choices.choose(Mutation);
        const output = if (mutant.source.ptr == &buffers.a) &buffers.b else &buffers.a;
        var writer: std.Io.Writer = .fixed(output);
        const applied = apply(choices, mutation, mutant.source, &writer) catch false;
        if (!applied) continue;
        mutant.source = writer.buffered();
        mutant.applied[mutant.applied_count] = mutation;
        mutant.applied_count += 1;
    }
    assert(mutant.source.len <= fuzz_ink.source_bytes_max);
    return mutant;
}

/// Writes `text` with `mutation` applied; false when it doesn't apply to `text`.
fn apply(
    choices: Choices,
    mutation: Mutation,
    text: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!bool {
    switch (mutation) {
        .delete_line, .duplicate_line, .swap_lines => {
            const first = pick(choices, text, .line) orelse return false;
            if (mutation == .swap_lines) {
                return swap(text, first, pick(choices, text, .line).?, writer);
            }
            return copy_or_drop(text, first, mutation == .duplicate_line, writer);
        },
        .delete_section, .duplicate_section, .swap_sections => {
            const first = pick(choices, text, .section) orelse return false;
            if (mutation == .swap_sections) {
                return swap(text, first, pick(choices, text, .section).?, writer);
            }
            return copy_or_drop(text, first, mutation == .duplicate_section, writer);
        },
        .delete_choice, .duplicate_choice => {
            const span = pick(choices, text, .choice) orelse return false;
            return copy_or_drop(text, span, mutation == .duplicate_choice, writer);
        },
        .toggle_sticky => {
            const span = pick(choices, text, .choice) orelse return false;
            const at = span.start + leading_space(text[span.start..span.end]);
            const marker: []const u8 = if (text[at] == '*') "+" else "*";
            return replace(text, Span.of(at, at + 1), marker, writer);
        },
        .change_number => {
            const span = pick(choices, text, .number) orelse return false;
            return replace(text, span, numbers[choices.below(numbers.len)], writer);
        },
        .flip_bool => {
            const span = pick(choices, text, .boolean) orelse return false;
            const flipped = if (text[span.start] == 't') "false" else "true";
            return replace(text, span, flipped, writer);
        },
        .change_divert => {
            const span = pick(choices, text, .divert_target) orelse return false;
            const others = &.{ "END", "DONE", "nowhere", "", "->", "0", "a.b.c" };
            return replace(text, span, other_name(choices, text, others), writer);
        },
        .change_name => {
            const span = pick(choices, text, .identifier) orelse return false;
            const others = &.{ "nowhere", "x", "ref", "not", "END", "a.b" };
            return replace(text, span, other_name(choices, text, others), writer);
        },
        .insert_token => {
            const at = choices.below(text.len + 1);
            const token = tokens[choices.below(tokens.len)];
            return replace(text, Span.of(at, at), token, writer);
        },
        .delete_bytes => {
            if (text.len == 0) return false;
            const start = choices.below(text.len);
            const length = 1 + choices.below(@min(32, text.len - start));
            return replace(text, Span.of(start, start + length), "", writer);
        },
        .truncate => {
            if (text.len == 0) return false;
            const at = choices.below(text.len);
            return replace(text, Span.of(at, text.len), "", writer);
        },
    }
}

/// What `change_number` puts in a number's place: small, large, out of range, a float, gone.
const numbers = [_][]const u8{
    "0", "1", "-1", "2", "7", "100", "0.5", "1.0", "2147483647", "99999999999", "", "-",
};

/// The ink syntax `insert_token` puts in.
const tokens = [_][]const u8{
    "{",              "}",                 "->",        "<-",                      "->->",
    "~ ",             "* ",                "+ ",        "- ",                      "=== k ===\n",
    "= s\n",          "(",                 ")",         "|",                       ":",
    "#",              "[",                 "]",         "\"",                      "VAR x = 1\n",
    "CONST c = 2\n",  "LIST l = a, (b)\n", "<>",        "TODO: x\n",               "//",
    "/*",             "*/",                "\n",        "{x:",                     "else:",
    "EXTERNAL f()\n", "&",                 "!",         "^",                       "?",
    "\\",             "function",          "ref ",      "~ return\n",              "~ temp t = ",
    "\t",             "\u{e9}",            "{~",        "{&",                      "{!",
    "{stopping:",     "->-> x\n",          "-> x ->\n", "=== function f(x) ===\n", ".",
    "&&",             "==",                "!=",        "+=",                      "--",
    "not ",           "has ",              "\"a\" + ",  "RANDOM(",                 "TURNS_SINCE(",
};

/// A byte range of the text, `end` exclusive (a text is at most `source_bytes_max` long).
const Span = struct {
    start: u32,
    end: u32,

    fn of(start: usize, end: usize) Span {
        assert(start <= end and end <= fuzz_ink.source_bytes_max);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }
};

const Unit = enum { line, section, choice, number, boolean, divert_target, identifier };

/// One of `text`'s `unit`s, drawn evenly, or null when it has none.
fn pick(choices: Choices, text: []const u8, unit: Unit) ?Span {
    const count = scan(text, unit, null);
    if (count == 0) return null;
    var span: Span = undefined;
    const found = scan(text, unit, .{ .index = @intCast(choices.below(count)), .span = &span });
    assert(found == count);
    return span;
}

const Wanted = struct { index: u32, span: *Span };

/// How many `unit`s `text` has; with `wanted`, also the span of the one at its index.
fn scan(text: []const u8, unit: Unit, wanted: ?Wanted) usize {
    var count: usize = 0;
    var at: usize = 0;
    // A section runs from one header line to the next.
    var section_start: ?usize = null;
    while (at < text.len) {
        const span = next_unit(text, unit, at) orelse break;
        assert(span.end >= span.start and span.end <= text.len);
        at = @max(span.end, span.start + 1);
        if (unit == .section) {
            if (section_start) |start| {
                keep(wanted, count, Span.of(start, span.start));
                count += 1;
            }
            section_start = span.start;
        } else {
            keep(wanted, count, span);
            count += 1;
        }
    }
    if (section_start) |start| {
        keep(wanted, count, Span.of(start, text.len));
        count += 1;
    }
    return count;
}

fn keep(wanted: ?Wanted, index: usize, span: Span) void {
    const want = wanted orelse return;
    if (want.index == index) want.span.* = span;
}

/// The first `unit` at or after `from` (for sections, the next header line).
fn next_unit(text: []const u8, unit: Unit, from: usize) ?Span {
    switch (unit) {
        .line, .section, .choice => {
            var start = from;
            while (start < text.len) {
                const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline|
                    newline + 1
                else
                    text.len;
                const line = text[start..end];
                const first = std.mem.trimStart(u8, line, " \t");
                const wanted = switch (unit) {
                    .line => true,
                    .section => first.len > 0 and first[0] == '=',
                    .choice => first.len > 0 and (first[0] == '*' or first[0] == '+'),
                    else => unreachable,
                };
                if (wanted) return Span.of(start, end);
                start = end;
            }
            return null;
        },
        .number => {
            const start = std.mem.indexOfAnyPos(u8, text, from, "0123456789") orelse return null;
            var end = start;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            return Span.of(start, end);
        },
        .boolean => {
            var at = from;
            while (at < text.len) : (at += 1) {
                const rest = text[at..];
                const length: usize = if (std.mem.startsWith(u8, rest, "true"))
                    4
                else if (std.mem.startsWith(u8, rest, "false"))
                    5
                else
                    continue;
                if (word_at(text, at, at + length)) return Span.of(at, at + length);
            }
            return null;
        },
        .divert_target => {
            const arrow = std.mem.indexOfPos(u8, text, from, "->") orelse return null;
            var start = arrow + 2;
            while (start < text.len and text[start] == ' ') start += 1;
            var end = start;
            while (end < text.len and (identifier_byte(text[end]) or text[end] == '.')) end += 1;
            return Span.of(start, end);
        },
        .identifier => {
            // A word that starts with a letter, not the rest of one that starts otherwise.
            var start = from;
            while (start < text.len) {
                if (!std.ascii.isAlphabetic(text[start])) {
                    start += 1;
                    continue;
                }
                var end = start;
                while (end < text.len and identifier_byte(text[end])) end += 1;
                if (start == 0 or !identifier_byte(text[start - 1])) {
                    return Span.of(start, end);
                }
                start = end;
            }
            return null;
        },
    }
}

/// A word of `text`, or one of `others`.
fn other_name(choices: Choices, text: []const u8, others: []const []const u8) []const u8 {
    assert(others.len > 0);
    if (choices.choose(bool)) {
        if (pick(choices, text, .identifier)) |span| return text[span.start..span.end];
    }
    return others[choices.below(others.len)];
}

fn identifier_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether `text[start..end]` is a whole word.
fn word_at(text: []const u8, start: usize, end: usize) bool {
    if (start > 0 and identifier_byte(text[start - 1])) return false;
    if (end < text.len and identifier_byte(text[end])) return false;
    return true;
}

fn leading_space(line: []const u8) usize {
    return line.len - std.mem.trimStart(u8, line, " \t").len;
}

fn replace(text: []const u8, span: Span, with: []const u8, writer: *std.Io.Writer) !bool {
    assert(span.start <= span.end and span.end <= text.len);
    try writer.writeAll(text[0..span.start]);
    try writer.writeAll(with);
    try writer.writeAll(text[span.end..]);
    return true;
}

/// `text` without `span`, or with it twice.
fn copy_or_drop(text: []const u8, span: Span, twice: bool, writer: *std.Io.Writer) !bool {
    try writer.writeAll(text[0..if (twice) span.end else span.start]);
    try writer.writeAll(text[if (twice) span.start else span.end..]);
    return true;
}

/// `text` with two spans (each a whole line or section, so they don't overlap) swapped.
fn swap(text: []const u8, a: Span, b: Span, writer: *std.Io.Writer) !bool {
    if (a.start == b.start) return false;
    const first = if (a.start < b.start) a else b;
    const second = if (a.start < b.start) b else a;
    assert(first.end <= second.start);
    try writer.writeAll(text[0..first.start]);
    try writer.writeAll(text[second.start..second.end]);
    try writer.writeAll(text[first.end..second.start]);
    try writer.writeAll(text[first.start..first.end]);
    try writer.writeAll(text[second.end..]);
    return true;
}

test "a seed's mutant is the same every time, and the seeds apply every mutation" {
    // P19.3: the same seed mutates the same story the same way; over 400 seeds every
    // mutation applies to a story with knots, choices, numbers, booleans and diverts.
    const source =
        \\VAR flag = true
        \\-> knot_with_options ->
        \\Finished {1 + 2} tunnel.
        \\* E
        \\-
        \\== knot_with_options ==
        \\= stitch
        \\+ A
        \\* B {flag}
        \\- ->->
        \\== thread_with_options ==
        \\~ flag = false
        \\- -> DONE
        \\
    ;
    const corpus: Corpus = .{ .ids = &.{"story"}, .sources = &.{source} };
    var first: Buffers = undefined;
    var second: Buffers = undefined;
    var applied: std.EnumSet(Mutation) = .empty;
    var changed: u32 = 0;
    for (0..400) |seed| {
        const a = mutate(&corpus, seed, &first);
        const b = mutate(&corpus, seed, &second);
        try std.testing.expectEqualStrings(a.source, b.source);
        try std.testing.expectEqualSlices(Mutation, a.mutations(), b.mutations());
        try std.testing.expect(a.mutations().len <= mutations_max);
        for (a.mutations()) |mutation| applied.insert(mutation);
        if (!std.mem.eql(u8, a.source, source)) changed += 1;
    }
    try std.testing.expect(applied.eql(.full));
    try std.testing.expect(changed > 350);
}

test "mutations that don't apply are left out, and a full buffer keeps the story" {
    var buffers: Buffers = undefined;
    const empty: Corpus = .{ .ids = &.{"empty"}, .sources = &.{""} };
    for (0..64) |seed| {
        // Only a token goes into nothing; the mutations after it have its text.
        const mutant = mutate(&empty, seed, &buffers);
        if (mutant.applied_count == 0) continue;
        try std.testing.expectEqual(.insert_token, mutant.mutations()[0]);
    }
    // Diverts without a word to put in their place take one of the made-up names.
    const arrows: Corpus = .{ .ids = &.{"arrows"}, .sources = &.{"-> ->\n->->\n"} };
    for (0..256) |seed| _ = mutate(&arrows, seed, &buffers);
    // A story as long as the buffer: nothing that adds bytes fits.
    const long: [fuzz_ink.source_bytes_max]u8 = @splat('x');
    const full: Corpus = .{ .ids = &.{"full"}, .sources = &.{&long} };
    for (0..64) |seed| {
        const mutant = mutate(&full, seed, &buffers);
        try std.testing.expect(mutant.source.len <= long.len);
    }
}

test "the corpus reads a case's source from disk" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = "runtime/diverts/tunnel_vs_thread_behaviour";
    const corpus = try Corpus.load_ids(arena, std.testing.io, &.{id});
    try std.testing.expectEqual(@as(usize, 1), corpus.ids.len);
    const header = "== knot_with_options ==";
    try std.testing.expect(std.mem.indexOf(u8, corpus.sources[0], header) != null);
}
