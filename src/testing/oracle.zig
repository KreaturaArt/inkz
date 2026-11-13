//! The differential oracle: compares the runtime's transcripts with expected ones and checks
//! every difference against the divergence ledger, `test/divergence_ledger.zon`.
//!
//! A ledger entry names a case and a corpus, says what kind of difference it is
//! and why, and optionally the evidence for the expected behaviour. A difference that isn't
//! in the ledger fails, and so does an entry whose case no longer differs, so stale entries
//! get removed. `zig build test -Dledger-update` rewrites the entries of the corpus being
//! checked: new differences get an automatic reason, fixed ones are dropped, and
//! entries that still apply are kept as they are, so reasons edited by hand survive.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");

pub const ledger_path = "test/divergence_ledger.zon";
const file_bytes_max = 16 * 1024 * 1024;

/// Why the runtime differs from the expected transcript: a known divergence, or
/// what the comparison saw.
pub const Kind = enum {
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    /// The runtime lacks a capability the action script uses.
    unsupported,
    /// The runtime returned an error where ink didn't throw, or the other way around.
    exception,
    /// The runtime crashed (a panic or a signal).
    crash,
    /// Only tags differ (often S11).
    tags,
    /// Only whitespace inside lines differs (often S10).
    whitespace,
    /// Not classified yet.
    other,
};

pub const Corpus = enum {
    /// `test/ground_truth`: compared with what ink v1.2.1 produced.
    ground_truth,
    /// `test/transcripts`: compared with what the old runtime produced.
    transcripts,
    /// The new compiler's JSON for each ground-truth case, compared with inklecate's.
    structure,
};

pub const Entry = struct {
    case: []const u8,
    corpus: Corpus = .ground_truth,
    kind: Kind,
    reason: []const u8,
    /// The evidence for the expected behaviour, such as a Tests.cs test or a ground-truth case.
    source: []const u8 = "",
    /// The issue whose work removes this divergence, such as `TASK-145.8`.
    fix: []const u8 = "",
};

pub const Mismatch = struct {
    case: []const u8,
    kind: Kind,
    reason: []const u8,
};

/// One case's expected and actual transcripts.
pub const Result = struct {
    case: []const u8,
    expected: []const u8,
    actual: []const u8,
};

pub const Report = struct {
    mismatches: []const Mismatch,
    /// Mismatches that the ledger doesn't list.
    new: []const Mismatch,
    /// Ledger entries whose case now matches.
    stale: []const Entry,
};

/// Compares every result and sorts the differences into ledgered, new and stale.
pub fn evaluate(
    arena: std.mem.Allocator,
    ledger: []const Entry,
    corpus: Corpus,
    results: []const Result,
) !Report {
    var mismatches: std.ArrayList(Mismatch) = .empty;
    var new: std.ArrayList(Mismatch) = .empty;
    for (results) |result| {
        var mismatch = try compare(arena, result.expected, result.actual) orelse continue;
        mismatch.case = result.case;
        try mismatches.append(arena, mismatch);
        if (find_entry(ledger, corpus, result.case) == null) try new.append(arena, mismatch);
    }
    var stale: std.ArrayList(Entry) = .empty;
    for (ledger) |entry| {
        if (entry.corpus != corpus) continue;
        const still_differs = for (mismatches.items) |mismatch| {
            if (std.mem.eql(u8, mismatch.case, entry.case)) break true;
        } else false;
        if (!still_differs) try stale.append(arena, entry);
    }
    assert(new.items.len <= mismatches.items.len);
    return .{ .mismatches = mismatches.items, .new = new.items, .stale = stale.items };
}

/// The gate: fails on new or stale differences, or rewrites the ledger with -Dledger-update.
pub fn check(arena: std.mem.Allocator, io: std.Io, corpus: Corpus, results: []const Result) !void {
    assert(results.len > 0);
    const ledger = try read_ledger(arena, io);
    const report = try evaluate(arena, ledger, corpus, results);
    assert(report.mismatches.len <= results.len);
    if (build_options.ledger_update) {
        try write_ledger(arena, io, ledger, corpus, report.mismatches);
        return;
    }
    for (report.new) |mismatch| {
        std.debug.print("new divergence ({t}): {s}: {t}: {s}\n", .{
            corpus, mismatch.case, mismatch.kind, mismatch.reason,
        });
    }
    for (report.stale) |entry| {
        std.debug.print("stale ledger entry ({t}): {s} now matches\n", .{ corpus, entry.case });
    }
    std.debug.print("{t}: {d} cases, {d} ledgered divergences, {d} problems\n", .{
        corpus, results.len, report.mismatches.len, report.new.len + report.stale.len,
    });
    if (report.new.len + report.stale.len > 0) return error.OracleMismatch;
}

/// Null when `actual` matches `expected`; otherwise a classified difference.
pub fn compare(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) !?Mismatch {
    assert(expected.len < file_bytes_max);
    if (try lines_equivalent(arena, expected, actual, .exact)) return null;
    var mismatch: Mismatch = .{ .case = "", .kind = .other, .reason = "" };
    if (std.mem.indexOf(u8, actual, "crash: ")) |at| {
        mismatch.kind = .crash;
        mismatch.reason = try arena.dupe(u8, first_line(actual[at..]));
    } else if (std.mem.indexOf(u8, actual, "\nunsupported: ")) |at| {
        const line = first_line(actual[at + 1 ..]);
        mismatch.kind = .unsupported;
        mismatch.reason = try std.fmt.allocPrint(arena, "the runtime lacks it: {s}", .{line});
    } else if ((std.mem.indexOf(u8, actual, "exception: ") != null) !=
        (std.mem.indexOf(u8, expected, "exception: ") != null))
    {
        mismatch.kind = .exception;
        mismatch.reason = try first_difference(arena, expected, actual);
    } else if (try lines_equivalent(arena, expected, actual, .without_tags)) {
        mismatch.kind = .tags;
        mismatch.reason = "only tags differ";
    } else if (try lines_equivalent(arena, expected, actual, .whitespace)) {
        mismatch.kind = .whitespace;
        mismatch.reason = "only whitespace inside lines differs";
    } else {
        mismatch.reason = try first_difference(arena, expected, actual);
    }
    assert(mismatch.reason.len > 0);
    return mismatch;
}

fn first_line(text: []const u8) []const u8 {
    assert(text.len < file_bytes_max);
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    assert(end <= text.len);
    return text[0..end];
}

const Equivalence = enum { exact, without_tags, whitespace };

/// Compares line by line. `save:` lines are JSON-equivalent (key order ignored).
fn lines_equivalent(
    arena: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
    equivalence: Equivalence,
) !bool {
    assert(expected.len < file_bytes_max);
    assert(actual.len < file_bytes_max);
    var expected_lines = significant_lines(expected, equivalence);
    var actual_lines = significant_lines(actual, equivalence);
    while (true) {
        const a = expected_lines.next();
        const b = actual_lines.next();
        if (a == null or b == null) return a == null and b == null;
        if (!try line_equivalent(arena, a.?, b.?, equivalence)) return false;
    }
}

const LineIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    skip_tags: bool,

    fn next(iterator: *LineIterator) ?[]const u8 {
        assert(iterator.lines.buffer.len < file_bytes_max);
        while (iterator.lines.next()) |line| {
            if (line.len == 0) continue;
            assert(std.mem.indexOfScalar(u8, line, '\n') == null);
            if (iterator.skip_tags and std.mem.startsWith(u8, line, "tags: ")) continue;
            return if (iterator.skip_tags) strip_choice_tags(line) else line;
        }
        return null;
    }
};

fn significant_lines(text: []const u8, equivalence: Equivalence) LineIterator {
    assert(text.len < file_bytes_max);
    const iterator: LineIterator = .{
        .lines = std.mem.splitScalar(u8, text, '\n'),
        .skip_tags = equivalence == .without_tags,
    };
    assert(iterator.lines.index == 0);
    return iterator;
}

/// `  0: "text" tags ["a"]` without its ` tags [...]` suffix.
fn strip_choice_tags(line: []const u8) []const u8 {
    assert(line.len > 0);
    if (!std.mem.startsWith(u8, line, "  ")) return line;
    const at = std.mem.lastIndexOf(u8, line, "\" tags [") orelse return line;
    assert(at + 1 <= line.len);
    return line[0 .. at + 1];
}

fn line_equivalent(
    arena: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    equivalence: Equivalence,
) !bool {
    assert(a.len > 0);
    assert(b.len > 0);
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.startsWith(u8, a, "save: ") and std.mem.startsWith(u8, b, "save: ")) {
        return json_equivalent(arena, a["save: ".len..], b["save: ".len..]);
    }
    if (equivalence != .whitespace) return false;
    if (!std.mem.startsWith(u8, a, "text: ") or !std.mem.startsWith(u8, b, "text: ")) return false;
    return equal_ignoring_spaces(a, b);
}

fn equal_ignoring_spaces(a: []const u8, b: []const u8) bool {
    var index_a: usize = 0;
    var index_b: usize = 0;
    while (true) {
        assert(index_a <= a.len);
        assert(index_b <= b.len);
        while (index_a < a.len and a[index_a] == ' ') index_a += 1;
        while (index_b < b.len and b[index_b] == ' ') index_b += 1;
        if (index_a == a.len or index_b == b.len) return index_a == a.len and index_b == b.len;
        if (a[index_a] != b[index_b]) return false;
        index_a += 1;
        index_b += 1;
    }
}

fn json_equivalent(arena: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    assert(a.len < file_bytes_max);
    assert(b.len < file_bytes_max);
    const value_a = std.json.parseFromSliceLeaky(std.json.Value, arena, a, .{}) catch return false;
    const value_b = std.json.parseFromSliceLeaky(std.json.Value, arena, b, .{}) catch return false;
    return json_values_equal(value_a, value_b);
}

/// Deep equality where object key order doesn't matter. Iterative, with an explicit stack.
fn json_values_equal(a: std.json.Value, b: std.json.Value) bool {
    var pending: [256][2]std.json.Value = undefined;
    var count: u32 = 1;
    pending[0] = .{ a, b };
    var steps: u32 = 0;
    while (count > 0) : (steps += 1) {
        // Each value is visited once; a save holds far fewer than a million values.
        assert(steps < 1_000_000);
        assert(count <= pending.len);
        count -= 1;
        const left, const right = pending[count];
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        switch (left) {
            .array => |items| {
                if (items.items.len != right.array.items.len) return false;
                for (items.items, right.array.items) |x, y| {
                    if (count == pending.len) return false;
                    pending[count] = .{ x, y };
                    count += 1;
                }
            },
            .object => |object| {
                if (object.count() != right.object.count()) return false;
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const other = right.object.get(entry.key_ptr.*) orelse return false;
                    if (count == pending.len) return false;
                    pending[count] = .{ entry.value_ptr.*, other };
                    count += 1;
                }
            },
            .string => |text| if (!std.mem.eql(u8, text, right.string)) return false,
            .number_string => |text| if (!std.mem.eql(u8, text, right.number_string)) return false,
            else => if (!std.meta.eql(left, right)) return false,
        }
    }
    return true;
}

fn first_difference(
    arena: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
) ![]const u8 {
    assert(!std.mem.eql(u8, expected, actual));
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var number: u32 = 1;
    var turn: u32 = 1;
    while (true) : (number += 1) {
        assert(number < std.math.maxInt(u32));
        const a = expected_lines.next() orelse "<end>";
        const b = actual_lines.next() orelse "<end>";
        if (std.mem.eql(u8, a, b)) {
            // A turn ends with a choice, made by `play` or by a `choose` action.
            if (std.mem.startsWith(u8, a, "choose: ") or std.mem.startsWith(u8, a, "> choose ")) {
                turn += 1;
            }
            continue;
        }
        return std.fmt.allocPrint(arena, "turn {d}, line {d}: expected {s} | got {s}", .{
            turn, number, truncate(a, 80), truncate(b, 80),
        });
    }
}

fn truncate(text: []const u8, length: usize) []const u8 {
    assert(length > 0);
    const result = text[0..@min(text.len, length)];
    assert(result.len <= length);
    return result;
}

pub fn read_ledger(arena: std.mem.Allocator, io: std.Io) ![]const Entry {
    assert(file_bytes_max > 0);
    assert(ledger_path.len > 0);
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        ledger_path,
        arena,
        .limited(file_bytes_max),
        .of(u8),
        0,
    );
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice([]const Entry, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        diagnostics.log(ledger_path);
        return err;
    };
}

fn find_entry(ledger: []const Entry, corpus: Corpus, case: []const u8) ?Entry {
    for (ledger) |entry| {
        if (entry.corpus == corpus and std.mem.eql(u8, entry.case, case)) return entry;
    }
    return null;
}

/// Writes the ledger: entries of other corpora unchanged, then this corpus's divergences,
/// keeping existing entries for cases that still diverge.
fn write_ledger(
    arena: std.mem.Allocator,
    io: std.Io,
    ledger: []const Entry,
    corpus: Corpus,
    mismatches: []const Mismatch,
) !void {
    for (mismatches) |mismatch| assert(mismatch.case.len > 0);
    var output: std.Io.Writer.Allocating = .init(arena);
    const writer = &output.writer;
    try writer.writeAll(
        \\// Known differences (plan P0.4, P0.10), one per case and corpus. Kinds: s1..s11
        \\// (plan §1.1), unsupported, exception, crash, tags, whitespace, other.
        \\// `zig build test -Dledger-update` adds new ones and drops fixed ones; reasons and
        \\// sources edited by hand are kept.
        \\.{
        \\
    );
    for (ledger) |entry| {
        if (entry.corpus != corpus) try write_entry(writer, entry);
    }
    for (mismatches) |mismatch| {
        const entry = find_entry(ledger, corpus, mismatch.case) orelse Entry{
            .case = mismatch.case,
            .corpus = corpus,
            .kind = mismatch.kind,
            .reason = mismatch.reason,
        };
        try write_entry(writer, entry);
    }
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ledger_path, .data = output.written() });
}

fn write_entry(writer: *std.Io.Writer, entry: Entry) !void {
    assert(entry.case.len > 0);
    try writer.writeAll("    .{ .case = ");
    try std.zon.stringify.serialize(entry.case, .{}, writer);
    try writer.print(", .corpus = .{t}, .kind = .{t}, .reason = ", .{ entry.corpus, entry.kind });
    try std.zon.stringify.serialize(entry.reason, .{}, writer);
    if (entry.source.len > 0) {
        try writer.writeAll(", .source = ");
        try std.zon.stringify.serialize(entry.source, .{}, writer);
    }
    if (entry.fix.len > 0) {
        try writer.writeAll(", .fix = ");
        try std.zon.stringify.serialize(entry.fix, .{}, writer);
    }
    try writer.writeAll(" },\n");
}

fn test_entry(case: []const u8, corpus: Corpus, kind: Kind) Entry {
    return .{ .case = case, .corpus = corpus, .kind = kind, .reason = "r" };
}

test "a seeded divergence reports the first differing turn" {
    // The reason points at the turn: two transcripts that agree on the
    // first turn and differ on the second.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const expected = "> play\ntext: \"a\\n\"\nchoose: 0\ntext: \"b\\n\"\nend\n";
    const actual = "> play\ntext: \"a\\n\"\nchoose: 0\ntext: \"c\\n\"\nend\n";
    const results = [_]Result{.{ .case = "seeded", .expected = expected, .actual = actual }};
    const report = try evaluate(arena_state.allocator(), &.{}, .transcripts, &results);
    try std.testing.expectEqual(@as(usize, 1), report.new.len);
    try std.testing.expect(std.mem.startsWith(u8, report.new[0].reason, "turn 2, line 4:"));
}

test "a ledgered divergence passes and a stale entry fails" {
    // The two ledger rules: one listed case that still differs, one listed
    // case that now matches, and an entry of another corpus that must be ignored.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const same = "> play\nend\n";
    const results = [_]Result{
        .{ .case = "still_differs", .expected = same, .actual = "> play\ncrash: x\n" },
        .{ .case = "fixed", .expected = same, .actual = same },
    };
    const ledger = [_]Entry{
        test_entry("still_differs", .transcripts, .crash),
        test_entry("fixed", .transcripts, .other),
        test_entry("fixed", .ground_truth, .other),
    };
    const report = try evaluate(arena_state.allocator(), &ledger, .transcripts, &results);
    try std.testing.expectEqual(@as(usize, 0), report.new.len);
    try std.testing.expectEqual(@as(usize, 1), report.stale.len);
    try std.testing.expectEqualStrings("fixed", report.stale[0].case);
}

test "compare classifies differences" {
    // The classification used for automatic ledger reasons: one pair per kind.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "> play\ntext: \"a b\\n\"\ntags: [\"t\"]\nend\n";
    try std.testing.expectEqual(@as(?Mismatch, null), try compare(arena, base, base));
    const no_tags = "> play\ntext: \"a b\\n\"\nend\n";
    try std.testing.expectEqual(Kind.tags, (try compare(arena, base, no_tags)).?.kind);
    const spaced = "> play\ntext: \"a  b\\n\"\ntags: [\"t\"]\nend\n";
    try std.testing.expectEqual(Kind.whitespace, (try compare(arena, base, spaced)).?.kind);
    const thrown = "> play\nexception: \"Bad\"\n";
    try std.testing.expectEqual(Kind.exception, (try compare(arena, base, thrown)).?.kind);
    const gap = "> play\nunsupported: play\n";
    try std.testing.expectEqual(Kind.unsupported, (try compare(arena, base, gap)).?.kind);
    const other = "> play\ntext: \"c\\n\"\nend\n";
    try std.testing.expectEqual(Kind.other, (try compare(arena, base, other)).?.kind);
}

test "save lines compare as JSON, ignoring key order" {
    // JSON-equivalent saves: the same object with keys in another order.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "save: {\"a\":1,\"b\":[true,\"x\"]}\n";
    const b = "save: {\"b\":[true,\"x\"],\"a\":1}\n";
    try std.testing.expectEqual(@as(?Mismatch, null), try compare(arena, a, b));
    const c = "save: {\"b\":[true,\"y\"],\"a\":1}\n";
    try std.testing.expect(try compare(arena, a, c) != null);
}
