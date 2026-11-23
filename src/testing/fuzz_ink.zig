//! An ink source generator for the fuzz targets. The fuzzer's choices, read
//! through `std.testing.Smith`, pick each construct, so the fuzzer explores ink instead of
//! bytes: knots, stitches, functions, declarations, text, glue, tags, choices, gathers,
//! diverts, tunnels, threads, conditionals, sequences, expressions and assignments.
//!
//! Every name comes from a small pool that the generator declares (knots `k0`–`k2`, stitch
//! `k0.s0`, functions `f0(x)`, `f1()` and the external `e0(x)` with its fallback, variables
//! `v0`–`v2`, `c0` and the list `l0`; with `hub`, the knots `hub` and `tunnel0`), so the
//! sources parse and resolve and reach the later stages. For the stages that must reject
//! broken input, a swarm with `drop` or `collision` (each drawn 1 in 8) leaves names out or
//! reuses them, and the parser targets splice raw bytes in. For the play targets, `hub` and
//! `typed` keep a played story going through choices without errors. Nothing recurses:
//! expressions are flat chains of terms, and nesting is bounded by a depth counter.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;

/// Enough for the largest source the bounds below allow.
pub const source_bytes_max = 32 * 1024;

pub const Options = struct {
    /// Let the fuzzer splice raw bytes into the source (for the parser's targets).
    splices: bool = false,
    /// The features the source may use; null draws a configuration from the choices.
    /// `-Dfuzz-swarm=off` makes the default the full mix, to measure swarm against it.
    swarm: ?Swarm = if (build_options.fuzz_swarm) null else Swarm.all,
};

const build_options = @import("build_options");

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

/// Features for ink's name resolution (`GetRawVariableWithName`, variable pointers), which the
/// full mix of the first generator didn't write:
/// - `temp`: temps `u0`-`u3` declared, re-assigned, incremented and read in each flow (and a
///   function's parameter `x` read in its body).
/// - `ref`: `f2(ref x)` and `f3(ref y)`, which passes its pointer on to `f2`, called with
///   globals, temps and parameters, so variable pointers get contexts -1, 0 and n.
/// - `items`: list items read by full name (`l0.a`) and by bare name (`b`).
/// - `l1`: a second list, `LIST l1 = a, d`, so the bare `a` is ambiguous and the generator
///   writes `l0.a` and `l1.a`.
/// - `collision`: one name ink rejects per source (a temp named like a global, a list item or
///   a knot, or the ambiguous bare `a`), for comparing compile errors. It is drawn with
///   probability 1/8 and is not in `Swarm.all`.
/// - `drop`: each declaration, knot, stitch and function left out with probability 1/16
///   while the terms still name them, so the source fails to resolve. Drawn with probability
///   1/8 and not in `Swarm.all`; `Swarm.classic` has it, as the first generator dropped.
pub const Resolution = enum { temp, ref, items, l1, collision, drop };

/// Features that keep a played story going:
/// - `hub`: the root diverts to a knot `hub`, and the hub, each knot and the stitch end in
///   a block of choices (most sticky, a few to END or DONE) that divert to the hub, the
///   knots and the stitch, so play loops through choices; a knot ends otherwise with
///   probability 1/8. Every other choice comes after a sticky fallback to the hub. Tunnels
///   call a knot `tunnel0` that only tunnels reach and that returns with `->->`, so no knot
///   that a divert reaches ends in a tunnel return; diverts and threads outside choices
///   only go forward (to a later knot, the hub, and seldom END or DONE), and function
///   bodies call no function, so nothing loops or recurses without a choice.
/// - `typed`: each expression keeps to one kind of value, numbers (and booleans), strings
///   or lists, with the operators ink defines on it; variables, temps, parameters and
///   function returns keep theirs (`v1` a string, `l0` a list, the others numbers), so
///   expressions don't stop play at a type error. Where a kind has no term here, an
///   expression whose value isn't stored takes another kind, and a stored one the kind's
///   empty value.
pub const Play = enum { hub, typed };

/// Constructs of ink that the first generator didn't write (P18.6), each its own feature, so
/// `Swarm.classic` keeps its choices:
/// - `turns`: the term `TURNS()`.
/// - `math`: the terms `POW`, `FLOOR`, `CEILING`, `INT`, `FLOAT`, `MIN` and `MAX` of
///   numbers, variables and constants.
/// - `list_functions`: `LIST_VALUE` (a number) and `LIST_MIN`, `LIST_MAX`, `LIST_ALL`,
///   `LIST_INVERT`, `LIST_RANDOM`, `LIST_RANGE` and `l0(n)` (lists) of `l0`.
/// - `seed_random`: the line `~ SEED_RANDOM(n)`, which reseeds what `RANDOM`, shuffles and
///   `LIST_RANDOM` draw.
/// - `conditional_else`: the multi-line conditional of one condition and an `- else:`
///   branch (`block` writes the one with a branch per condition).
/// - `choice_tags`: tags in a choice's start, choice-only and output text, one of them
///   with a value, and in the hub's choices.
/// - `divert_variable`: `VAR d0 = -> k0`, assigned other knots and diverted to with
///   `-> d0` (and passed to `jump1` with `parameters`); with `hub`, it always holds the hub.
/// - `parameters`: knots with parameters, each reached by one kind of line with an
///   argument: `-> tunnel1(n) ->` returns with `->->`, `<- thread1(n)` offers a choice, and
///   `-> jump1(n, -> k0)` diverts to the target its second parameter holds (the hub with
///   `hub`).
pub const Construct = enum {
    turns,
    math,
    list_functions,
    seed_random,
    conditional_else,
    choice_tags,
    divert_variable,
    parameters,
};

/// The kinds of value a `typed` expression keeps to.
const Kind = enum { number, string, list };

/// The terms and the extra terms of each kind: `variable` names `v0` or `v2` as a
/// number and `v1` as a string.
const kind_terms = std.enums.EnumArray(Kind, std.EnumSet(Term)).init(.{
    .number = .initMany(&.{
        .integer,    .float,         .boolean, .variable, .constant,
        .call,       .call_external, .random,  .visits,   .turns_since,
        .list_query, .choice_count,  .negate,
    }),
    .string = .initMany(&.{ .string, .variable }),
    .list = .initOne(.list),
});
const kind_extra_terms = std.enums.EnumArray(Kind, std.EnumSet(ExtraTerm)).init(.{
    .number = .initMany(&.{ .temp_read, .ref_call, .global_read, .turns, .math, .list_value }),
    .string = .empty,
    .list = .initMany(&.{ .item_full, .item_bare, .ambiguous, .list_function }),
});
/// Ink's operators on each kind: arithmetic, comparison and logic on numbers, joining,
/// equality and containment on strings, and the set operations and comparisons on lists.
const kind_operators = std.enums.EnumArray(Kind, std.EnumSet(Operator)).init(.{
    .number = .initMany(&.{
        .add,  .subtract, .multiply,   .divide,        .modulo, .equal, .not_equal,
        .less, .greater,  .less_equal, .greater_equal, .@"and", .@"or",
    }),
    .string = .initMany(&.{ .add, .equal, .not_equal, .contains, .not_contains }),
    .list = .initMany(&.{
        .add,        .subtract,      .equal,    .not_equal,    .less, .greater,
        .less_equal, .greater_equal, .contains, .not_contains, .has,
    }),
});

const ExtraLine = enum {
    temp_declare,
    temp_assign,
    temp_increment,
    ref_call,
    global_assign,
    collision,
    seed_random,
    conditional_else,
    divert_assign,
};

const ExtraTerm = enum {
    temp_read,
    item_full,
    item_bare,
    ref_call,
    global_read,
    ambiguous,
    turns,
    math,
    list_value,
    list_function,
};

/// A list item's text, and whether it needs `l1` (else `l0`).
const Item = struct { []const u8, bool };
const items_full = [_]Item{
    .{ "l0.a", false },
    .{ "l0.b", false },
    .{ "l0.c", false },
    .{ "l1.a", true },
    .{ "l1.d", true },
};
const items_bare = [_]Item{ .{ "b", false }, .{ "c", false }, .{ "d", true } };
const temps_count = 4;

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
    resolution: std.EnumSet(Resolution),
    /// Globals `n0`... declared beyond `v0`-`v2`, read and assigned: 0 to 64 (`g` would
    /// collide with the gathers' labels).
    globals_extra: u8,
    play: std.EnumSet(Play),
    constructs: std.EnumSet(Construct),

    pub const lines_limit = 10;
    pub const terms_limit = 4;
    pub const choice_depth_limit = 3;
    pub const knots_limit = 3;
    pub const globals_extra_limit = 64;

    /// The first generator's full mix: every feature but the resolution ones (`drop` aside,
    /// which that generator did), at the largest bounds. It takes the same choices as that
    /// generator did, so its seeds give the same sources.
    pub const classic: Swarm = .{
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
        .resolution = .initOne(.drop),
        .globals_extra = 0,
        .play = .empty,
        .constructs = .empty,
    };

    /// Every feature at the largest bounds, but `collision` and `drop`, which would make
    /// sources fail to compile.
    pub const all: Swarm = all: {
        var swarm = classic;
        swarm.resolution = .full;
        swarm.resolution.remove(.collision);
        swarm.resolution.remove(.drop);
        swarm.globals_extra = globals_extra_limit;
        swarm.play = .full;
        swarm.constructs = .full;
        break :all swarm;
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
        .resolution = .empty,
        .globals_extra = 0,
        .play = .empty,
        .constructs = .empty,
    };

    /// A configuration from the choices, so that the fuzzer learns good ones and a seed
    /// replays one: `all` with weight 1/8, else each feature on with probability ½ (`hub`
    /// ¾) and each bound uniform, then `normalize`.
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
            .resolution = draw_set(choices, Resolution),
            .globals_extra = if (choices.choose(bool))
                choices.range(u8, 1, globals_extra_limit)
            else
                0,
            .play = .empty,
            .constructs = .empty,
        };
        // A collision or a drop fails the compile, so each gets ¼ of the usual probability.
        if (swarm.resolution.contains(.collision) and !choices.weighted(3, 1)) {
            swarm.resolution.remove(.collision);
        }
        if (swarm.resolution.contains(.drop) and !choices.weighted(3, 1)) {
            swarm.resolution.remove(.drop);
        }
        // Drawn last, so the other features of a seed's draw stay as they were before it.
        if (choices.weighted(1, 3)) swarm.play.insert(.hub);
        if (choices.choose(bool)) swarm.play.insert(.typed);
        swarm.constructs = draw_set(choices, Construct);
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
            swarm.constructs.remove(.list_functions);
        }
        if (!declared.contains(.l0) and !swarm.resolution.contains(.l1)) {
            swarm.resolution.remove(.items);
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
            swarm.choice_depth_max >= 1 and swarm.choice_depth_max <= choice_depth_limit and
            swarm.globals_extra <= globals_extra_limit;
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

/// A swarm over `E`'s keys: all of them with weight 1/8, else each with probability ½, and
/// one drawn key when that leaves none.
pub inline fn draw_subset(choices: Choices, E: type) std.EnumSet(E) {
    if (choices.weighted(7, 1)) return .full;
    const Mask = @FieldType(@FieldType(std.EnumSet(E), "bits"), "mask");
    var set: std.EnumSet(E) = .{ .bits = .{ .mask = choices.choose(Mask) } };
    if (set.count() == 0) set.insert(choices.choose(E));
    assert(set.count() > 0);
    return set;
}

/// One of `set`'s keys: `below(count)`, then that set key. There are no retries and no
/// fallbacks, so a left-out key is never picked and none is favoured. On a full set this is
/// `below(len)`, as a pick from the whole list was.
pub inline fn pick_from(choices: Choices, E: type, set: std.EnumSet(E)) E {
    assert(set.count() > 0);
    var skip = choices.below(set.count());
    var keys = set.iterator();
    while (keys.next()) |key| {
        if (skip == 0) return key;
        skip -= 1;
    }
    unreachable;
}

pub const Generator = struct {
    choices: Choices,
    writer: std.Io.Writer,
    /// The features this source may use.
    swarm: Swarm,
    /// The features written so far: always covered by `swarm` (the tests check it).
    used: Swarm = .none,
    /// Unique label suffixes for choices and gathers.
    labels: u32 = 0,
    /// The temps `u0`-`u3` declared in the current flow, as bits.
    temps: u8 = 0,
    /// The temps `t0` and `t1` (of assignments) declared in the current flow, as bits.
    temps_plain: u2 = 0,
    /// Whether the last term written was `not v2`, which ink won't let a `?`, `!?` or `has`
    /// follow.
    negated: bool = false,
    /// The kind of value the expression being written keeps to, with `typed`.
    kind: ?Kind = null,
    /// Whether the current flow is `f0`, `f1` or `e0`.
    in_function: bool = false,
    /// Whether the current flow is a function with the parameter `x`.
    parameter: bool = false,
    /// Whether the source has its one collision.
    collided: bool = false,
    /// The knots and the stitch written after the current flow, which its diverts and
    /// threads may name with `hub`: the root comes first, then `k0`, `k0.s0`, `k1`, `k2`.
    later: std.EnumSet(Target) = knot_targets,

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
        if (swarm.play.contains(.hub)) generator.hub();
        for (0..swarm.knots_count) |index| generator.knot(@intCast(index));
        if (swarm.constructs.contains(.parameters)) generator.knots_with_parameters();
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

    inline fn pick_enabled(generator: *Generator, E: type, set: std.EnumSet(E)) E {
        return pick_from(generator.choices, E, set);
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

    /// Any target; with `hub`, END or DONE (1 in 8, when on), else the hub or a knot after
    /// this flow, so that diverts outside choices never loop and seldom end the story.
    fn divert_target(generator: *Generator) []const u8 {
        const swarm = generator.swarm;
        if (!swarm.play.contains(.hub)) return generator.target(swarm.targets);
        const ends = swarm.targets.intersectWith(.initMany(&.{ .end, .done }));
        if (ends.count() > 0 and generator.choices.weighted(7, 1)) return generator.target(ends);
        return generator.hub_or(swarm.targets.intersectWith(generator.later));
    }

    /// A knot; with `hub`, the hub or a knot after this flow, so that threads never nest
    /// without end.
    fn thread_target(generator: *Generator) []const u8 {
        if (!generator.swarm.play.contains(.hub)) return generator.knot_target();
        return generator.hub_or(generator.swarm.targets.intersectWith(generator.later));
    }

    /// `hub` or one of `set`, each as likely.
    fn hub_or(generator: *Generator, set: std.EnumSet(Target)) []const u8 {
        if (generator.choices.below(set.count() + 1) == 0) return "hub";
        return generator.target(set);
    }

    /// A declared variable; in a `typed` expression, one of its kind when one is declared.
    fn variable(generator: *Generator) []const u8 {
        var set = generator.swarm.declarations.intersectWith(variables);
        if (generator.kind) |kind| {
            const of_kind = set.intersectWith(switch (kind) {
                .number => .initMany(&.{ .v0, .v2 }),
                .string => .initOne(.v1),
                .list => .empty,
            });
            if (of_kind.count() > 0) set = of_kind;
        }
        return @tagName(generator.pick_enabled(Declaration, set));
    }

    /// True, but with `drop` on, where the fuzzer can still leave a declaration out.
    fn keep(generator: *Generator) bool {
        assert(generator.writer.end <= generator.writer.buffer.len);
        if (!generator.swarm.resolution.contains(.drop)) return true;
        if (generator.choices.weighted(1, 15)) return true;
        generator.used.resolution.insert(.drop);
        return false;
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
        if (generator.swarm.resolution.contains(.l1)) {
            generator.used.resolution.insert(.l1);
            generator.put("LIST l1 = a, d\n");
        }
        for (0..generator.swarm.globals_extra) |index| generator.print("VAR n{d} = {d}\n", .{
            index,
            index,
        });
        if (generator.swarm.constructs.contains(.divert_variable) and generator.keep()) {
            generator.used.constructs.insert(.divert_variable);
            generator.print("VAR d0 = -> {s}\n", .{generator.divert_value()});
        }
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
        if (enabled.count() == 0 and generator.extra_lines().count() == 0) return;
        const lines_max = generator.swarm.lines_max;
        var lines: u32 = 0;
        while (lines < lines_max and !!generator.choices.more(3, 1)) : (lines += 1) {
            // An extra line takes a choice only when one is possible, so `classic`
            // takes the first generator's choices.
            const kinds = generator.extra_lines();
            if (kinds.count() > 0 and
                (enabled.count() == 0 or generator.choices.weighted(2, 1)))
            {
                generator.extra_line(kinds);
                continue;
            }
            if (enabled.count() == 0) break;
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
            .divert => generator.divert(),
            .tunnel => if (generator.with_parameters()) {
                generator.put("-> tunnel1(");
                generator.expression_typed(.number);
                generator.put(") ->\n");
            } else if (generator.swarm.play.contains(.hub)) {
                generator.put("-> tunnel0 ->\n");
            } else {
                generator.print("-> {s} ->\n", .{generator.knot_target()});
            },
            .thread => if (generator.with_parameters()) {
                generator.put("<- thread1(");
                generator.expression_typed(.number);
                generator.put(")\n");
            } else {
                generator.print("<- {s}\n", .{generator.thread_target()});
            },
            else => unreachable,
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// Whether a tunnel, thread or divert goes to a knot with parameters: half of them
    /// with `parameters`.
    fn with_parameters(generator: *Generator) bool {
        if (!generator.swarm.constructs.contains(.parameters)) return false;
        if (!generator.choices.choose(bool)) return false;
        generator.used.constructs.insert(.parameters);
        return true;
    }

    /// A divert: to a target, or with the constructs on, to `d0` or `jump1`.
    fn divert(generator: *Generator) void {
        const variable_on = generator.swarm.constructs.contains(.divert_variable);
        if (variable_on and generator.choices.weighted(2, 1)) {
            generator.used.constructs.insert(.divert_variable);
            return generator.put("-> d0\n");
        }
        if (!generator.with_parameters()) {
            return generator.print("-> {s}\n", .{generator.divert_target()});
        }
        generator.put("-> jump1(");
        generator.expression_typed(.number);
        if (variable_on and generator.choices.choose(bool)) {
            generator.used.constructs.insert(.divert_variable);
            generator.put(", d0)\n");
        } else {
            generator.print(", -> {s})\n", .{generator.divert_value()});
        }
    }

    /// What `d0` and `jump1`'s target hold: a knot, or with `hub` the hub, so that a divert
    /// to them never loops without a choice.
    fn divert_value(generator: *Generator) []const u8 {
        if (generator.swarm.play.contains(.hub)) return "hub";
        return generator.knot_target();
    }

    /// The knots that tunnels, threads and diverts with arguments reach. Only tunnels reach
    /// `tunnel1`, and only threads `thread1`, whose choice goes to any target (the hub with
    /// `hub`).
    fn knots_with_parameters(generator: *Generator) void {
        assert(generator.swarm.constructs.contains(.parameters));
        if (generator.keep()) {
            generator.put("=== tunnel1(x) ===\nTunnel {x}\n~ x++\n->->\n");
        }
        if (generator.keep()) {
            generator.put("=== thread1(x) ===\nThread {x}\n");
            const to = if (generator.swarm.play.contains(.hub))
                "hub"
            else
                generator.target(generator.swarm.targets);
            generator.print("* [Thread {{x}}] -> {s}\n", .{to});
            if (generator.swarm.targets.contains(.done)) {
                generator.used.targets.insert(.done);
                generator.put("-> DONE\n");
            }
        }
        if (generator.keep()) generator.put("=== jump1(x, -> t) ===\nJump {x}\n-> t\n");
    }

    fn text_line(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.put(generator.pick(&words));
        generator.put("\n");
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    fn inline_kind(generator: *Generator) Inline {
        var set = generator.swarm.inlines;
        assert(set.count() > 0);
        // With `hub`, no calls in a function body, where they could recurse without end.
        if (generator.in_function and generator.swarm.play.contains(.hub) and
            set.count() > 1) set.remove(.calls);
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

    /// A choice; with `hub`, after a sticky fallback choice to the hub, so that its choice set
    /// never runs out once its choices are used up or their conditions are false.
    fn choice(generator: *Generator) void {
        const depth = generator.choices.range(u8, 1, generator.swarm.choice_depth_max);
        if (generator.swarm.play.contains(.hub)) {
            for (0..depth) |_| generator.put("+");
            generator.put(" -> hub\n");
        }
        const bullet = if (generator.choices.choose(bool)) "*" else "+";
        for (0..depth) |_| generator.put(bullet);
        generator.labels += 1;
        if (generator.choices.choose(bool)) generator.print(" (o{d})", .{generator.labels});
        if (generator.choices.weighted(3, 1)) {
            generator.put(" {");
            generator.expression();
            generator.put("}");
        }
        if (generator.swarm.constructs.contains(.choice_tags) and generator.choices.choose(bool)) {
            return generator.choice_tagged();
        }
        switch (generator.choices.choose(u2)) {
            0 => generator.put(" Start [choice] end\n"),
            1 => generator.put(" [Only choice]\n"),
            2 => generator.put(if (generator.declared(.v0)) " Both {v0}\n" else " Both\n"),
            3 => generator.print(" -> {s}\n", .{generator.target(generator.swarm.targets)}),
        }
        assert(depth <= generator.swarm.choice_depth_max);
    }

    /// A choice's text with tags: in each of its parts, in the choice-only part with a
    /// value, or after its text.
    fn choice_tagged(generator: *Generator) void {
        generator.used.constructs.insert(.choice_tags);
        const label = generator.labels;
        switch (generator.choices.below(3)) {
            0 => generator.print(" Start # ct{d}a [choice # ct{d}b] end # ct{d}c\n", .{
                label, label, label,
            }),
            1 => {
                // An operand: a `->` of `TURNS_SINCE(-> k1)` would end the choice's text.
                generator.print(" [Only # ct{d} {{", .{label});
                generator.operand();
                generator.put("}]\n");
            },
            2 => generator.print(" Tagged # ct{d}\n", .{label}),
            else => unreachable,
        }
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
        // With `typed`, what the target holds; a plain temp is never read.
        var value: ?Kind = null;
        switch (kind) {
            0, 1, 2 => {
                const name = generator.variable();
                generator.print("~ {s} {s} ", .{ name, if (kind == 2) "+=" else "=" });
                value = if (std.mem.eql(u8, name, "v1")) .string else .number;
            },
            3 => {
                // A second `temp` of the same name in one flow is a duplicate declaration.
                const index = generator.choices.choose(u1);
                const bit = @as(u2, 1) << index;
                const declare = if (generator.temps_plain & bit == 0) "temp " else "";
                generator.temps_plain |= bit;
                generator.print("~ {s}t{d} = ", .{ declare, index });
            },
            4 => generator.put("~ l0 += "),
            5 => generator.put("~ v0++\n~ v1 = "),
            6 => generator.put("~ f0("),
            7 => generator.put("~ e0("),
        }
        switch (kind) {
            3 => generator.expression(),
            4 => generator.expression_typed(.list),
            5 => generator.expression_typed(.string),
            6, 7 => generator.expression_typed(.number),
            else => generator.expression_typed(value.?),
        }
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

    /// An expression of any kind: with `typed`, a number with weight ½, else a string or a
    /// list, of the kinds with terms here (of any kind when none has).
    fn expression(generator: *Generator) void {
        if (!generator.swarm.play.contains(.typed)) return generator.expression_of(null, false);
        var kinds: std.EnumSet(Kind) = .empty;
        for (std.enums.values(Kind)) |of| {
            if (generator.kind_terms_here(of).count() > 0) kinds.insert(of);
        }
        if (kinds.count() == 0) return generator.expression_of(null, false);
        const number = kinds.contains(.number) and
            (kinds.count() == 1 or generator.choices.choose(bool));
        kinds.remove(.number);
        const kind = if (number) .number else generator.pick_enabled(Kind, kinds);
        generator.expression_of(kind, false);
    }

    /// An expression that, with `typed`, keeps to `kind`, for a variable, temp, parameter
    /// or return value of that kind; where the kind has no terms here, its empty value
    /// (`0`, `""` or `()`) stands in.
    fn expression_typed(generator: *Generator, kind: Kind) void {
        if (!generator.swarm.play.contains(.typed)) return generator.expression_of(null, false);
        if (generator.kind_terms_here(kind).count() == 0) {
            return generator.put(switch (kind) {
                .number => "0",
                .string => "\"\"",
                .list => "()",
            });
        }
        generator.expression_of(kind, true);
    }

    /// A flat chain of terms joined by operators, of `kind` when it isn't null. A
    /// comparison of strings or lists gives a boolean, which a second one would compare with
    /// a string or a list: an unstored chain keeps to one, a `stored` one to none.
    fn expression_of(generator: *Generator, kind: ?Kind, stored: bool) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        assert(generator.kind == null);
        assert(kind != null or !stored);
        generator.kind = kind;
        defer generator.kind = null;
        var term_start = generator.writer.end;
        generator.term();
        const terms_max = generator.swarm.terms_max;
        var terms: u32 = 1;
        const set_operations: std.EnumSet(Operator) = .initMany(&.{ .add, .subtract });
        var operators = generator.swarm.operators;
        if (kind) |of| operators = operators.intersectWith(kind_operators.get(of));
        const compares = kind != null and kind != .number;
        if (compares and stored) operators = operators.intersectWith(set_operations);
        while (terms < terms_max and !!generator.choices.more(2, 1)) : (terms += 1) {
            if (operators.count() == 0) break;
            const operator = generator.pick_enabled(Operator, operators);
            if (compares and !set_operations.contains(operator)) {
                operators = operators.intersectWith(set_operations);
            }
            generator.used.operators.insert(operator);
            const containment = operator == .contains or operator == .not_contains or
                operator == .has;
            if (containment and generator.negated) generator.unnegate(term_start);
            generator.put(binary_operators[@backingInt(operator)]);
            term_start = generator.writer.end;
            generator.term();
        }
        assert(terms <= terms_max);
    }

    /// Drops the `not ` of the `not v2` written at `start`: ink rejects a `not` left of `?`,
    /// `!?` or `has` even in parentheses (its parser keeps no node for them).
    fn unnegate(generator: *Generator, start: usize) void {
        const end = generator.writer.end;
        const buffer = generator.writer.buffer;
        // A full buffer may have cut it short.
        if (!std.mem.eql(u8, buffer[start..end], "not v2")) return;
        std.mem.copyForwards(u8, buffer[start .. end - 4], buffer[start + 4 .. end]);
        generator.writer.end = end - 4;
    }

    fn term(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        generator.negated = false;
        var kinds = generator.extra_terms();
        var set = generator.swarm.terms;
        if (generator.kind) |of| {
            const here = generator.kind_terms_here(of);
            if (here.count() > 0) {
                kinds = here.extra;
                set = here.terms;
            }
        }
        if (generator.in_function and generator.swarm.play.contains(.hub)) {
            // A call in a function body could recurse without end.
            const calls: std.EnumSet(Term) = .initMany(&.{ .call, .call_external });
            if (set.differenceWith(calls).count() + kinds.count() > 0) {
                set = set.differenceWith(calls);
            }
        }
        if (kinds.count() > 0 and (set.count() == 0 or generator.choices.weighted(2, 1))) {
            return generator.extra_term(kinds);
        }
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
            .list => {
                // With `l1`, a bare `a` is ambiguous: ink rejects it.
                const l1 = generator.swarm.resolution.contains(.l1);
                const literal = if (l1) "(l0.a, c)" else "(a, c)";
                generator.put(if (generator.choices.choose(bool)) literal else "l0");
            },
            .list_query => generator.put("LIST_COUNT(l0)"),
            .choice_count => generator.put("CHOICE_COUNT()"),
            .negate => generator.negate(),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    const TermsHere = struct {
        extra: std.EnumSet(ExtraTerm),
        terms: std.EnumSet(Term),

        fn count(here: TermsHere) usize {
            return here.extra.count() + here.terms.count();
        }
    };

    /// The terms of kind `of` possible here and now.
    fn kind_terms_here(generator: *const Generator, of: Kind) TermsHere {
        var terms = generator.swarm.terms.intersectWith(kind_terms.get(of));
        const variables_of = switch (of) {
            .number => generator.declared(.v0) or generator.declared(.v2),
            .string => generator.declared(.v1),
            .list => false,
        };
        if (!variables_of) terms.remove(.variable);
        return .{
            .extra = generator.extra_terms().intersectWith(
                kind_extra_terms.get(of),
            ),
            .terms = terms,
        };
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
        generator.negated = !minus;
        generator.put(if (minus) "-v0" else "not v2");
    }

    fn knot(generator: *Generator, index: u8) void {
        assert(index < generator.swarm.knots_count);
        assert(generator.writer.end <= generator.writer.buffer.len);
        if (!generator.keep()) return;
        generator.print("=== k{d} ===\n", .{index});
        generator.flow_start(false);
        const order = [_]Target{ .k0, .k0_s0, .k1, .k2 };
        const position: usize = if (index == 0) 0 else index + 1;
        generator.later = .initMany(order[position + 1 ..]);
        generator.weave(false);
        generator.knot_end();
        if (index != 0) return;
        if (generator.keep()) generator.put("= s0\n");
        generator.flow_start(false);
        generator.later = .initMany(order[2..]);
        generator.weave(false);
        generator.knot_end();
    }

    /// The root gathers and diverts to the knot `hub`, a block of choices; with tunnels on,
    /// the knot `tunnel0` that they call follows.
    fn hub(generator: *Generator) void {
        assert(generator.swarm.play.contains(.hub));
        generator.used.play.insert(.hub);
        // The gather takes the loose ends of the root's choices to the hub.
        generator.put("-\n-> hub\n=== hub ===\n");
        generator.flow_start(false);
        generator.hub_choices();
        if (!generator.swarm.lines.contains(.tunnel)) return;
        // Only tunnels reach it, so its `->->` always has a tunnel to return from.
        generator.put("=== tunnel0 ===\n");
        generator.flow_start(false);
        generator.weave(true);
        generator.put("->->\n");
    }

    /// A gather, which the loose ends of the weave before it reach, then 2 to 4 choices
    /// that divert to the hub, a knot or the stitch, or (1 in 32, when on) to END or DONE.
    /// One in 4 is once-only, but not the last when none before it is sticky, so the block
    /// always offers a choice.
    fn hub_choices(generator: *Generator) void {
        assert(generator.swarm.play.contains(.hub));
        const knots = generator.swarm.targets.intersectWith(knot_targets);
        const ends = generator.swarm.targets.intersectWith(.initMany(&.{ .end, .done }));
        generator.put("-\n");
        const count = generator.choices.range(u8, 2, 4);
        var sticky = false;
        for (0..count) |index| {
            const last = index + 1 == count;
            const once = (sticky or !last) and generator.choices.weighted(3, 1);
            sticky = sticky or !once;
            generator.labels += 1;
            generator.put(if (once) "*" else "+");
            if (generator.choices.choose(bool)) {
                if (generator.swarm.constructs.contains(.choice_tags) and
                    generator.choices.choose(bool))
                {
                    generator.used.constructs.insert(.choice_tags);
                    generator.print(" [Go {d} # ct{d}]", .{ generator.labels, generator.labels });
                } else {
                    generator.print(" [Go {d}]", .{generator.labels});
                }
            } else {
                generator.print(" Go {d}", .{generator.labels});
            }
            const to = if (ends.count() > 0 and generator.choices.weighted(31, 1))
                generator.target(ends)
            else if (generator.choices.below(knots.count() + 1) == 0)
                "hub"
            else
                generator.target(knots);
            generator.print(" -> {s}\n", .{to});
        }
        assert(sticky);
    }

    /// A knot's or the stitch's end: with `hub`, a block of choices (7 in 8), else a divert
    /// or (but with `hub`) a tunnel return.
    fn knot_end(generator: *Generator) void {
        assert(generator.writer.end <= generator.writer.buffer.len);
        const hub_on = generator.swarm.play.contains(.hub);
        if (hub_on and generator.choices.weighted(1, 7)) return generator.hub_choices();
        // A divert to a target is always possible, and a tunnel return without `hub`.
        var allowed: u8 = if (hub_on) 0b1000 else 0b1010;
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
            3 => generator.print("-> {s}\n", .{generator.divert_target()}),
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
        generator.in_function = true;
        for (headers, [_]bool{ true, false, true }) |header, parameter| {
            if (!generator.keep()) continue;
            generator.put(header);
            generator.flow_start(parameter);
            generator.weave(true);
            generator.put("~ return ");
            generator.expression_typed(.number);
            generator.put("\n");
        }
        generator.in_function = false;
        generator.flow_start(false);
        if (generator.swarm.resolution.contains(.ref)) {
            // f3 passes its own pointer on: a pointer to a pointer.
            generator.put("=== function f2(ref x) ===\n~ x++\n~ return x\n");
            generator.put("=== function f3(ref y) ===\n~ f2(y)\n~ return y\n");
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// A knot, stitch or function starts: temps of the flow before are out of scope.
    fn flow_start(generator: *Generator, parameter: bool) void {
        assert(generator.temps < 1 << temps_count);
        generator.temps = 0;
        generator.temps_plain = 0;
        generator.parameter = parameter;
    }

    fn temps_declared(generator: *const Generator) u32 {
        assert(generator.temps < 1 << temps_count);
        return @popCount(generator.temps);
    }

    /// The extra lines (beyond `Line`) possible here and now.
    fn extra_lines(generator: *const Generator) std.EnumSet(ExtraLine) {
        const on = generator.swarm.resolution;
        var kinds: std.EnumSet(ExtraLine) = .empty;
        if (on.contains(.temp)) {
            if (generator.temps_declared() < temps_count) kinds.insert(.temp_declare);
            if (generator.temps_declared() > 0) {
                kinds.insert(.temp_assign);
                kinds.insert(.temp_increment);
            }
        }
        if (on.contains(.ref) and generator.ref_targets_count() > 0) kinds.insert(.ref_call);
        if (generator.swarm.globals_extra > 0) kinds.insert(.global_assign);
        if (on.contains(.collision) and !generator.collided) kinds.insert(.collision);
        const constructs = generator.swarm.constructs;
        if (constructs.contains(.seed_random)) kinds.insert(.seed_random);
        if (constructs.contains(.conditional_else)) kinds.insert(.conditional_else);
        if (constructs.contains(.divert_variable)) kinds.insert(.divert_assign);
        assert(kinds.count() <= std.enums.values(ExtraLine).len);
        return kinds;
    }

    fn extra_line(generator: *Generator, kinds: std.EnumSet(ExtraLine)) void {
        assert(kinds.count() > 0);
        switch (generator.pick_enabled(ExtraLine, kinds)) {
            .temp_declare => {
                generator.used.resolution.insert(.temp);
                var free = ~generator.temps & ((1 << temps_count) - 1);
                for (0..generator.choices.below(@popCount(free))) |_| free &= free - 1;
                const index = @ctz(free);
                generator.print("~ temp u{d} = ", .{index});
                generator.expression_typed(.number);
                generator.put("\n");
                // Declared after its expression, which can't read it yet.
                generator.temps |= @as(u8, 1) << @intCast(index);
            },
            .temp_assign => {
                generator.used.resolution.insert(.temp);
                generator.print("~ u{d} = ", .{generator.declared_temp()});
                generator.expression_typed(.number);
                generator.put("\n");
            },
            .temp_increment => {
                generator.used.resolution.insert(.temp);
                generator.print("~ u{d}++\n", .{generator.declared_temp()});
            },
            .ref_call => {
                generator.put("~ ");
                generator.ref_call();
                generator.put("\n");
            },
            .global_assign => {
                const global = generator.choices.below(generator.swarm.globals_extra);
                generator.print("~ n{d} = ", .{global});
                generator.expression_typed(.number);
                generator.put("\n");
            },
            .collision => generator.collision(),
            .seed_random => {
                generator.used.constructs.insert(.seed_random);
                generator.put("~ SEED_RANDOM(");
                if (generator.declared(.c0) and generator.choices.choose(bool)) {
                    generator.put("c0");
                } else {
                    generator.print("{d}", .{generator.choices.choose(i8)});
                }
                generator.put(")\n");
            },
            .divert_assign => {
                generator.used.constructs.insert(.divert_variable);
                generator.print("~ d0 = -> {s}\n", .{generator.divert_value()});
            },
            .conditional_else => {
                generator.used.constructs.insert(.conditional_else);
                generator.put("{ ");
                generator.expression();
                generator.put(":\nIf yes\n- else:\nIf no\n}\n");
            },
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// One of the temps declared in this flow.
    fn declared_temp(generator: *Generator) u32 {
        assert(generator.temps != 0);
        var declared_bits = generator.temps;
        for (0..generator.choices.below(@popCount(declared_bits))) |_| {
            declared_bits &= declared_bits - 1;
        }
        return @ctz(declared_bits);
    }

    /// The extra terms (beyond `Term`) possible here and now.
    fn extra_terms(generator: *const Generator) std.EnumSet(ExtraTerm) {
        const on = generator.swarm.resolution;
        var kinds: std.EnumSet(ExtraTerm) = .empty;
        if (on.contains(.temp) and (generator.temps != 0 or generator.parameter)) {
            kinds.insert(.temp_read);
        }
        if (on.contains(.items)) {
            kinds.insert(.item_full);
            kinds.insert(.item_bare);
        }
        if (on.contains(.ref) and generator.ref_targets_count() > 0) kinds.insert(.ref_call);
        if (generator.swarm.globals_extra > 0) kinds.insert(.global_read);
        if (on.contains(.collision) and on.contains(.l1) and generator.declared(.l0) and
            !generator.collided) kinds.insert(.ambiguous);
        const constructs = generator.swarm.constructs;
        if (constructs.contains(.turns)) kinds.insert(.turns);
        if (constructs.contains(.math)) kinds.insert(.math);
        if (constructs.contains(.list_functions) and generator.declared(.l0)) {
            kinds.insert(.list_value);
            kinds.insert(.list_function);
        }
        return kinds;
    }

    fn extra_term(generator: *Generator, kinds: std.EnumSet(ExtraTerm)) void {
        assert(kinds.count() > 0);
        switch (generator.pick_enabled(ExtraTerm, kinds)) {
            .temp_read => {
                generator.used.resolution.insert(.temp);
                const count = generator.temps_declared() + @intFromBool(generator.parameter);
                generator.put_local(@intCast(generator.choices.below(count)));
            },
            .item_full => generator.put(generator.list_item(&items_full)),
            .item_bare => generator.put(generator.list_item(&items_bare)),
            .ref_call => generator.ref_call(),
            .global_read => {
                generator.print("n{d}", .{generator.choices.below(generator.swarm.globals_extra)});
            },
            .ambiguous => {
                generator.used.resolution.insert(.collision);
                generator.collided = true;
                generator.put("a");
            },
            .turns => {
                generator.used.constructs.insert(.turns);
                generator.put("TURNS()");
            },
            .math => generator.math(),
            .list_value => {
                generator.used.constructs.insert(.list_functions);
                generator.put(generator.pick(&.{
                    "LIST_VALUE(l0)", "LIST_VALUE(LIST_MIN(l0))", "LIST_VALUE(LIST_RANDOM(l0))",
                }));
            },
            .list_function => generator.list_function(),
        }
        assert(generator.writer.end <= generator.writer.buffer.len);
    }

    /// A function of ink's on numbers, of operands that are no expressions (nothing nests).
    fn math(generator: *Generator) void {
        generator.used.constructs.insert(.math);
        const unary = [_][]const u8{ "FLOOR(", "CEILING(", "INT(", "FLOAT(" };
        switch (generator.choices.below(unary.len + 3)) {
            0...unary.len - 1 => |index| {
                generator.put(unary[index]);
                generator.operand();
            },
            unary.len => {
                generator.put("POW(");
                generator.operand();
                generator.print(", {d}", .{generator.choices.choose(u2)});
            },
            else => |index| {
                generator.put(if (index == unary.len + 1) "MIN(" else "MAX(");
                generator.operand();
                generator.put(", ");
                generator.operand();
            },
        }
        generator.put(")");
    }

    /// A number: an integer, a float, `v0` or `c0` (when declared).
    fn operand(generator: *Generator) void {
        switch (generator.choices.choose(u2)) {
            0 => generator.print("{d}", .{generator.choices.choose(i8)}),
            1 => generator.print("{d}.5", .{generator.choices.choose(i8)}),
            2 => generator.put(if (generator.declared(.v0)) "v0" else "1"),
            3 => generator.put(if (generator.declared(.c0)) "c0" else "2.5"),
        }
    }

    /// A function of ink's on lists that returns one, of `l0`.
    fn list_function(generator: *Generator) void {
        generator.used.constructs.insert(.list_functions);
        switch (generator.choices.below(8)) {
            0 => generator.put("LIST_MIN(l0)"),
            1 => generator.put("LIST_MAX(l0)"),
            2 => generator.put("LIST_ALL(l0)"),
            3 => generator.put("LIST_INVERT(l0)"),
            4 => generator.put("LIST_RANDOM(l0)"),
            5 => generator.print("LIST_RANGE(l0, {d}, {d})", .{
                generator.choices.choose(u2),
                generator.choices.choose(u2),
            }),
            // `l0.a` is the only full name that the `items` feature doesn't own.
            6 => generator.put("LIST_RANGE(LIST_ALL(l0), l0.a, 2)"),
            7 => generator.print("l0({d})", .{generator.choices.range(u8, 1, 3)}),
            else => unreachable,
        }
    }

    /// One of `items` whose list is declared; the bare `a` only when it isn't ambiguous.
    fn list_item(generator: *Generator, items: []const Item) []const u8 {
        const l0 = generator.declared(.l0);
        const l1 = generator.swarm.resolution.contains(.l1);
        assert(l0 or l1);
        generator.used.resolution.insert(.items);
        const bare_a = l0 and !l1 and items.len == items_bare.len;
        var count: u32 = @intFromBool(bare_a);
        for (items) |item| count += @intFromBool(if (item[1]) l1 else l0);
        var skip = generator.choices.below(count);
        for (items) |item| {
            if (!(if (item[1]) l1 else l0)) continue;
            if (skip == 0) return item[0];
            skip -= 1;
        }
        assert(bare_a and skip == 0);
        return "a";
    }

    /// What a ref parameter can point to: the declared globals, the extra globals, this
    /// flow's temps and the function's parameter.
    fn ref_targets_count(generator: *const Generator) u32 {
        const globals = generator.ref_globals().count();
        return @as(u32, @intCast(globals)) + @intFromBool(generator.swarm.globals_extra > 0) +
            generator.temps_declared() + @intFromBool(generator.parameter);
    }

    /// The declared globals a ref parameter can point to: with `typed`, the numbers, which
    /// `f2` increments and returns.
    fn ref_globals(generator: *const Generator) std.EnumSet(Declaration) {
        const globals = generator.swarm.declarations.intersectWith(variables);
        if (!generator.swarm.play.contains(.typed)) return globals;
        return globals.differenceWith(.initOne(.v1));
    }

    /// `f2(target)` or `f3(target)`, which passes it on as a pointer to a pointer.
    fn ref_call(generator: *Generator) void {
        const count = generator.ref_targets_count();
        assert(count > 0);
        generator.used.resolution.insert(.ref);
        generator.put(if (generator.choices.choose(bool)) "f2(" else "f3(");
        var chosen: u32 = @intCast(generator.choices.below(count));
        const declared_variables = generator.ref_globals();
        const globals: u32 = @intCast(declared_variables.count());
        if (chosen < globals) {
            var keys = declared_variables.iterator();
            while (keys.next()) |key| : (chosen -= 1) {
                if (chosen == 0) {
                    generator.put(@tagName(key));
                    break;
                }
            }
        } else if (chosen == globals and generator.swarm.globals_extra > 0) {
            generator.print("n{d}", .{generator.choices.below(generator.swarm.globals_extra)});
        } else {
            generator.put_local(chosen - globals - @intFromBool(generator.swarm.globals_extra > 0));
        }
        generator.put(")");
    }

    /// The `index`th temp declared in this flow, or the parameter `x` after them.
    fn put_local(generator: *Generator, index: u32) void {
        assert(index < generator.temps_declared() + @intFromBool(generator.parameter));
        if (index == generator.temps_declared()) return generator.put("x");
        var declared_bits = generator.temps;
        for (0..index) |_| declared_bits &= declared_bits - 1;
        generator.print("u{d}", .{@ctz(declared_bits)});
    }

    /// A name ink rejects: a temp named like a global, a list item or a knot.
    fn collision(generator: *Generator) void {
        assert(!generator.collided);
        generator.collided = true;
        generator.used.resolution.insert(.collision);
        const names = [_][]const u8{ "v0", "a", "k0" };
        const possible = [_]bool{ generator.declared(.v0), generator.declared(.l0), true };
        var count: u32 = 0;
        for (possible) |on| count += @intFromBool(on);
        var skip = generator.choices.below(count);
        for (names, possible) |name, on| {
            if (!on) continue;
            if (skip == 0) {
                generator.print("~ temp {s} = 1\n", .{name});
                return;
            }
            skip -= 1;
        }
        unreachable;
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
/// A fuzz target: `check` on 32 seeded choice streams, more than `passed_min` of which must
/// pass (return true), then under the fuzzer.
pub fn run_target(comptime check: fn (Choices) anyerror!bool, passed_min: u32) !void {
    var passed: u32 = 0;
    for (0..32) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        if (try check(.{ .random = prng.random() })) passed += 1;
    }
    try std.testing.expect(passed > passed_min);
    const target = struct {
        fn entry(_: void, smith: *Smith) anyerror!void {
            _ = try check(.{ .smith = smith });
        }
    };
    try std.testing.fuzz({}, target.entry, .{ .corpus = &.{""} });
}

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
    // The sources reach the stages after the parser: 128 seeds compiled; the
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
    const seeds = 128;
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

test "Swarm.classic reproduces the generator before swarms" {
    // Golden hashes of the generator's output at 9018c6d, before the swarm: `all` takes
    // the same choices, so seeded corpora and replays keep their meaning.
    const golden = [_]struct { seed: u64, length: u32, hash: u64 }{
        .{ .seed = 1, .length = 622, .hash = 0x2d3db7357b5982d3 },
        .{ .seed = 42, .length = 405, .hash = 0x79c78a6ef7068a47 },
        .{ .seed = 9001, .length = 642, .hash = 0x4a0c27b359ab678c },
    };
    var buffer: [source_bytes_max]u8 = undefined;
    for (golden) |expected| {
        const source = generate_seeded(expected.seed, &buffer, .{ .swarm = .classic });
        try std.testing.expectEqual(expected.length, @as(u32, @intCast(source.len)));
        try std.testing.expectEqual(expected.hash, std.hash.Wyhash.hash(0, source));
    }
}

/// Text that only the construct writes, for checking that a left-out construct is absent.
const Marker = struct {
    text: []const u8,
    present: *const fn (Swarm) bool,
    /// Text right before `text` that makes it another construct's.
    not_after: []const u8 = "",

    fn written(marker: Marker, source: []const u8) bool {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, marker.text)) |found| : (at = found + 1) {
            const before = source[0..found];
            if (marker.not_after.len == 0 or !std.mem.endsWith(u8, before, marker.not_after)) {
                return true;
            }
        }
        return false;
    }
};

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

fn with_not_after(marker: Marker, comptime not_after: []const u8) Marker {
    var with = marker;
    with.not_after = not_after;
    return with;
}

const markers_unique = [_]Marker{
    unique_marker("# tag", "lines", Line.tag),
    unique_marker("<>", "lines", Line.glue),
    unique_marker("<- ", "lines", Line.thread),
    unique_marker(" ->\n", "lines", Line.tunnel),
    unique_marker("- else: Else", "lines", Line.block),
    unique_marker("{ stopping", "lines", Line.block),
    unique_marker("{ shuffle once", "lines", Line.block),
    unique_marker("{&", "inlines", Inline.cycle),
    unique_marker("{~", "inlines", Inline.shuffle),
    unique_marker("{!", "inlines", Inline.once),
    unique_marker("|two|}", "inlines", Inline.stopping),
    unique_marker(": yes|no}", "inlines", Inline.conditional),
    unique_marker("{f0(2)}", "inlines", Inline.calls),
    // `LIST_RANDOM(` and `SEED_RANDOM(` take one argument.
    unique_marker("RANDOM(1, 3)", "terms", Term.random),
    unique_marker("TURNS_SINCE", "terms", Term.turns_since),
    unique_marker("LIST_COUNT", "terms", Term.list_query),
    unique_marker("CHOICE_COUNT", "terms", Term.choice_count),
    // The assignment `~ e0(` calls it with an expression, which may be `2`.
    with_not_after(unique_marker("e0(2)", "terms", Term.call_external), "~ "),
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
            if (unique.written(case.source)) {
                const written = "seed {d}: '{s}' is left out but written\n";
                std.debug.print(written, .{ seed, unique.text });
                return error.TestUnexpectedResult;
            }
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
            "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1 resolution= " ++
            "globals_extra=0 play= constructs=",
        // k2 names a knot that a count of 1 doesn't write.
        "lines=text terms=integer operators=add inlines= targets=k2 declarations= " ++
            "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1 resolution= " ++
            "globals_extra=0 play= constructs=",
    };
    for (invalid) |bad| try std.testing.expectError(error.InvalidSwarm, Swarm.parse(bad));
    const one = "lines=text terms=integer operators=add inlines= targets=k0 declarations= " ++
        "lines_max=1 terms_max=1 choice_depth_max=1 knots_count=1 resolution= globals_extra=0 " ++
        "play= constructs=";
    var writer: std.Io.Writer = .fixed(&text);
    try writer.print("{f}", .{try Swarm.parse(one)});
    try std.testing.expectEqualStrings(one, writer.buffered());
}

test "each resolution feature appears when on and never when off" {
    // 1,000 seeded draws: every resolution feature (and the extra globals) is written by
    // some source that has it on, and its text is absent from every source that has it off.
    const Check = struct { feature: ?Resolution, texts: []const []const u8 };
    const checks = [_]Check{
        .{ .feature = .temp, .texts = &.{"~ temp u"} },
        .{ .feature = .ref, .texts = &.{"=== function f2(ref x)"} },
        // `l0.a` is also the list literal's item when `l1` is on.
        .{ .feature = .items, .texts = &.{ "l0.b", "l0.c", "l1." } },
        .{ .feature = .l1, .texts = &.{"LIST l1"} },
        .{ .feature = .collision, .texts = &.{ "~ temp v0 =", "~ temp a =", "~ temp k0 =" } },
        .{ .feature = null, .texts = &.{"VAR n0 "} },
    };
    var seen: [checks.len]u32 = @splat(0);
    var buffer: [source_bytes_max]u8 = undefined;
    for (0..1000) |seed| {
        const case = generate_case_seeded(seed, &buffer, .{});
        try std.testing.expect(case.swarm.covers(case.used));
        for (checks, &seen) |check, *count| {
            const on = if (check.feature) |feature|
                case.swarm.resolution.contains(feature)
            else
                case.swarm.globals_extra > 0;
            var written = false;
            for (check.texts) |text| {
                if (std.mem.indexOf(u8, case.source, text) != null) written = true;
            }
            if (!on) try std.testing.expect(!written);
            if (written) count.* += 1;
        }
    }
    for (seen) |count| try std.testing.expect(count > 0);
}

test "each construct appears when on and never when off" {
    // 1,000 seeded draws: every construct is written by some source that has it on, and
    // its text is absent from every source that has it off.
    const checks = std.enums.EnumArray(Construct, []const []const u8).init(.{
        .turns = &.{"TURNS()"},
        // `MIN(` and `MAX(` are also in `LIST_MIN(` and `LIST_MAX(`.
        .math = &.{ "POW(", "FLOOR(", "CEILING(", "INT(", "FLOAT(" },
        .seed_random = &.{"SEED_RANDOM("},
        .conditional_else = &.{ "If yes", "If no" },
        .choice_tags = &.{"# ct"},
        .divert_variable = &.{ "VAR d0", "-> d0", "~ d0 =" },
        .parameters = &.{ "tunnel1(", "thread1(", "jump1(" },
        .list_functions = &.{
            "LIST_VALUE(",  "LIST_MIN(",    "LIST_MAX(",   "LIST_ALL(",
            "LIST_INVERT(", "LIST_RANDOM(", "LIST_RANGE(", "l0(",
        },
    });
    var seen: std.enums.EnumArray(Construct, u32) = .initFill(0);
    var buffer: [source_bytes_max]u8 = undefined;
    for (0..1000) |seed| {
        const case = generate_case_seeded(seed, &buffer, .{});
        try std.testing.expect(case.swarm.covers(case.used));
        for (std.enums.values(Construct)) |construct| {
            var written = false;
            for (checks.get(construct)) |text| {
                if (std.mem.indexOf(u8, case.source, text) != null) written = true;
            }
            if (!case.swarm.constructs.contains(construct) and written) {
                std.debug.print("seed {d}: {t} is off but written\n", .{ seed, construct });
                return error.TestUnexpectedResult;
            }
            if (written) seen.getPtr(construct).* += 1;
        }
    }
    for (std.enums.values(Construct)) |construct| try std.testing.expect(seen.get(construct) > 0);
}

test "most sources with only the resolution features compile" {
    // A configuration of plain text and integers plus every resolution feature but
    // `collision`: at least 60% of 200 seeds compile, so they reach the runtime.
    const gpa = std.testing.allocator;
    var buffer: [source_bytes_max]u8 = undefined;
    var swarm = Swarm.classic;
    swarm.lines = .initMany(&.{.text});
    swarm.terms = .initMany(&.{.integer});
    swarm.declarations = .initMany(&.{ .v0, .l0 });
    swarm.resolution = .initMany(&.{ .temp, .ref, .items, .l1 });
    var compiled: u32 = 0;
    var resolving: u32 = 0;
    const seeds = 200;
    for (0..seeds) |seed| {
        swarm.globals_extra = @intCast(seed % (Swarm.globals_extra_limit + 1));
        const case = generate_case_seeded(seed, &buffer, .{ .swarm = swarm });
        if (case.used.resolution.count() > 0) resolving += 1;
        var program = compile.compile_source(gpa, case.source) catch continue;
        program.deinit(gpa);
        compiled += 1;
    }
    try std.testing.expect(resolving * 2 > seeds);
    try std.testing.expect(compiled * 10 >= seeds * 6);
}

test "drawn sources compile unless an error feature is on, and with one they fail" {
    // 500 seeded draws: fewer than 5% of the sources without `collision` and `drop` fail to
    // compile (none did in 2,000), and `drop` still leaves names unresolved.
    const gpa = std.testing.allocator;
    var buffer: [source_bytes_max]u8 = undefined;
    var clean: u32 = 0;
    var clean_failed: u32 = 0;
    var dropped: u32 = 0;
    var dropped_failed: u32 = 0;
    for (0..500) |seed| {
        const case = generate_case_seeded(seed, &buffer, .{ .swarm = null });
        // A collision always fails; a drop fails when it left out a name in use.
        if (case.swarm.resolution.contains(.collision)) continue;
        const erroneous = case.swarm.resolution.contains(.drop);
        if (erroneous and !case.used.resolution.contains(.drop)) continue;
        const failed = if (compile.compile_source(gpa, case.source)) |program| failed: {
            var compiled = program;
            compiled.deinit(gpa);
            break :failed false;
        } else |err| switch (err) {
            error.CompileFailed => true,
            else => return err,
        };
        if (erroneous) {
            dropped += 1;
            dropped_failed += @intFromBool(failed);
        } else {
            clean += 1;
            clean_failed += @intFromBool(failed);
        }
    }
    try std.testing.expect(clean > 300);
    try std.testing.expect(clean_failed * 20 < clean);
    try std.testing.expect(dropped > 0 and dropped_failed > 0);
}

test "64 extra globals stay below the source bound" {
    // `Swarm.all` declares the most globals; no seed fills the buffer (a full one would cut
    // the source short).
    var buffer: [source_bytes_max]u8 = undefined;
    var longest: usize = 0;
    for (0..200) |seed| {
        const source = generate_seeded(seed, &buffer, .{ .swarm = .all });
        try std.testing.expect(std.mem.indexOf(u8, source, "VAR n63 = 63\n") != null);
        longest = @max(longest, source.len);
    }
    try std.testing.expect(longest < source_bytes_max / 2);
}
