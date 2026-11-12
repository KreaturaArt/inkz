//! The state heap (plan §4.5, D4): runtime strings in a fixed byte buffer and lists in a fixed
//! word slab, both reclaimed by sliding mark-compact, which keeps objects in allocation order.
//! Compaction runs only when an allocation doesn't fit, and can happen at any instruction
//! boundary, since a single `cont()` may build any amount of garbage.
//!
//! The heap doesn't know where references live. `compact` takes `roots`, which must provide
//! `visit(visitor: anytype)` and call `visitor.string(*StringReference)` and
//! `visitor.list(*ListReference)` for every reference the state holds (globals, temps, the
//! evaluation stack, output, choices, snapshots, parked flows, the lookahead snapshot, the
//! observer queue). Offsets recorded with the lookahead snapshot are relocated too: because
//! compaction preserves order, objects older than a mark stay below it.
//!
//! A string is `[length | mark bit, forward, bytes..., padding to 4]`.

const std = @import("std");
const assert = std.debug.assert;
const fault = @import("../core/fault.zig");
const value_module = @import("value.zig");
const ListSlab = @import("lists.zig").ListSlab;
const StringReference = value_module.StringReference;
const ListReference = value_module.ListReference;

const header_bytes = 8;
const mark_bit: u32 = 1 << 31;
/// Freed bytes are filled with this in safe builds, so a stale reference reads garbage that
/// `check_reference` and the length field reject.
const poison: u8 = 0xAA;

pub const StringHeap = struct {
    bytes: []u8,
    used: u32 = 0,

    pub const Fault = enum { ok, used_exceeds_capacity, object_out_of_bounds, misaligned, marked };

    pub fn init(bytes: []u8) StringHeap {
        assert(bytes.len < mark_bit);
        assert(std.mem.isAligned(@intFromPtr(bytes.ptr), 4));
        return .{ .bytes = bytes };
    }

    fn object_bytes(text_length: u32) u32 {
        const total = std.mem.alignForward(u32, header_bytes + text_length, 4);
        assert(total >= header_bytes + text_length);
        assert(total % 4 == 0);
        return total;
    }

    /// Room for a string of `length` bytes, or null if it doesn't fit without compacting.
    pub fn try_allocate(heap: *StringHeap, length: u32) ?StringReference {
        assert(heap.used <= heap.bytes.len);
        if (length >= mark_bit) return null;
        const total = object_bytes(length);
        if (total > heap.bytes.len - heap.used) return null;
        const at = heap.used;
        std.mem.writeInt(u32, heap.bytes[at..][0..4], length, .little);
        std.mem.writeInt(u32, heap.bytes[at + 4 ..][0..4], 0, .little);
        heap.used += total;
        assert(heap.used <= heap.bytes.len);
        return .heap(at);
    }

    /// Shortens the most recently allocated string to `length` bytes.
    pub fn shrink_last(heap: *StringHeap, reference: StringReference, length: u32) void {
        const at = reference.heap_offset();
        assert(length <= heap.length_at(at));
        assert(at + object_bytes(heap.length_at(at)) == heap.used);
        std.mem.writeInt(u32, heap.bytes[at..][0..4], length, .little);
        heap.used = at + object_bytes(length);
    }

    /// Drops every object from `top` on; `top` must be an object boundary, such as a
    /// relocated lookahead mark.
    pub fn truncate(heap: *StringHeap, top: u32) void {
        assert(top <= heap.used);
        assert(top % 4 == 0);
        if (std.debug.runtime_safety) @memset(heap.bytes[top..heap.used], poison);
        heap.used = top;
    }

    fn length_at(heap: *const StringHeap, at: u32) u32 {
        assert(at + header_bytes <= heap.used);
        const raw = std.mem.readInt(u32, heap.bytes[at..][0..4], .little);
        assert(raw & ~mark_bit <= heap.used - at - header_bytes);
        return raw & ~mark_bit;
    }

    /// The bytes of a heap string; valid until the next allocation that may compact.
    pub fn get(heap: *const StringHeap, reference: StringReference) []u8 {
        assert(reference.is_heap());
        const at = reference.heap_offset();
        const length = heap.length_at(at);
        assert(at + header_bytes + length <= heap.used);
        return heap.bytes[at + header_bytes ..][0..length];
    }

    /// Whether `reference` points at an object boundary in the used part of the heap.
    pub fn check_reference(heap: *const StringHeap, reference: StringReference) Fault {
        assert(heap.used <= heap.bytes.len);
        const at = reference.heap_offset();
        if (at % 4 != 0) return .misaligned;
        if (at + header_bytes > heap.used) return .object_out_of_bounds;
        const raw = std.mem.readInt(u32, heap.bytes[at..][0..4], .little);
        if (raw & mark_bit != 0) return .marked;
        if (at + object_bytes(raw) > heap.used) return .object_out_of_bounds;
        assert(at + header_bytes <= heap.used);
        return .ok;
    }

    /// Walks every object: lengths chain exactly to `used`, and nothing is left marked.
    pub fn check(heap: *const StringHeap) Fault {
        assert(heap.bytes.len < mark_bit);
        if (heap.used > heap.bytes.len) return .used_exceeds_capacity;
        var at: u32 = 0;
        while (at < heap.used) {
            if (at + header_bytes > heap.used) return .object_out_of_bounds;
            const raw = std.mem.readInt(u32, heap.bytes[at..][0..4], .little);
            if (raw & mark_bit != 0) return .marked;
            const total = object_bytes(raw);
            if (total > heap.used - at) return .object_out_of_bounds;
            at += total;
        }
        assert(at == heap.used);
        return .ok;
    }

    pub fn verify(heap: *const StringHeap) void {
        assert(heap.used <= heap.bytes.len);
        fault.verify(heap.check());
    }
};

/// Heap positions that must follow compaction, such as the lookahead snapshot's heap tops:
/// string byte offsets and list word offsets.
pub const Marks = struct {
    strings: []u32 = &.{},
    lists: []u32 = &.{},

    pub const count_max = 16;
};

/// Marks from the roots, computes new offsets, rewrites the roots and `marks`, and slides
/// live objects down, for strings and lists both. Returns the bytes and words reclaimed.
pub fn compact(
    strings: *StringHeap,
    lists: *ListSlab,
    roots: anytype,
    marks: Marks,
) struct { bytes: u32, words: u32 } {
    strings.verify();
    var marker: Marker = .{ .strings = strings, .lists = lists };
    roots.visit(&marker);
    plan_strings(strings, marks.strings);
    plan_lists(lists, marks.lists);
    var updater: Updater = .{ .strings = strings, .lists = lists };
    roots.visit(&updater);
    const bytes_before = strings.used;
    const words_before = lists.used;
    slide_strings(strings);
    slide_lists(lists);
    strings.verify();
    assert(strings.used <= bytes_before and lists.used <= words_before);
    return .{ .bytes = bytes_before - strings.used, .words = words_before - lists.used };
}

const Marker = struct {
    strings: *StringHeap,
    lists: *ListSlab,

    pub fn string(marker: *Marker, reference: *StringReference) void {
        assert(marker.strings.used <= marker.strings.bytes.len);
        if (!reference.is_heap()) return;
        const at = reference.heap_offset();
        assert(marker.strings.check_reference(reference.*) == .ok or
            marker.strings.check_reference(reference.*) == .marked);
        const header = marker.strings.bytes[at..][0..4];
        std.mem.writeInt(u32, header, std.mem.readInt(u32, header, .little) | mark_bit, .little);
    }

    pub fn list(marker: *Marker, reference: *ListReference) void {
        assert(marker.lists.used <= marker.lists.words.len);
        const at = @backingInt(reference.*);
        assert(at + ListSlab.header_words <= marker.lists.used);
        // Any value other than `unmarked` means live until the plan assigns the offset.
        marker.lists.words[at] = 0;
    }
};

/// Gives every marked string its new offset (in its forward word), and relocates `marks`:
/// a mark moves to where the first live object at or after it goes.
fn plan_strings(heap: *StringHeap, marks: []u32) void {
    var at: u32 = 0;
    var next: u32 = 0;
    for (marks) |*mark| assert(mark.* <= heap.used);
    var relocated: [Marks.count_max]bool = @splat(false);
    assert(marks.len <= relocated.len);
    while (at < heap.used) {
        relocate(marks, &relocated, at, next);
        const raw = std.mem.readInt(u32, heap.bytes[at..][0..4], .little);
        const total = StringHeap.object_bytes(raw & ~mark_bit);
        if (raw & mark_bit != 0) {
            std.mem.writeInt(u32, heap.bytes[at + 4 ..][0..4], next, .little);
            next += total;
        }
        at += total;
    }
    relocate(marks, &relocated, at, next);
    assert(next <= heap.used);
}

/// Moves every mark not yet moved that lies at or before `at` (an old object start, or the
/// old end) to `next`, where the first live object from `at` on goes.
fn relocate(marks: []u32, relocated: *[Marks.count_max]bool, at: u32, next: u32) void {
    assert(marks.len <= Marks.count_max);
    assert(next <= at);
    for (marks, 0..) |*mark, position| {
        if (!relocated[position] and mark.* <= at) {
            mark.* = next;
            relocated[position] = true;
        }
    }
}

fn plan_lists(slab: *ListSlab, marks: []u32) void {
    var at: u32 = 0;
    var next: u32 = 0;
    for (marks) |*mark| assert(mark.* <= slab.used);
    var relocated: [Marks.count_max]bool = @splat(false);
    assert(marks.len <= relocated.len);
    while (at < slab.used) {
        relocate(marks, &relocated, at, next);
        const total = slab.object_words(at);
        if (slab.words[at] != ListSlab.unmarked) {
            slab.words[at] = next;
            next += total;
        }
        at += total;
    }
    relocate(marks, &relocated, at, next);
    assert(at == slab.used);
    assert(next <= slab.used);
}

const Updater = struct {
    strings: *StringHeap,
    lists: *ListSlab,

    pub fn string(updater: *Updater, reference: *StringReference) void {
        assert(updater.strings.used <= updater.strings.bytes.len);
        if (!reference.is_heap()) return;
        const at = reference.heap_offset();
        const forward = std.mem.readInt(u32, updater.strings.bytes[at + 4 ..][0..4], .little);
        assert(forward <= at);
        reference.* = .heap(forward);
    }

    pub fn list(updater: *Updater, reference: *ListReference) void {
        assert(updater.lists.used <= updater.lists.words.len);
        const at = @backingInt(reference.*);
        const forward = updater.lists.words[at];
        assert(forward != ListSlab.unmarked and forward <= at);
        reference.* = @fromBackingInt(@intCast(forward));
    }
};

fn slide_strings(heap: *StringHeap) void {
    var at: u32 = 0;
    var next: u32 = 0;
    while (at < heap.used) {
        const raw = std.mem.readInt(u32, heap.bytes[at..][0..4], .little);
        const length = raw & ~mark_bit;
        const total = StringHeap.object_bytes(length);
        if (raw & mark_bit != 0) {
            assert(std.mem.readInt(u32, heap.bytes[at + 4 ..][0..4], .little) == next);
            std.mem.copyForwards(u8, heap.bytes[next..][0..total], heap.bytes[at..][0..total]);
            std.mem.writeInt(u32, heap.bytes[next..][0..4], length, .little);
            std.mem.writeInt(u32, heap.bytes[next + 4 ..][0..4], 0, .little);
            next += total;
        }
        at += total;
    }
    if (std.debug.runtime_safety) @memset(heap.bytes[next..heap.used], poison);
    heap.used = next;
    assert(heap.used <= heap.bytes.len);
}

fn slide_lists(slab: *ListSlab) void {
    var at: u32 = 0;
    var next: u32 = 0;
    while (at < slab.used) {
        const total = slab.object_words(at);
        if (slab.words[at] != ListSlab.unmarked) {
            assert(slab.words[at] == next);
            std.mem.copyForwards(u32, slab.words[next..][0..total], slab.words[at..][0..total]);
            slab.words[next] = ListSlab.unmarked;
            next += total;
        }
        at += total;
    }
    if (std.debug.runtime_safety) @memset(slab.words[next..slab.used], ListSlab.unmarked);
    slab.used = next;
    assert(slab.used <= slab.words.len);
}

/// A root set for the tests: a fixed array of values.
const TestRoots = struct {
    values: []value_module.Value,

    pub fn visit(roots: *TestRoots, visitor: anytype) void {
        assert(@TypeOf(visitor) != void);
        assert(roots.values.len < 1 << 16);
        for (roots.values) |*value| {
            switch (value.*) {
                .string => |*reference| visitor.string(reference),
                .tag => |*reference| visitor.string(reference),
                .list => |*reference| visitor.list(reference),
                else => {},
            }
        }
    }
};

fn store_text(heap: *StringHeap, text: []const u8) ?StringReference {
    assert(text.len < 1 << 16);
    const reference = heap.try_allocate(@intCast(text.len)) orelse return null;
    @memcpy(heap.get(reference), text);
    assert(std.mem.eql(u8, heap.get(reference), text));
    return reference;
}

test "live strings and lists survive compaction and keep their order" {
    // Goal: P4.3. Method: interleave live and dead objects, compact, check every live value.
    var bytes: [256]u8 align(4) = undefined;
    var words: [64]u32 = undefined;
    var strings = StringHeap.init(&bytes);
    var lists = ListSlab.init(&words);
    const dead = store_text(&strings, "dead dead dead").?;
    _ = dead;
    var values = [_]value_module.Value{
        .{ .string = store_text(&strings, "first").? },
        .{ .tag = store_text(&strings, "a tag").? },
        .{ .list = try lists.store(&.{ .from_int(1), .from_int(2) }, &.{}) },
        .{ .integer = 7 },
    };
    _ = try lists.store(&.{.from_int(3)}, &.{});
    values[3] = .{ .string = store_text(&strings, "last").? };
    var roots: TestRoots = .{ .values = &values };
    var marks = [_]u32{8};
    var list_marks = [_]u32{lists.used};
    const marks_all: Marks = .{ .strings = &marks, .lists = &list_marks };
    const reclaimed = compact(&strings, &lists, &roots, marks_all);
    try std.testing.expect(reclaimed.bytes > 0 and reclaimed.words > 0);
    try std.testing.expectEqualStrings("first", strings.get(values[0].string));
    try std.testing.expectEqualStrings("a tag", strings.get(values[1].tag));
    try std.testing.expectEqualStrings("last", strings.get(values[3].string));
    try std.testing.expectEqual(@as(usize, 2), lists.view(values[2].list).items.len);
    try std.testing.expect(values[0].string.heap_offset() < values[1].tag.heap_offset());
    // The mark was inside the dead string, so it moves to where the first live one went.
    try std.testing.expectEqual(@as(u32, 0), marks[0]);
    // A mark at the old end moves to the new end.
    try std.testing.expectEqual(lists.used, list_marks[0]);
}

test "a loop that builds garbage stays bounded through compaction" {
    // Goal: P4.3; 10k rounds of string concatenation in a heap far smaller than the total.
    var bytes: [512]u8 align(4) = undefined;
    var words: [16]u32 = undefined;
    var strings = StringHeap.init(&bytes);
    var lists = ListSlab.init(&words);
    var values = [_]value_module.Value{.{ .string = store_text(&strings, "").? }};
    var roots: TestRoots = .{ .values = &values };
    for (0..10_000) |round| {
        // The new string is the old one's last 40 bytes plus one digit.
        var buffer: [64]u8 = undefined;
        const old = strings.get(values[0].string);
        const keep = old[old.len -| 40..];
        @memcpy(buffer[0..keep.len], keep);
        buffer[keep.len] = '0' + @as(u8, @intCast(round % 10));
        const text = buffer[0 .. keep.len + 1];
        const reference = store_text(&strings, text) orelse retry: {
            _ = compact(&strings, &lists, &roots, .{});
            break :retry store_text(&strings, text).?;
        };
        values[0] = .{ .string = reference };
        try std.testing.expect(strings.used <= bytes.len);
    }
    try std.testing.expect(std.mem.endsWith(u8, strings.get(values[0].string), "789"));
}

test "a heap full of live data still fails" {
    // Goal: HeapLimit on a true overflow: compaction frees nothing when everything is live.
    var bytes: [64]u8 align(4) = undefined;
    var words: [8]u32 = undefined;
    var strings = StringHeap.init(&bytes);
    var lists = ListSlab.init(&words);
    var values = [_]value_module.Value{
        .{ .string = store_text(&strings, "0123456789abcdef0123").? },
        .{ .string = store_text(&strings, "0123456789abcdef0123").? },
    };
    var roots: TestRoots = .{ .values = &values };
    try std.testing.expectEqual(@as(?StringReference, null), strings.try_allocate(32));
    const reclaimed = compact(&strings, &lists, &roots, .{});
    try std.testing.expectEqual(@as(u32, 0), reclaimed.bytes);
    try std.testing.expectEqual(@as(?StringReference, null), strings.try_allocate(32));
}

test "a stale reference after compaction is caught" {
    // Goal: negative space; poisoning and check_reference reject a reference that wasn't a
    // root. Method: keep a copy of a reference out of the roots, compact, check it.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    var bytes: [128]u8 align(4) = undefined;
    var words: [8]u32 = undefined;
    var strings = StringHeap.init(&bytes);
    var lists = ListSlab.init(&words);
    _ = store_text(&strings, "garbage garbage garbage").?;
    const kept = store_text(&strings, "kept").?;
    const forgotten = store_text(&strings, "forgotten").?;
    var values = [_]value_module.Value{.{ .string = kept }};
    var roots: TestRoots = .{ .values = &values };
    _ = compact(&strings, &lists, &roots, .{});
    try std.testing.expectEqual(StringHeap.Fault.ok, strings.check_reference(values[0].string));
    try std.testing.expectEqual(
        StringHeap.Fault.object_out_of_bounds,
        strings.check_reference(forgotten),
    );
    try std.testing.expectEqual(poison, bytes[strings.used]);
}
