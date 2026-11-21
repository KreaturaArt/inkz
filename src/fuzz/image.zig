//! Fuzz target for the program image loader: a valid image, mutated. Random bytes rarely
//! pass the image's magic, so the raw target stops at the header; here every input starts
//! valid. Each input first draws its mutation operators (a swarm over operators, plan
//! §3.6): a subset with only `word_copy` builds cross-wired but plausible records, which
//! `decodable` and `Program.check` must reject, and which the uniform mix rarely makes.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const compile = @import("../compiler/compile.zig");
const program_image = @import("../core/program_image.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");

const mutations_max = 16;

pub const Mutation = enum {
    /// An aligned word set to any value.
    word,
    /// An aligned word set to a boundary: 0, 1, the largest index, `none`, a heap
    /// reference's bit, or all ones.
    word_boundary,
    /// An aligned word copied from elsewhere in the image.
    word_copy,
    /// Two neighbouring words swapped.
    word_swap,
    byte,
    bit,
    truncate,
};

pub const Mutations = std.EnumSet(Mutation);

const boundaries = [_]u32{ 0, 1, 0x7fff_fffe, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff };

/// Applies one operator from `allowed` to `bytes[0..length.*]`; returns it.
pub fn mutate(
    choices: fuzz_ink.Choices,
    bytes: []u8,
    length: *usize,
    allowed: Mutations,
) Mutation {
    assert(length.* >= 8 and length.* <= bytes.len);
    const words = length.* / 4;
    const mutation = fuzz_ink.pick_from(choices, Mutation, allowed);
    switch (mutation) {
        .word => write_word(bytes, choices.below(words), choices.choose(u32)),
        .word_boundary => write_word(bytes, choices.below(words), boundaries[
            choices.below(boundaries.len)
        ]),
        .word_copy => {
            const from = read_word(bytes, choices.below(words));
            write_word(bytes, choices.below(words), from);
        },
        .word_swap => {
            const at = choices.below(words - 1);
            const first = read_word(bytes, at);
            write_word(bytes, at, read_word(bytes, at + 1));
            write_word(bytes, at + 1, first);
        },
        .byte => bytes[choices.below(length.*)] = choices.choose(u8),
        .bit => bytes[choices.below(length.*)] ^= @as(u8, 1) << choices.choose(u3),
        .truncate => length.* = @max(8, choices.below(length.*)),
    }
    assert(length.* >= 8);
    return mutation;
}

fn read_word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}

fn write_word(bytes: []u8, index: usize, word: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
}

/// Mutates a copy of `image` with operators from `allowed` (drawn when null), loads it, and
/// returns the operators applied. A load returns a checked program or an error.
pub fn check_mutated(
    choices: fuzz_ink.Choices,
    image: []const u8,
    allowed_given: ?Mutations,
) !Mutations {
    assert(image.len >= 8);
    assert(image.len % 4 == 0);
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, image);
    defer gpa.free(bytes);
    const allowed = allowed_given orelse fuzz_ink.draw_subset(choices, Mutation);
    var applied: Mutations = .empty;
    var length = bytes.len;
    var count: u32 = 0;
    while (count < mutations_max and choices.more(15, 1)) : (count += 1) {
        applied.insert(mutate(choices, bytes, &length, allowed));
    }
    assert(length <= bytes.len);
    var program = program_image.load(gpa, bytes[0..length]) catch return applied;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    return applied;
}

fn load_mutated_image(image: []const u8, smith: *Smith) anyerror!void {
    _ = try check_mutated(.{ .smith = smith }, image, null);
}

/// A story with knots, choices, variables, lists and an external, so that every section of
/// its image has elements to mutate.
const base_source =
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

fn base_image(gpa: std.mem.Allocator) ![]u8 {
    var program = try compile.compile_source(gpa, base_source);
    defer program.deinit(gpa);
    var image: std.Io.Writer.Allocating = .init(gpa);
    errdefer image.deinit();
    try program_image.write(&program, &image.writer);
    return image.toOwnedSlice();
}

test "fuzz: a mutated program image loads or is rejected" {
    // The base image is valid; the empty input leaves it so.
    const gpa = std.testing.allocator;
    const image = try base_image(gpa);
    defer gpa.free(image);
    var loaded = try program_image.load(gpa, image);
    defer loaded.deinit(gpa);
    assert(loaded.check() == .ok);
    try std.testing.fuzz(@as([]const u8, image), load_mutated_image, .{ .corpus = &.{""} });
}

test "fuzz: a mutated image applies only the operators it drew" {
    // 1,000 seeded inputs: the operators applied are in the drawn set; then each operator
    // alone, on 16 seeds, gives a checked program or a named error.
    const gpa = std.testing.allocator;
    const image = try base_image(gpa);
    defer gpa.free(image);
    var subsets: u32 = 0;
    for (0..1000) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const choices: fuzz_ink.Choices = .{ .random = prng.random() };
        var draw_prng = prng;
        const allowed = fuzz_ink.draw_subset(.{ .random = draw_prng.random() }, Mutation);
        const applied = try check_mutated(choices, image, null);
        try std.testing.expect(applied.subsetOf(allowed));
        if (!allowed.eql(.full)) subsets += 1;
    }
    try std.testing.expect(subsets > 800);
    for (std.enums.values(Mutation)) |mutation| {
        for (0..16) |seed| {
            var prng: std.Random.DefaultPrng = .init(seed);
            const only: Mutations = .initOne(mutation);
            const applied = try check_mutated(.{ .random = prng.random() }, image, only);
            try std.testing.expect(applied.subsetOf(only));
        }
    }
}
