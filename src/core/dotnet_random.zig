//! A bit-exact port of .NET's seeded `System.Random`. .NET 8 still uses the
//! legacy Knuth subtractive generator for `new Random(seed)`, and ink creates one per random
//! choice: `RANDOM` and `LIST_RANDOM` use `new Random(storySeed + previousRandom).Next()`, and
//! shuffles use `new Random(pathHash + loopIndex + storySeed)`. Only `Next()` is needed.

const std = @import("std");
const assert = std.debug.assert;

/// `int.MaxValue`, the generator's modulus.
const modulus: i32 = std.math.maxInt(i32);
/// The generator's fixed seed constant, from Knuth.
const seed_constant: i32 = 161_803_398;

pub const DotnetRandom = struct {
    seeds: [56]i32,
    next_index: u8,
    next_index_far: u8,

    pub fn init(seed: i32) DotnetRandom {
        // .NET maps minInt to maxInt because abs(minInt) overflows; so seeds n and -n agree.
        const subtraction: i32 = if (seed == std.math.minInt(i32))
            modulus
        else
            @intCast(@abs(seed));
        var random: DotnetRandom = .{ .seeds = @splat(0), .next_index = 0, .next_index_far = 21 };
        var mj: i32 = seed_constant -% subtraction;
        random.seeds[55] = mj;
        var mk: i32 = 1;
        var ii: u32 = 0;
        for (1..55) |_| {
            ii += 21;
            if (ii >= 55) ii -= 55;
            random.seeds[ii] = mk;
            mk = mj -% mk;
            if (mk < 0) mk +%= modulus;
            mj = random.seeds[ii];
        }
        for (1..5) |_| random.mix();
        assert(random.next_index == 0);
        assert(random.next_index_far == 21);
        return random;
    }

    /// One mixing round of the constructor.
    fn mix(random: *DotnetRandom) void {
        for (1..56) |i| {
            var n = i + 30;
            if (n >= 55) n -= 55;
            random.seeds[i] -%= random.seeds[1 + n];
            if (random.seeds[i] < 0) random.seeds[i] +%= modulus;
            assert(random.seeds[i] >= 0);
        }
        assert(random.seeds[0] == 0);
    }

    /// The next value in `[0, maxInt(i32))`, as `Random.Next()`.
    pub fn next(random: *DotnetRandom) i32 {
        var index = random.next_index + 1;
        if (index >= 56) index = 1;
        var index_far = random.next_index_far + 1;
        if (index_far >= 56) index_far = 1;
        var result = random.seeds[index] -% random.seeds[index_far];
        if (result == modulus) result -= 1;
        if (result < 0) result +%= modulus;
        random.seeds[index] = result;
        random.next_index = index;
        random.next_index_far = index_far;
        assert(result >= 0);
        assert(result < modulus);
        return result;
    }
};

comptime {
    assert(@sizeOf(DotnetRandom) <= 232);
}

test "sequences match .NET 8 for the reference seeds" {
    // Bit-exact .NET behaviour: compare the first 1000 values for each
    // seed in test/ground_truth/dotnet_random.expected, generated on .NET 8 by the harness.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "test/ground_truth/dotnet_random.expected";
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var seeds_checked: u32 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        try std.testing.expectEqualStrings("seed", words.next().?);
        const seed_text = std.mem.trimEnd(u8, words.next().?, ":");
        var random = DotnetRandom.init(try std.fmt.parseInt(i32, seed_text, 10));
        var values: u32 = 0;
        while (words.next()) |word| : (values += 1) {
            try std.testing.expectEqual(try std.fmt.parseInt(i32, word, 10), random.next());
        }
        try std.testing.expectEqual(@as(u32, 1000), values);
        seeds_checked += 1;
    }
    try std.testing.expectEqual(@as(u32, 7), seeds_checked);
}

test "negative seeds behave like their absolute value" {
    // The documented .NET quirk that ink inherits: compare seeds 5 and -5.
    var positive = DotnetRandom.init(5);
    var negative = DotnetRandom.init(-5);
    for (0..10) |_| try std.testing.expectEqual(positive.next(), negative.next());
}
