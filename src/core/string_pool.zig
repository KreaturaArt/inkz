//! Interned strings. All bytes live in one buffer. `StringId`s are dense, so side
//! tables can be indexed by them, and `get` is O(1). Id 0 is always the empty string.
//!
//! A pool grows while a program is built (control plane); a built `Program` holds it const,
//! so it never allocates again: `get` and `find` are lookups only.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const StringId = @import("index.zig").StringId;

/// How many times the table hashed a string: tests check that `intern` hashes once.
var hashes_for_tests: if (builtin.is_test) u64 else void = if (builtin.is_test) 0 else {};

/// How many times a pool looked a string up: tests check the VM never does.
pub var finds_for_tests: if (builtin.is_test) u64 else void = if (builtin.is_test) 0 else {};

fn count_hash() void {
    if (builtin.is_test) hashes_for_tests += 1;
}

pub const empty_id: StringId = @fromBackingInt(@intCast(0));

/// `ends[i]` is one past the last byte of string `i`; string `i` starts at `ends[i - 1]`, or 0.
const Strings = struct {
    bytes: []const u8,
    ends: []const u32,

    fn get(strings: Strings, id: StringId) []const u8 {
        const index = id.to_int();
        assert(index < strings.ends.len);
        const start = if (index == 0) 0 else strings.ends[index - 1];
        const end = strings.ends[index];
        assert(start <= end);
        return strings.bytes[start..end];
    }
};

/// Hashes ids by their bytes, so the table stores only `u32` keys.
const IdContext = struct {
    strings: *const Strings,

    pub fn hash(context: IdContext, key: u32) u64 {
        assert(key < context.strings.ends.len);
        const bytes = context.strings.get(@fromBackingInt(@intCast(key)));
        assert(bytes.len <= context.strings.bytes.len);
        count_hash();
        return std.hash.Wyhash.hash(0, bytes);
    }

    pub fn eql(context: IdContext, a: u32, b: u32) bool {
        assert(a < context.strings.ends.len);
        assert(b < context.strings.ends.len);
        return a == b;
    }
};

/// Looks up ids by the bytes they would have, without inserting.
const BytesAdapter = struct {
    strings: *const Strings,

    pub fn hash(adapter: BytesAdapter, bytes: []const u8) u64 {
        assert(adapter.strings.ends.len > 0);
        count_hash();
        const result = std.hash.Wyhash.hash(0, bytes);
        return result;
    }

    pub fn eql(adapter: BytesAdapter, bytes: []const u8, key: u32) bool {
        assert(key < adapter.strings.ends.len);
        const candidate = adapter.strings.get(@fromBackingInt(@intCast(key)));
        assert(candidate.len <= adapter.strings.bytes.len);
        return std.mem.eql(u8, bytes, candidate);
    }
};

const Table = std.HashMapUnmanaged(u32, void, IdContext, std.hash_map.default_max_load_percentage);

pub const StringPool = struct {
    bytes: std.ArrayList(u8),
    ends: std.ArrayList(u32),
    table: Table,
    /// The view `IdContext` points at while the table is being changed.
    context_strings: Strings = .{ .bytes = &.{}, .ends = &.{} },
    /// The most bytes and strings the pool holds (the ids and ends are `u32`); a test lowers
    /// them.
    bytes_max: u64 = std.math.maxInt(u32),
    strings_max: u64 = std.math.maxInt(u32) - 1,

    pub fn init(gpa: Allocator) Allocator.Error!StringPool {
        var pool: StringPool = .{ .bytes = .empty, .ends = .empty, .table = .empty };
        // Not `pool.deinit`, which asserts the empty string is already there.
        try pool.ends.append(gpa, 0);
        errdefer pool.ends.deinit(gpa);
        try pool.table.putNoClobberContext(gpa, 0, {}, pool.id_context());
        assert(pool.count() == 1);
        assert(pool.get(empty_id).len == 0);
        return pool;
    }

    /// A pool over `bytes` and `ends` (taken on success), with its hash index rebuilt; two
    /// equal strings are an error (program images). `ends` must be valid: `ends[0] == 0`,
    /// never decreasing, the last `bytes.len`.
    pub fn init_unique(
        gpa: Allocator,
        bytes: []u8,
        ends: []u32,
    ) (Allocator.Error || error{DuplicateString})!StringPool {
        assert(ends.len > 0 and ends[0] == 0);
        assert(ends[ends.len - 1] == bytes.len);
        var pool: StringPool = .{
            .bytes = .fromOwnedSlice(bytes),
            .ends = .fromOwnedSlice(ends),
            .table = .empty,
        };
        errdefer pool.table.deinit(gpa);
        try pool.table.ensureTotalCapacityContext(gpa, @intCast(ends.len), pool.id_context());
        const view = pool.strings();
        const adapter: BytesAdapter = .{ .strings = &view };
        for (0..ends.len) |position| {
            const text = view.get(@fromBackingInt(@intCast(position)));
            const entry = pool.table.getOrPutAssumeCapacityAdapted(text, adapter);
            if (entry.found_existing) return error.DuplicateString;
            entry.key_ptr.* = @intCast(position);
        }
        assert(pool.count() == ends.len);
        return pool;
    }

    pub fn deinit(pool: *StringPool, gpa: Allocator) void {
        assert(pool.ends.items.len > 0);
        assert(pool.table.count() == pool.ends.items.len);
        pool.table.deinit(gpa);
        pool.ends.deinit(gpa);
        pool.bytes.deinit(gpa);
        pool.* = undefined;
    }

    pub fn count(pool: *const StringPool) u32 {
        assert(pool.ends.items.len > 0);
        assert(pool.table.count() == pool.ends.items.len);
        return @intCast(pool.ends.items.len);
    }

    /// Returns the id of `bytes`, adding it if it is new: one hash of `bytes`. The room is
    /// made first, so an error leaves the strings and the table as they were.
    pub fn intern(pool: *StringPool, gpa: Allocator, bytes: []const u8) !StringId {
        // Near the bounds, a new string wouldn't fit: only then look it up first.
        const full = pool.bytes.items.len + bytes.len > pool.bytes_max or
            pool.ends.items.len >= pool.strings_max;
        if (full) return pool.find(bytes) orelse error.StringPoolFull;
        try pool.bytes.ensureUnusedCapacity(gpa, bytes.len);
        try pool.ends.ensureUnusedCapacity(gpa, 1);
        try pool.table.ensureUnusedCapacityContext(gpa, 1, pool.id_context());
        const view = pool.strings();
        const adapter: BytesAdapter = .{ .strings = &view };
        const entry = pool.table.getOrPutAssumeCapacityAdapted(bytes, adapter);
        if (entry.found_existing) {
            assert(std.mem.eql(u8, pool.get(@fromBackingInt(@intCast(entry.key_ptr.*))), bytes));
            return @fromBackingInt(@intCast(entry.key_ptr.*));
        }
        pool.bytes.appendSliceAssumeCapacity(bytes);
        pool.ends.appendAssumeCapacity(@intCast(pool.bytes.items.len));
        const id: u32 = @intCast(pool.ends.items.len - 1);
        entry.key_ptr.* = id;
        assert(std.mem.eql(u8, pool.get(@fromBackingInt(@intCast(id))), bytes));
        assert(pool.count() == id + 1);
        return @fromBackingInt(@intCast(id));
    }

    /// The id of `bytes` if it is interned. Never inserts and never allocates.
    pub fn find(pool: *const StringPool, bytes: []const u8) ?StringId {
        if (builtin.is_test) finds_for_tests += 1;
        const view = pool.strings();
        assert(view.ends.len > 0);
        const adapter: BytesAdapter = .{ .strings = &view };
        const key = pool.table.getKeyAdapted(bytes, adapter) orelse return null;
        assert(key < view.ends.len);
        const id: StringId = @fromBackingInt(@intCast(key));
        assert(std.mem.eql(u8, pool.get(id), bytes));
        if (bytes.len == 0) assert(id == empty_id);
        return id;
    }

    /// The bytes of `id`, which must have been issued by this pool.
    pub fn get(pool: *const StringPool, id: StringId) []const u8 {
        assert(!id.is_none());
        const bytes = pool.strings().get(id);
        assert(bytes.len <= pool.bytes.items.len);
        return bytes;
    }

    fn strings(pool: *const StringPool) Strings {
        assert(pool.ends.items.len > 0);
        const result: Strings = .{ .bytes = pool.bytes.items, .ends = pool.ends.items };
        assert(result.ends[result.ends.len - 1] == result.bytes.len);
        return result;
    }

    /// The table's context must see the current buffers, so it is rebuilt for each operation.
    /// It points at a field that lives as long as the call.
    fn id_context(pool: *StringPool) IdContext {
        pool.context_strings = pool.strings();
        assert(pool.context_strings.ends.len == pool.ends.items.len);
        assert(pool.context_strings.bytes.len == pool.bytes.items.len);
        return .{ .strings = &pool.context_strings };
    }
};

test "interning deduplicates and id 0 is the empty string" {
    // Equal bytes get equal ids, different bytes different ids: intern a few
    // strings twice, including "".
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    try std.testing.expectEqual(empty_id, try pool.intern(gpa, ""));
    const hello = try pool.intern(gpa, "hello");
    const world = try pool.intern(gpa, "world");
    try std.testing.expect(hello != world);
    try std.testing.expectEqual(hello, try pool.intern(gpa, "hello"));
    try std.testing.expectEqualStrings("world", pool.get(world));
    try std.testing.expectEqual(@as(u32, 3), pool.count());
}

test "find never inserts" {
    // Lookups have no side effects: find a missing string, then check the count.
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    _ = try pool.intern(gpa, "present");
    try std.testing.expectEqual(@as(?StringId, null), pool.find("absent"));
    try std.testing.expectEqual(@as(u32, 2), pool.count());
    try std.testing.expect(pool.find("present") != null);
}

test "100k strings round-trip, and a pool rebuilt from their bytes finds them all" {
    // Scale and the image loader's path: intern 100k distinct strings, rebuild a pool from
    // copies of the bytes and ends, then look each one up in both.
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    var ids: std.ArrayList(StringId) = .empty;
    defer ids.deinit(gpa);
    var buffer: [32]u8 = undefined;
    for (0..100_000) |number| {
        const text = try std.fmt.bufPrint(&buffer, "string {d}", .{number});
        try ids.append(gpa, try pool.intern(gpa, text));
    }
    var loaded = try StringPool.init_unique(
        gpa,
        try gpa.dupe(u8, pool.bytes.items),
        try gpa.dupe(u32, pool.ends.items),
    );
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 100_001), loaded.count());
    for (ids.items, 0..) |id, number| {
        const text = try std.fmt.bufPrint(&buffer, "string {d}", .{number});
        try std.testing.expectEqualStrings(text, loaded.get(id));
        try std.testing.expectEqual(id, loaded.find(text).?);
        try std.testing.expectEqual(id, pool.find(text).?);
    }
    try std.testing.expectEqual(@as(?StringId, null), loaded.find("string 100000"));
}

test "a pool rebuilt from bytes with two equal strings is rejected" {
    // Program images are untrusted: "a" twice is DuplicateString, and nothing leaks.
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, "aa");
    defer gpa.free(bytes);
    const ends = try gpa.dupe(u32, &.{ 0, 1, 2 });
    defer gpa.free(ends);
    try std.testing.expectError(error.DuplicateString, StringPool.init_unique(gpa, bytes, ends));
}

test "bytes may contain zeros and look alike" {
    // Strings are byte ranges, not NUL-terminated, so prefixes and zeros are distinct.
    // Intern "a", "a\x00" and "ab".
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    const a = try pool.intern(gpa, "a");
    const a_zero = try pool.intern(gpa, "a\x00");
    const ab = try pool.intern(gpa, "ab");
    try std.testing.expect(a != a_zero and a_zero != ab);
    try std.testing.expectEqual(@as(usize, 2), pool.get(a_zero).len);
}

test "intern hashes a string once, new or not" {
    // A counted hash: interning a new string and an existing one each hash once (with room
    // reserved, so no rehash), and the existing one adds no bytes or ends (P16.15).
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    try pool.table.ensureUnusedCapacityContext(gpa, 16, pool.id_context());
    try pool.bytes.ensureUnusedCapacity(gpa, 64);
    try pool.ends.ensureUnusedCapacity(gpa, 16);
    const before = hashes_for_tests;
    const knot = try pool.intern(gpa, "knot");
    try std.testing.expectEqual(before + 1, hashes_for_tests);
    const bytes_count = pool.bytes.items.len;
    const ends_count = pool.ends.items.len;
    try std.testing.expectEqual(knot, try pool.intern(gpa, "knot"));
    try std.testing.expectEqual(before + 2, hashes_for_tests);
    try std.testing.expectEqual(bytes_count, pool.bytes.items.len);
    try std.testing.expectEqual(ends_count, pool.ends.items.len);
}

test "a full pool rejects a new string and stays as it was" {
    // A small bound: the next new string is StringPoolFull and nothing changes; a string
    // already there is still found.
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);
    const knot = try pool.intern(gpa, "knot");
    pool.bytes_max = pool.bytes.items.len + 2;
    const bytes_count = pool.bytes.items.len;
    const strings_count = pool.count();
    try std.testing.expectError(error.StringPoolFull, pool.intern(gpa, "stitch"));
    try std.testing.expectEqual(bytes_count, pool.bytes.items.len);
    try std.testing.expectEqual(strings_count, pool.count());
    try std.testing.expectEqual(@as(u32, strings_count), pool.table.count());
    try std.testing.expect(pool.find("stitch") == null);
    try std.testing.expectEqual(knot, try pool.intern(gpa, "knot"));
    try std.testing.expectEqual(@as(?StringId, try pool.intern(gpa, "ab")), pool.find("ab"));
    pool.strings_max = pool.count();
    try std.testing.expectError(error.StringPoolFull, pool.intern(gpa, "c"));
    try std.testing.expectEqual(strings_count + 1, pool.count());
}
