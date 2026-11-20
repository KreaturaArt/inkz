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

pub const Options = struct {
    /// Let the fuzzer splice raw bytes into the source (for the parser's targets).
    splices: bool = false,
    /// The features the source may use; null draws a configuration from the choices.
    swarm: ?Swarm = null,
};

pub const Line = enum {
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

/// The lines a function can hold (no choices, gathers or diverts).
const function_lines: std.EnumSet(Line) = .initMany(&.{
    .text, .text_inline, .tag, .glue, .assignment, .block,
});

pub const Term = enum {
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

/// The binary operators, in the order of `binary_operators`.
pub const Operator = enum {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    @"and",
    @"or",
    contains,
    not_contains,
    has,
};

const binary_operators = [_][]const u8{
    " + ",   " - ",  " * ", " / ",  " % ",   " == ", " != ", " < ", " > ", " <= ", " >= ",
    " and ", " or ", " ? ", " !? ", " has ",
};

/// The constructs a text line's braces can hold.
pub const Inline = enum { value, conditional, cycle, shuffle, once, stopping, calls };

/// What diverts, tunnels, threads and visit counts name, in the order of `targets`.
pub const Target = enum { k0, k1, k2, k0_s0, end, done };

const targets = [_][]const u8{ "k0", "k1", "k2", "k0.s0", "END", "DONE" };
/// The targets a tunnel, a thread or a visit count can name.
const knot_targets: std.EnumSet(Target) = .initMany(&.{ .k0, .k1, .k2, .k0_s0 });

/// The story's declarations; the first three are the variables.
pub const Declaration = enum { v0, v1, v2, c0, l0, e0 };

const variables: std.EnumSet(Declaration) = .initMany(&.{ .v0, .v1, .v2 });
const words = [_][]const u8{ "Hello", "the cat", "a", "", "!", "  spaced  ", "x\\{y\\}" };

comptime {
    assert(binary_operators.len == std.enums.values(Operator).len);
    assert(targets.len == std.enums.values(Target).len);
}

/// A swarm-testing configuration (Groce et al., "Swarm Testing", ISSTA 2012): the features one
/// source may use. Leaving features out of a whole source makes the others dense (no
/// dilution among 11 line kinds and 15 terms), and keeps suppressors such as an early
/// `-> END` out of the configurations that need depth.
pub const Swarm = struct {
    lines: std.EnumSet(Line),
    terms: std.EnumSet(Term),
    operators: std.EnumSet(Operator),
    inlines: std.EnumSet(Inline),
    targets: std.EnumSet(Target),
    declarations: std.EnumSet(Declaration),
    lines_max: u8,
    terms_max: u8,
    choice_depth_max: u8,
    knots_count: u8,

    pub const lines_limit = 10;
    pub const terms_limit = 4;
    pub const choice_depth_limit = 3;
    pub const knots_limit = 3;

    /// Every feature at the largest bounds: the generator's full mix.
    pub const all: Swarm = .{
        .lines = .full,
        .terms = .full,
        .operators = .full,
        .inlines = .full,
        .targets = .full,
        .declarations = .full,
        .lines_max = lines_limit,
        .terms_max = terms_limit,
        .choice_depth_max = choice_depth_limit,
        .knots_count = knots_limit,
    };

    /// No feature: what a generator has used before it writes anything.
    pub const none: Swarm = .{
        .lines = .empty,
        .terms = .empty,
        .operators = .empty,
        .inlines = .empty,
        .targets = .empty,
        .declarations = .empty,
        .lines_max = 0,
        .terms_max = 0,
        .choice_depth_max = 0,
        .knots_count = 0,
    };

    /// A configuration from the choices, so that the fuzzer learns good ones and a seed
    /// replays one: `all` with weight 1/8, else each feature on with probability ½ and each
    /// bound uniform, then `normalize`.
    pub fn draw(choices: Choices) Swarm {
        if (choices.weighted(7, 1)) return all;
        var swarm: Swarm = .{
            .lines = draw_set(choices, Line),
            .terms = draw_set(choices, Term),
            .operators = draw_set(choices, Operator),
            .inlines = draw_set(choices, Inline),
            .targets = draw_set(choices, Target),
            .declarations = draw_set(choices, Declaration),
            .lines_max = choices.range(u8, 1, lines_limit),
            .terms_max = choices.range(u8, 1, terms_limit),
            .choice_depth_max = choices.range(u8, 1, choice_depth_limit),
            .knots_count = choices.range(u8, 1, knots_limit),
        };
        swarm.normalize();
        assert(swarm.valid());
        return swarm;
    }

    /// Each key with probability ½: one value as wide as the set's mask.
    inline fn draw_set(choices: Choices, E: type) std.EnumSet(E) {
        const Mask = @FieldType(@FieldType(std.EnumSet(E), "bits"), "mask");
        return .{ .bits = .{ .mask = choices.choose(Mask) } };
    }

    /// Drops the features that name what the configuration leaves out (knots past
    /// `knots_count`, terms of undeclared names), then gives each set that must not be empty
    /// one fallback key.
    pub fn normalize(swarm: *Swarm) void {
        assert(swarm.knots_count >= 1 and swarm.knots_count <= knots_limit);
        if (swarm.knots_count < 3) swarm.targets.remove(.k2);
        if (swarm.knots_count < 2) swarm.targets.remove(.k1);
        if (swarm.targets.intersectWith(knot_targets).count() == 0) swarm.targets.insert(.k0);
        const declared = swarm.declarations;
        if (declared.intersectWith(variables).count() == 0) swarm.terms.remove(.variable);
        if (!declared.contains(.v0) and !declared.contains(.v2)) swarm.terms.remove(.negate);
        if (!declared.contains(.c0)) swarm.terms.remove(.constant);
        if (!declared.contains(.l0)) {
            swarm.terms.remove(.list);
            swarm.terms.remove(.list_query);
        }
        if (swarm.inlines.count() == 0) swarm.lines.remove(.text_inline);
        if (swarm.lines.count() == 0) swarm.lines.insert(.text);
        if (swarm.terms.count() == 0) swarm.terms.insert(.integer);
        if (swarm.operators.count() == 0) swarm.operators.insert(.add);
        assert(swarm.valid());
    }

    /// The sets the generator picks from are not empty, every target names a knot that
    /// exists, and the bounds are in range.
    pub fn valid(swarm: Swarm) bool {
        const knots_missing: std.EnumSet(Target) = switch (swarm.knots_count) {
            1 => .initMany(&.{ .k1, .k2 }),
            2 => .initOne(.k2),
            3 => .empty,
            else => return false,
        };
        return swarm.lines.count() > 0 and swarm.terms.count() > 0 and
            swarm.operators.count() > 0 and
            swarm.targets.intersectWith(knot_targets).count() > 0 and
            swarm.targets.intersectWith(knots_missing).count() == 0 and
            (swarm.inlines.count() > 0 or !swarm.lines.contains(.text_inline)) and
            swarm.lines_max >= 1 and swarm.lines_max <= lines_limit and
            swarm.terms_max >= 1 and swarm.terms_max <= terms_limit and
            swarm.choice_depth_max >= 1 and swarm.choice_depth_max <= choice_depth_limit;
    }

    pub fn eql(a: Swarm, b: Swarm) bool {
        inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
            const equal = if (@FieldType(Swarm, name) == u8)
                @field(a, name) == @field(b, name)
            else
                @field(a, name).eql(@field(b, name));
            if (!equal) return false;
        }
        return true;
    }

    /// Whether every feature `used` has is on in `swarm` (the bounds aren't compared).
    pub fn covers(swarm: Swarm, used: Swarm) bool {
        inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
            if (@FieldType(Swarm, name) != u8 and !@field(used, name).subsetOf(@field(swarm, name)))
                return false;
        }
        return true;
    }

    /// One line, for failure reports and reproduce commands: `all`, or every field as
    /// `name=key,key` or `name=number`, separated by spaces. `parse` reads it back.
    pub fn format(swarm: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (swarm.eql(all)) return writer.writeAll("all");
        inline for (@typeInfo(Swarm).@"struct".field_names, 0..) |name, index| {
            if (index > 0) try writer.writeByte(' ');
            try writer.writeAll(name ++ "=");
            const value = @field(swarm, name);
            if (@FieldType(Swarm, name) == u8) {
                try writer.print("{d}", .{value});
            } else {
                var keys = value.iterator();
                var first = true;
                while (keys.next()) |key| : (first = false) {
                    if (!first) try writer.writeByte(',');
                    try writer.writeAll(@tagName(key));
                }
            }
        }
    }

    /// Reads what `format` writes; every field must be given once, and the result be valid.
    pub fn parse(text: []const u8) error{InvalidSwarm}!Swarm {
        if (std.mem.eql(u8, text, "all")) return all;
        const fields = @typeInfo(Swarm).@"struct".field_names;
        var swarm: Swarm = none;
        var seen: std.StaticBitSet(fields.len) = .empty;
        var pairs = std.mem.tokenizeScalar(u8, text, ' ');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidSwarm;
            const name = pair[0..equals];
            const value = pair[equals + 1 ..];
            var known = false;
            inline for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, name, field)) {
                    if (seen.isSet(index)) return error.InvalidSwarm;
                    seen.set(index);
                    @field(swarm, field) = try parse_field(@FieldType(Swarm, field), value);
                    known = true;
                }
            }
            if (!known) return error.InvalidSwarm;
        }
        if (seen.count() != fields.len or !swarm.valid()) return error.InvalidSwarm;
        return swarm;
    }

    fn parse_field(T: type, value: []const u8) error{InvalidSwarm}!T {
        if (T == u8) return std.fmt.parseInt(u8, value, 10) catch error.InvalidSwarm;
        var set: T = .empty;
        var keys = std.mem.tokenizeScalar(u8, value, ',');
        while (keys.next()) |key| {
            set.insert(std.meta.stringToEnum(T.Key, key) orelse return error.InvalidSwarm);
        }
        return set;
    }
};

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
    /// The features this source may use.
    swarm: Swarm,
    /// The features written so far: always covered by `swarm` (the tests check it).
    used: Swarm = .none,
    /// Unique label suffixes for choices and gathers.
    labels: u32 = 0,

    pub const Case = struct {
        source: []const u8,
        swarm: Swarm,
        used: Swarm,
    };

    /// Writes one source into `buffer` and returns it (cut short if the buffer is full).
    pub fn generate(choices: Choices, buffer: []u8, options: Options) []const u8 {
        return generate_case(choices, buffer, options).source;
    }

    /// Like `generate`, and also returns the configuration and the features used.
    pub fn generate_case(choices: Choices, buffer: []u8, options: Options) Case {
        assert(buffer.len >= 1024);
        const swarm = options.swarm orelse Swarm.draw(choices);
        assert(swarm.valid());
        var generator: Generator = .{
            .choices = choices,
            .writer = .fixed(buffer),
            .swarm = swarm,
        };
        generator.declarations();
        generator.weave(false);
        for (0..swarm.knots_count) |index| generator.knot(@intCast(index));
        generator.functions();
        const length = generator.writer.end;
        assert(length <= buffer.len);
        assert(swarm.covers(generator.used));
        const end = if (options.splices) splice(choices, buffer, length) else length;
        return .{ .source = buffer[0..end], .swarm = swarm, .used = generator.used };
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

    /// One of `set`'s keys: `below(count)`, then that set key. There are no retries and no
    /// fallbacks, so a left-out key is never written and none is favoured. On a full set
    /// this is `below(len)`, as a pick from the whole list was.
    inline fn pick_enabled(generator: *Generator, E: type, set: std.EnumSet(E)) E {
        assert(set.count() > 0);
        var skip = generator.choices.below(set.count());
        var keys = set.iterator();
        while (keys.next()) |key| {
            if (skip == 0) return key;
            skip -= 1;
        }
        unreachable;
    }

    /// An index whose bit is set in `mask`: `choose(T)` when every one is (as the full mix
    /// always picked), else `below(count)`, then that set bit.
    inline fn pick_bit(generator: *Generator, T: type, mask: u8) T {
        comptime assert(@bitSizeOf(T) <= 3);
        const full: u8 = (1 << (1 << @bitSizeOf(T))) - 1;
        assert(mask & full != 0);
        if (mask & full == full) return generator.choices.choose(T);
        var skip = generator.choices.below(@popCount(mask & full));
        for (0..1 << @bitSizeOf(T)) |index| {
            if (mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (skip == 0) return @intCast(index);
            skip -= 1;
        }
        unreachable;
    }

    fn declared(generator: *const Generator, declaration: Declaration) bool {
        assert(generator.swarm.valid());
        return generator.swarm.declarations.contains(declaration);
    }

    fn target(generator: *Generator, set: std.EnumSet(Target)) []const u8 {
        assert(set.subsetOf(generator.swarm.targets));
        const key = generator.pick_enabled(Target, set);
        generator.used.targets.insert(key);
        return targets[@backingInt(key)];
    }

    fn knot_target(generator: *Generator) []const u8 {
        return generator.target(generator.swarm.targets.intersectWith(knot_targets));
    }

    fn variable(generator: *Generator) []const u8 {
        const set = generator.swarm.declarations.intersectWith(variables);
        return @tagName(generator.pick_enabled(Declaration, set));
    }

    /// Mostly true: the fuzzer can still leave a declaration out.
    fn keep(generator: *Generator) bool {
        assert(generator.writer.end <= generator.writer.buffer.len);
        return generator.choices.weighted(1, 15);
    }

    fn declarations(generator: *Generator) void {
        assert(generator.writer.end == 0);
        if (generator.declared(.v0) and generator.keep()) {
            generator.print("VAR v0 = {d}\n", .{generator.choices.choose(i8)});
        }
        if (generator.declared(.v1) and generator.keep()) generator.put("VAR v1 = \"text\"\n");
        if (generator.declared(.v2) and generator.keep()) generator.put("VAR v2 = true\n");
        if (generator.declared(.c0) and generator.keep()) {
            generator.print("CONST c0 = {d}\n", .{generator.choices.choose(u8)});
        }
        if (generator.declared(.l0) and generator.keep()) generator.put("LIST l0 = a, (b), c\n");
        if (generator.declared(.e0) and generator.keep()) generator.put("EXTERNAL e0(x)\n");
        generator.used.declarations = generator.swarm.declarations;
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// Lines of a knot, stitch or the story's root; `in_function` leaves out what functions
    /// can't hold (choices, gathers, diverts).
    fn weave(generator: *Generator, in_function: bool) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        const all_lines = generator.swarm.lines.eql(.full);
        const enabled = if (in_function and !all_lines)
            generator.swarm.lines.intersectWith(function_lines)
        else
            generator.swarm.lines;
        if (enabled.count() == 0) return;
        const lines_max = generator.swarm.lines_max;
        var lines: u32 = 0;
        while (lines < lines_max and !!generator.choices.more(3, 1)) : (lines += 1) {
            const line = if (all_lines)
                generator.choices.choose(Line)
            else
                generator.pick_enabled(Line, enabled);
            generator.used.lines.insert(line);
            switch (line) {
                .choice, .gather, .divert, .tunnel, .thread => if (in_function) {
                    // Only the full mix gets here: it writes text instead.
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
            .divert => generator.print("-> {s}\n", .{generator.target(generator.swarm.targets)}),
            .tunnel => generator.print("-> {s} ->\n", .{generator.knot_target()}),
            .thread => generator.print("<- {s}\n", .{generator.knot_target()}),
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

    fn inline_kind(generator: *Generator) Inline {
        const set = generator.swarm.inlines;
        assert(set.count() > 0);
        if (!set.eql(.full)) return generator.pick_enabled(Inline, set);
        return switch (generator.choices.choose(u3)) {
            0, 1 => .value,
            2 => .conditional,
            3 => .cycle,
            4 => .shuffle,
            5 => .once,
            6 => .stopping,
            7 => .calls,
        };
    }

    /// Text with one inline construct: a value, a conditional or a sequence.
    fn inline_line(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.put(generator.pick(&words));
        const kind = generator.inline_kind();
        generator.used.inlines.insert(kind);
        switch (kind) {
            .value => {
                generator.put("{");
                generator.expression();
                generator.put("}");
            },
            .conditional => {
                generator.put("{");
                generator.expression();
                generator.put(": yes|no}");
            },
            .cycle => generator.put("{&one|two|three}"),
            .shuffle => generator.put("{~one|two}"),
            .once => generator.put("{!once|twice}"),
            .stopping => generator.put("{one|two|}"),
            .calls => generator.put("{f0(2)} {f1()}"),
        }
        generator.put("\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn choice(generator: *Generator) void {
        const depth = generator.choices.range(u8, 1, generator.swarm.choice_depth_max);
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
            2 => generator.put(if (generator.declared(.v0)) " Both {v0}\n" else " Both\n"),
            3 => generator.print(" -> {s}\n", .{generator.target(generator.swarm.targets)}),
        }
        assert(depth <= generator.swarm.choice_depth_max);
    }

    fn gather(generator: *Generator) void {
        const depth = generator.choices.range(u8, 1, generator.swarm.choice_depth_max);
        for (0..depth) |_| generator.put("- ");
        generator.labels += 1;
        if (generator.choices.choose(bool)) generator.print("(g{d}) ", .{generator.labels});
        generator.text_line();
        assert(depth <= generator.swarm.choice_depth_max);
    }

    fn assignment(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        // Kinds 3 (a temp) and 6 (a call to f0) name nothing the swarm can leave out.
        var allowed: u8 = 0xff;
        if (generator.swarm.declarations.intersectWith(variables).count() == 0) {
            allowed &= ~@as(u8, 0b0000_0111);
        }
        if (!generator.declared(.l0)) allowed &= ~@as(u8, 1 << 4);
        if (!generator.declared(.v0) or !generator.declared(.v1)) allowed &= ~@as(u8, 1 << 5);
        const kind = generator.pick_bit(u3, allowed);
        switch (kind) {
            0, 1 => generator.print("~ {s} = ", .{generator.variable()}),
            2 => generator.print("~ {s} += ", .{generator.variable()}),
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
                const declared_any = generator.swarm.declarations.intersectWith(variables)
                    .count() > 0;
                generator.print("{{ {s}:\n- 1: One\n- \"text\": Text\n- else: Other\n}}\n", .{
                    if (declared_any) generator.variable() else "1",
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
        const terms_max = generator.swarm.terms_max;
        var terms: u32 = 1;
        while (terms < terms_max and !!generator.choices.more(2, 1)) : (terms += 1) {
            const operator = generator.pick_enabled(Operator, generator.swarm.operators);
            generator.used.operators.insert(operator);
            generator.put(binary_operators[@backingInt(operator)]);
            generator.term();
        }
        assert(terms <= terms_max);
    }

    fn term(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        const set = generator.swarm.terms;
        const kind = if (set.eql(.full))
            generator.choices.choose(Term)
        else
            generator.pick_enabled(Term, set);
        generator.used.terms.insert(kind);
        switch (kind) {
            .integer => generator.print("{d}", .{generator.choices.choose(i8)}),
            .float => generator.print("{d}.5", .{generator.choices.choose(u8)}),
            .string => generator.put("\"str\""),
            .boolean => generator.put(if (generator.choices.choose(bool)) "true" else "false"),
            .variable => generator.put(generator.variable()),
            .constant => generator.put("c0"),
            .call => generator.put("f0(1)"),
            .call_external => generator.put("e0(2)"),
            .random => generator.put("RANDOM(1, 3)"),
            .visits => generator.put(generator.knot_target()),
            .turns_since => generator.turns_since(),
            .list => generator.put(if (generator.choices.choose(bool)) "(a, c)" else "l0"),
            .list_query => generator.put("LIST_COUNT(l0)"),
            .choice_count => generator.put("CHOICE_COUNT()"),
            .negate => generator.negate(),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn turns_since(generator: *Generator) void {
        const knots = generator.swarm.targets.intersectWith(knot_targets);
        // k1 when it is on, as the full mix always wrote; else the first knot target.
        var keys = knots.iterator();
        const key: Target = if (knots.contains(.k1)) .k1 else keys.next().?;
        generator.used.targets.insert(key);
        generator.print("TURNS_SINCE(-> {s})", .{targets[@backingInt(key)]});
    }

    fn negate(generator: *Generator) void {
        const v0 = generator.declared(.v0);
        const v2 = generator.declared(.v2);
        assert(v0 or v2);
        const minus = if (v0 and v2) generator.choices.choose(bool) else v0;
        generator.put(if (minus) "-v0" else "not v2");
    }

    fn knot(generator: *Generator, index: u8) void {
        assert(index < generator.swarm.knots_count);
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
        // A tunnel return and a divert to a target are always possible.
        var allowed: u8 = 0b1010;
        if (generator.swarm.targets.contains(.end)) allowed |= 0b0001;
        if (generator.swarm.targets.contains(.done)) allowed |= 0b0100;
        switch (generator.pick_bit(u2, allowed)) {
            0 => {
                generator.used.targets.insert(.end);
                generator.put("-> END\n");
            },
            1 => generator.put("->->\n"),
            2 => {
                generator.used.targets.insert(.done);
                generator.put("-> DONE\n");
            },
            3 => generator.print("-> {s}\n", .{generator.target(generator.swarm.targets)}),
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

/// A source and its configuration from a seeded PRNG.
pub fn generate_case_seeded(seed: u64, buffer: []u8, options: Options) Generator.Case {
    assert(buffer.len >= 1024);
    var prng: std.Random.DefaultPrng = .init(seed);
    return Generator.generate_case(.{ .random = prng.random() }, buffer, options);
}

test "Swarm.all reproduces the generator before swarms" {
    // Golden hashes of the generator's output at 9018c6d, before the swarm: `all` takes
    // the same choices, so seeded corpora and replays keep their meaning.
    const golden = [_]struct { seed: u64, length: u32, hash: u64 }{
        .{ .seed = 1, .length = 622, .hash = 0x2d3db7357b5982d3 },
        .{ .seed = 42, .length = 405, .hash = 0x79c78a6ef7068a47 },
        .{ .seed = 9001, .length = 642, .hash = 0x4a0c27b359ab678c },
    };
    var buffer: [source_bytes_max]u8 = undefined;
    for (golden) |expected| {
        const source = generate_seeded(expected.seed, &buffer, .{ .swarm = .all });
        try std.testing.expectEqual(expected.length, @as(u32, @intCast(source.len)));
        try std.testing.expectEqual(expected.hash, std.hash.Wyhash.hash(0, source));
    }
}

/// Text that only the construct writes, for checking that a left-out construct is absent.
const Marker = struct { text: []const u8, present: *const fn (Swarm) bool };

fn unique_marker(
    comptime text: []const u8,
    comptime field: []const u8,
    comptime key: anytype,
) Marker {
    return .{ .text = text, .present = struct {
        fn present(swarm: Swarm) bool {
            return @field(swarm, field).contains(key);
        }
    }.present };
}

const markers_unique = [_]Marker{
    unique_marker("# tag", "lines", Line.tag),
    unique_marker("<>", "lines", Line.glue),
    unique_marker("<- ", "lines", Line.thread),
    unique_marker(" ->\n", "lines", Line.tunnel),
    unique_marker("else:", "lines", Line.block),
    unique_marker("{ stopping", "lines", Line.block),
    unique_marker("{ shuffle once", "lines", Line.block),
    unique_marker("{&", "inlines", Inline.cycle),
    unique_marker("{~", "inlines", Inline.shuffle),
    unique_marker("{!", "inlines", Inline.once),
    unique_marker("|two|}", "inlines", Inline.stopping),
    unique_marker(": yes|no}", "inlines", Inline.conditional),
    unique_marker("{f0(2)}", "inlines", Inline.calls),
    unique_marker("RANDOM(", "terms", Term.random),
    unique_marker("TURNS_SINCE", "terms", Term.turns_since),
    unique_marker("LIST_COUNT", "terms", Term.list_query),
    unique_marker("CHOICE_COUNT", "terms", Term.choice_count),
    unique_marker("e0(2)", "terms", Term.call_external),
    unique_marker("\"str\"", "terms", Term.string),
    unique_marker(" + ", "operators", Operator.add),
    unique_marker(" * ", "operators", Operator.multiply),
    unique_marker(" / ", "operators", Operator.divide),
    unique_marker(" % ", "operators", Operator.modulo),
    unique_marker(" == ", "operators", Operator.equal),
    unique_marker(" != ", "operators", Operator.not_equal),
    unique_marker(" < ", "operators", Operator.less),
    unique_marker(" > ", "operators", Operator.greater),
    unique_marker(" <= ", "operators", Operator.less_equal),
    unique_marker(" >= ", "operators", Operator.greater_equal),
    unique_marker(" and ", "operators", Operator.@"and"),
    unique_marker(" or ", "operators", Operator.@"or"),
    unique_marker(" ? ", "operators", Operator.contains),
    unique_marker(" !? ", "operators", Operator.not_contains),
    unique_marker(" has ", "operators", Operator.has),
    unique_marker("-> END", "targets", Target.end),
    unique_marker("-> DONE", "targets", Target.done),
    unique_marker("-> k1", "targets", Target.k1),
    unique_marker("-> k2", "targets", Target.k2),
    unique_marker("-> k0.s0", "targets", Target.k0_s0),
    unique_marker("VAR v0", "declarations", Declaration.v0),
    unique_marker("VAR v1", "declarations", Declaration.v1),
    unique_marker("VAR v2", "declarations", Declaration.v2),
    unique_marker("CONST c0", "declarations", Declaration.c0),
    unique_marker("LIST l0", "declarations", Declaration.l0),
    unique_marker("EXTERNAL e0", "declarations", Declaration.e0),
};

test "a source uses only its configuration's features" {
    // 1,000 seeded draws: what the generator records as used is in the configuration, and
    // the text of every left-out construct (and of knots and nesting past the bounds) is
    // absent from the source.
    var buffer: [source_bytes_max]u8 = undefined;
    var subsets: u32 = 0;
    for (0..1000) |seed| {
        const case = generate_case_seeded(seed, &buffer, .{});
        try std.testing.expect(case.swarm.covers(case.used));
        if (!case.swarm.eql(.all)) subsets += 1;
        for (markers_unique) |unique| {
            if (unique.present(case.swarm)) continue;
            try std.testing.expect(std.mem.indexOf(u8, case.source, unique.text) == null);
        }
        const knots = [_][]const u8{ "=== k0 ", "=== k1 ", "=== k2 " };
        for (knots[case.swarm.knots_count..]) |header| {
            try std.testing.expect(std.mem.indexOf(u8, case.source, header) == null);
        }
        try std.testing.expect(nesting_max(case.source) <= case.swarm.choice_depth_max);
    }
    // About 7 in 8 draws are subsets.
    try std.testing.expect(subsets > 800 and subsets < 950);
}

/// The deepest choice or gather: the longest run of bullets (`*`, `+` or `- `) a line starts
/// with.
fn nesting_max(source: []const u8) usize {
    var deepest: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var depth: usize = 0;
        while (depth < line.len and (line[depth] == '*' or line[depth] == '+')) depth += 1;
        var gathers: usize = 0;
        while (std.mem.startsWith(u8, line[gathers * 2 ..], "- ")) gathers += 1;
        deepest = @max(deepest, depth, gathers);
    }
    return deepest;
}

test "a drawn configuration is valid: no empty set, bounds in range" {
    for (0..1000) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const swarm = Swarm.draw(.{ .random = prng.random() });
        try std.testing.expect(swarm.valid());
        try std.testing.expect(swarm.lines.count() > 0);
        try std.testing.expect(swarm.terms.count() > 0);
        try std.testing.expect(swarm.operators.count() > 0);
        try std.testing.expect(swarm.targets.intersectWith(knot_targets).count() > 0);
        try std.testing.expect(swarm.lines_max >= 1 and swarm.lines_max <= Swarm.lines_limit);
        try std.testing.expect(swarm.terms_max >= 1 and swarm.terms_max <= Swarm.terms_limit);
        try std.testing.expect(swarm.choice_depth_max >= 1 and
            swarm.choice_depth_max <= Swarm.choice_depth_limit);
        try std.testing.expect(swarm.knots_count >= 1 and swarm.knots_count <= Swarm.knots_limit);
    }
}

test "Swarm.format round-trips through Swarm.parse" {
    var text: [1024]u8 = undefined;
    for (0..256) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const swarm = Swarm.draw(.{ .random = prng.random() });
        var writer: std.Io.Writer = .fixed(&text);
        try writer.print("{f}", .{swarm});
        const parsed = try Swarm.parse(writer.buffered());
        try std.testing.expect(parsed.eql(swarm));
    }
    try std.testing.expect((try Swarm.parse("all")).eql(.all));
    const invalid = [_][]const u8{
        "",
        "lines=text",
        "lines=nope terms=integer operators=add inlines= targets=k0 declarations= " ++
            "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1",
        // k2 names a knot that a count of 1 doesn't write.
        "lines=text terms=integer operators=add inlines= targets=k2 declarations= " ++
            "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1",
    };
    for (invalid) |bad| try std.testing.expectError(error.InvalidSwarm, Swarm.parse(bad));
    const one = "lines=text terms=integer operators=add inlines= targets=k0 declarations= " ++
        "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1";
    var writer: std.Io.Writer = .fixed(&text);
    try writer.print("{f}", .{try Swarm.parse(one)});
    try std.testing.expectEqualStrings(one, writer.buffered());
}
