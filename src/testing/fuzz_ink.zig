//! An ink source generator for the fuzz targets. The fuzzer's choices, read
//! through `std.testing.Smith`, pick each construct, so the fuzzer explores ink instead of
//! bytes: knots, stitches, functions, declarations, text, glue, tags, choices, gathers,
//! diverts, tunnels, threads, conditionals, sequences, expressions and assignments.
//!
//! Every name comes from a small pool that the generator declares (knots `k0`–`k2`, stitch
//! `k0.s0`, functions `f0(x)`, `f1()` and the external `e0(x)` with its fallback, variables
//! `v0`–`v2`, `c0` and the list `l0`), so most sources parse and resolve and reach the later
//! stages. The fuzzer can still drop a declaration or splice raw bytes in, for the stages that
//! must reject broken input. Nothing recurses: expressions are flat chains of terms, and
//! nesting is bounded by a depth counter.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;

/// Enough for the largest source the bounds below allow.
pub const source_bytes_max = 32 * 1024;
const lines_max = 10;
const terms_max = 4;
const choice_depth_max = 3;
const knots_count = 3;

pub const Options = struct {
    /// Let the fuzzer splice raw bytes into the source (for the parser's targets).
    splices: bool = false,
};

const Line = enum {
    text,
    text_inline,
    tag,
    glue,
    choice,
    gather,
    divert,
    tunnel,
    thread,
    assignment,
    block,
};

const Term = enum {
    integer,
    float,
    string,
    boolean,
    variable,
    constant,
    call,
    call_external,
    random,
    visits,
    turns_since,
    list,
    list_query,
    choice_count,
    negate,
};

const binary_operators = [_][]const u8{
    " + ",   " - ",  " * ", " / ",  " % ",   " == ", " != ", " < ", " > ", " <= ", " >= ",
    " and ", " or ", " ? ", " !? ", " has ",
};
const words = [_][]const u8{ "Hello", "the cat", "a", "", "!", "  spaced  ", "x\\{y\\}" };
const targets = [_][]const u8{ "k0", "k1", "k2", "k0.s0", "END", "DONE" };
const variables = [_][]const u8{ "v0", "v1", "v2" };

/// Where the generator's choices come from: the fuzzer's Smith, or a seeded PRNG (for unit
/// tests and seed corpora). The methods are inline so that each Smith call keeps its own call
/// site, which the fuzzer uses to tell the choices apart.
pub const Choices = union(enum) {
    smith: *Smith,
    random: std.Random,

    pub inline fn choose(choices: Choices, T: type) T {
        comptime assert(@bitSizeOf(T) <= 64);
        comptime assert(@typeInfo(T) != .float);
        return switch (choices) {
            .smith => |smith| smith.value(T),
            .random => |random| switch (@typeInfo(T)) {
                .@"enum" => random.enumValue(T),
                .bool => random.boolean(),
                else => random.int(T),
            },
        };
    }

    pub inline fn below(choices: Choices, len: usize) usize {
        assert(len > 0);
        return switch (choices) {
            .smith => |smith| smith.index(len),
            .random => |random| random.uintLessThan(usize, len),
        };
    }

    pub inline fn range(choices: Choices, T: type, at_least: T, at_most: T) T {
        comptime assert(@typeInfo(T) == .int);
        assert(at_least <= at_most);
        return switch (choices) {
            .smith => |smith| smith.valueRangeAtMost(T, at_least, at_most),
            .random => |random| random.intRangeAtMost(T, at_least, at_most),
        };
    }

    /// True with weight `true_weight` against `false_weight`.
    pub inline fn weighted(choices: Choices, false_weight: u64, true_weight: u64) bool {
        assert(false_weight > 0);
        assert(true_weight > 0);
        return switch (choices) {
            .smith => |smith| smith.boolWeighted(false_weight, true_weight),
            .random => |random| random.uintLessThan(u64, false_weight + true_weight) >=
                false_weight,
        };
    }

    /// Whether a loop goes on: the end has weight `end_weight` against `more_weight`.
    pub inline fn more(choices: Choices, more_weight: u64, end_weight: u64) bool {
        assert(more_weight > 0);
        assert(end_weight > 0);
        return switch (choices) {
            .smith => |smith| !smith.eosWeightedSimple(more_weight, end_weight),
            .random => |random| random.uintLessThan(u64, more_weight + end_weight) <
                more_weight,
        };
    }

    /// Fills a prefix of `buffer` and returns its length.
    pub inline fn fill(choices: Choices, buffer: []u8) usize {
        switch (choices) {
            .smith => |smith| return smith.slice(buffer),
            .random => |random| {
                const length = random.uintAtMost(usize, buffer.len);
                random.bytes(buffer[0..length]);
                return length;
            },
        }
    }
};

pub const Generator = struct {
    choices: Choices,
    writer: std.Io.Writer,
    /// Unique label suffixes for choices and gathers.
    labels: u32 = 0,

    /// Writes one source into `buffer` and returns it (cut short if the buffer is full).
    pub fn generate(choices: Choices, buffer: []u8, options: Options) []const u8 {
        assert(buffer.len >= 1024);
        var generator: Generator = .{ .choices = choices, .writer = .fixed(buffer) };
        generator.declarations();
        generator.weave(false);
        for (0..knots_count) |index| generator.knot(@intCast(index));
        generator.functions();
        const length = generator.writer.end;
        assert(length <= buffer.len);
        if (!options.splices) return buffer[0..length];
        return buffer[0..splice(choices, buffer, length)];
    }

    fn put(generator: *Generator, bytes: []const u8) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        assert(bytes.len < generator.writer.buffer.len);
        // A full buffer cuts the source short, which is still a source.
        generator.writer.writeAll(bytes) catch {};
    }

    fn print(generator: *Generator, comptime format: []const u8, arguments: anytype) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.writer.print(format, arguments) catch {};
    }

    fn pick(generator: *Generator, comptime list: []const []const u8) []const u8 {
        assert(list.len < 64);
        return list[generator.choices.below(list.len)];
    }

    /// Mostly true: the fuzzer can still leave a declaration out.
    fn keep(generator: *Generator) bool {
        assert(generator.writer.end <= generator.writer.buffer.len);
        return generator.choices.weighted(1, 15);
    }

    fn declarations(generator: *Generator) void {
        assert(generator.writer.end == 0);
        if (generator.keep()) generator.print("VAR v0 = {d}\n", .{generator.choices.choose(i8)});
        if (generator.keep()) generator.put("VAR v1 = \"text\"\n");
        if (generator.keep()) generator.put("VAR v2 = true\n");
        if (generator.keep()) generator.print("CONST c0 = {d}\n", .{generator.choices.choose(u8)});
        if (generator.keep()) generator.put("LIST l0 = a, (b), c\n");
        if (generator.keep()) generator.put("EXTERNAL e0(x)\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// Lines of a knot, stitch or the story's root; `in_function` leaves out what functions
    /// can't hold (choices, gathers, diverts).
    fn weave(generator: *Generator, in_function: bool) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        var lines: u32 = 0;
        while (lines < lines_max and !!generator.choices.more(3, 1)) : (lines += 1) {
            const line = generator.choices.choose(Line);
            switch (line) {
                .choice, .gather, .divert, .tunnel, .thread => if (in_function) {
                    generator.text_line();
                } else generator.flow_line(line),
                .text => generator.text_line(),
                .text_inline => generator.inline_line(),
                .tag => generator.print("Line # tag{d}\n", .{generator.choices.choose(u2)}),
                .glue => generator.put("Before <>\n<> after\n"),
                .assignment => generator.assignment(),
                .block => generator.block(),
            }
        }
        assert(lines <= lines_max);
    }

    fn flow_line(generator: *Generator, line: Line) void {
        assert(line == .choice or line == .gather or line == .divert or line == .tunnel or
            line == .thread);
        switch (line) {
            .choice => generator.choice(),
            .gather => generator.gather(),
            .divert => generator.print("-> {s}\n", .{generator.pick(&targets)}),
            .tunnel => generator.print("-> {s} ->\n", .{generator.pick(&targets[0..4].*)}),
            .thread => generator.print("<- {s}\n", .{generator.pick(&targets[0..4].*)}),
            else => unreachable,
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn text_line(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.put(generator.pick(&words));
        generator.put("\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// Text with one inline construct: a value, a conditional or a sequence.
    fn inline_line(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.put(generator.pick(&words));
        switch (generator.choices.choose(u3)) {
            0, 1 => {
                generator.put("{");
                generator.expression();
                generator.put("}");
            },
            2 => {
                generator.put("{");
                generator.expression();
                generator.put(": yes|no}");
            },
            3 => generator.put("{&one|two|three}"),
            4 => generator.put("{~one|two}"),
            5 => generator.put("{!once|twice}"),
            6 => generator.put("{one|two|}"),
            7 => generator.put("{f0(2)} {f1()}"),
        }
        generator.put("\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn choice(generator: *Generator) void {
        const depth = generator.choices.range(u8, 1, choice_depth_max);
        const bullet = if (generator.choices.choose(bool)) "*" else "+";
        for (0..depth) |_| generator.put(bullet);
        generator.labels += 1;
        if (generator.choices.choose(bool)) generator.print(" (o{d})", .{generator.labels});
        if (generator.choices.weighted(3, 1)) {
            generator.put(" {");
            generator.expression();
            generator.put("}");
        }
        switch (generator.choices.choose(u2)) {
            0 => generator.put(" Start [choice] end\n"),
            1 => generator.put(" [Only choice]\n"),
            2 => generator.put(" Both {v0}\n"),
            3 => generator.print(" -> {s}\n", .{generator.pick(&targets)}),
        }
        assert(depth <= choice_depth_max);
    }

    fn gather(generator: *Generator) void {
        const depth = generator.choices.range(u8, 1, choice_depth_max);
        for (0..depth) |_| generator.put("- ");
        generator.labels += 1;
        if (generator.choices.choose(bool)) generator.print("(g{d}) ", .{generator.labels});
        generator.text_line();
        assert(depth <= choice_depth_max);
    }

    fn assignment(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        const kind = generator.choices.choose(u3);
        switch (kind) {
            0, 1 => generator.print("~ {s} = ", .{generator.pick(&variables)}),
            2 => generator.print("~ {s} += ", .{generator.pick(&variables)}),
            3 => generator.print("~ temp t{d} = ", .{generator.choices.choose(u1)}),
            4 => generator.put("~ l0 += "),
            5 => generator.put("~ v0++\n~ v1 = "),
            6 => generator.put("~ f0("),
            7 => generator.put("~ e0("),
        }
        generator.expression();
        generator.put(if (kind >= 6) ")\n" else "\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// A multi-line conditional, switch or sequence.
    fn block(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        switch (generator.choices.choose(u2)) {
            0 => {
                generator.put("{\n- ");
                generator.expression();
                generator.put(": Then\n- else: Else\n}\n");
            },
            1 => {
                generator.print("{{ {s}:\n- 1: One\n- \"text\": Text\n- else: Other\n}}\n", .{
                    generator.pick(&variables),
                });
            },
            2 => generator.put("{ stopping:\n- First\n- Second\n}\n"),
            3 => generator.put("{ shuffle once:\n- A\n- B\n}\n"),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// A flat chain of terms joined by operators.
    fn expression(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.term();
        var terms: u32 = 1;
        while (terms < terms_max and !!generator.choices.more(2, 1)) : (terms += 1) {
            generator.put(generator.pick(&binary_operators));
            generator.term();
        }
        assert(terms <= terms_max);
    }

    fn term(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        switch (generator.choices.choose(Term)) {
            .integer => generator.print("{d}", .{generator.choices.choose(i8)}),
            .float => generator.print("{d}.5", .{generator.choices.choose(u8)}),
            .string => generator.put("\"str\""),
            .boolean => generator.put(if (generator.choices.choose(bool)) "true" else "false"),
            .variable => generator.put(generator.pick(&variables)),
            .constant => generator.put("c0"),
            .call => generator.put("f0(1)"),
            .call_external => generator.put("e0(2)"),
            .random => generator.put("RANDOM(1, 3)"),
            .visits => generator.put(generator.pick(&targets[0..4].*)),
            .turns_since => generator.put("TURNS_SINCE(-> k1)"),
            .list => generator.put(if (generator.choices.choose(bool)) "(a, c)" else "l0"),
            .list_query => generator.put("LIST_COUNT(l0)"),
            .choice_count => generator.put("CHOICE_COUNT()"),
            .negate => generator.put(if (generator.choices.choose(bool)) "-v0" else "not v2"),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn knot(generator: *Generator, index: u8) void {
        assert(index < knots_count);
        assert(generator.writer.end <= generator.writer.buffer.len);
        if (!generator.keep()) return;
        generator.print("=== k{d} ===\n", .{index});
        generator.weave(false);
        generator.knot_end();
        if (index != 0) return;
        if (generator.keep()) generator.put("= s0\n");
        generator.weave(false);
        generator.knot_end();
    }

    fn knot_end(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        switch (generator.choices.choose(u2)) {
            0 => generator.put("-> END\n"),
            1 => generator.put("->->\n"),
            2 => generator.put("-> DONE\n"),
            3 => generator.print("-> {s}\n", .{generator.pick(&targets)}),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn functions(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        const headers = [_][]const u8{
            "=== function f0(x) ===\n",
            "=== function f1() ===\n",
            "=== function e0(x) ===\n",
        };
        for (headers) |header| {
            if (!generator.keep()) continue;
            generator.put(header);
            generator.weave(true);
            generator.put("~ return ");
            generator.expression();
            generator.put("\n");
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }
};

/// Overwrites up to 4 fuzzer-chosen spans of `buffer[0..length]` with fuzzer bytes, and may
/// cut the source short; returns the new length.
pub fn splice(choices: Choices, buffer: []u8, length: usize) usize {
    assert(length <= buffer.len);
    var end = length;
    var count: u32 = 0;
    while (count < 4 and end > 0 and choices.more(1, 1)) : (count += 1) {
        const at = choices.below(end);
        const span = choices.fill(buffer[at..@min(end, at + 8)]);
        assert(at + span <= end);
        if (choices.weighted(7, 1)) end = at + span;
    }
    assert(end <= length);
    return end;
}

// Tests: a seeded PRNG stands in for the fuzzer.

const compile = @import("../compiler/compile.zig");

/// A source from a seeded PRNG, as the seed corpora use.
pub fn generate_seeded(seed: u64, buffer: []u8, options: Options) []const u8 {
    assert(buffer.len >= 1024);
    var prng: std.Random.DefaultPrng = .init(seed);
    const source = Generator.generate(.{ .random = prng.random() }, buffer, options);
    assert(source.len <= buffer.len);
    return source;
}

test "the same choices give the same source" {
    // The generator reads only the Smith: one seed generated twice.
    var first: [source_bytes_max]u8 = undefined;
    var second: [source_bytes_max]u8 = undefined;
    const a = generate_seeded(7, &first, .{});
    const b = generate_seeded(7, &second, .{});
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(a.len > 0);
}

test "most generated sources compile, and every construct appears" {
    // The sources reach the stages after the parser: 64 seeds compiled; the
    // constructs counted across all of them.
    const gpa = std.testing.allocator;
    var buffer: [source_bytes_max]u8 = undefined;
    const markers = [_][]const u8{
        "=== k",    "= s0",     "function", "VAR",         "CONST", "LIST",
        "EXTERNAL", "<>",       "#",        "*",           "+",     "- ",
        "->->",     "-> k",     "<- ",      "~ ",          "{&",    "{~",
        "{!",       "stopping", "RANDOM",   "TURNS_SINCE",
    };
    var seen: [markers.len]bool = @splat(false);
    var compiled: u32 = 0;
    const seeds = 64;
    for (0..seeds) |seed| {
        const source = generate_seeded(seed, &buffer, .{});
        for (markers, 0..) |marker, i| {
            if (std.mem.indexOf(u8, source, marker) != null) seen[i] = true;
        }
        var program = compile.compile_source(gpa, source) catch continue;
        program.deinit(gpa);
        compiled += 1;
    }
    for (markers, seen) |marker, found| {
        if (!found) std.debug.print("never generated: {s}\n", .{marker});
        try std.testing.expect(found);
    }
    try std.testing.expect(compiled * 2 > seeds);
}

test "splices change the source and stay in bounds" {
    // The parser targets get broken input: the same seed with and without
    // splices.
    var plain: [source_bytes_max]u8 = undefined;
    var spliced: [source_bytes_max]u8 = undefined;
    var differ: u32 = 0;
    for (0..16) |seed| {
        const a = generate_seeded(seed, &plain, .{});
        const b = generate_seeded(seed, &spliced, .{ .splices = true });
        assert(b.len <= spliced.len);
        if (!std.mem.eql(u8, a, b)) differ += 1;
    }
    try std.testing.expect(differ > 0);
}
