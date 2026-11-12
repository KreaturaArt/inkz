//! Sets of enum tags as bitsets (plan T7), such as a parser's first and recovery sets. Sets
//! are usually built at compile time (`TagSet(Tag).of(&.{ .a, .b })`) and tested with one
//! bit operation.

const std = @import("std");
const assert = std.debug.assert;

pub fn TagSet(comptime Tag: type) type {
    const info = @typeInfo(Tag).@"enum";
    comptime assert(info.field_names.len > 0);
    comptime assert(info.field_names.len <= 1024);
    const Bits = std.bit_set.Static(info.field_names.len);
    return struct {
        bits: Bits,

        const Self = @This();

        pub const empty: Self = .{ .bits = .empty };
        pub const full: Self = .{ .bits = .full };

        pub fn of(comptime tags: []const Tag) Self {
            comptime {
                var set: Self = empty;
                for (tags) |tag| set.bits.set(position(tag));
                assert(set.count() <= tags.len);
                assert(tags.len == 0 or set.count() > 0);
                return set;
            }
        }

        pub fn contains(set: Self, tag: Tag) bool {
            const result = set.bits.isSet(position(tag));
            if (result) assert(set.count() > 0);
            assert(set.count() <= info.field_names.len);
            return result;
        }

        pub fn count(set: Self) u32 {
            const result: u32 = @intCast(set.bits.count());
            assert(result <= info.field_names.len);
            assert((result == 0) == set.eql(empty));
            return result;
        }

        pub fn eql(a: Self, b: Self) bool {
            const result = a.bits.eql(b.bits);
            assert(result == b.bits.eql(a.bits));
            assert(info.field_names.len > 0);
            return result;
        }

        pub fn union_with(a: Self, b: Self) Self {
            const result: Self = .{ .bits = a.bits.unionWith(b.bits) };
            assert(result.bits.count() >= a.bits.count());
            assert(result.bits.count() >= b.bits.count());
            return result;
        }

        pub fn intersect_with(a: Self, b: Self) Self {
            const result: Self = .{ .bits = a.bits.intersectWith(b.bits) };
            assert(result.bits.count() <= a.bits.count());
            assert(result.bits.count() <= b.bits.count());
            return result;
        }

        pub fn difference_with(a: Self, b: Self) Self {
            const result: Self = .{ .bits = a.bits.intersectWith(b.bits.complement()) };
            assert(result.bits.count() <= a.bits.count());
            assert(result.intersect_with(b).bits.count() == 0);
            return result;
        }

        pub fn complement(set: Self) Self {
            const result: Self = .{ .bits = set.bits.complement() };
            assert(result.bits.count() + set.bits.count() == info.field_names.len);
            assert(result.intersect_with(set).bits.count() == 0);
            return result;
        }

        fn position(tag: Tag) usize {
            const value = @backingInt(tag);
            inline for (info.field_names, 0..) |name, index| {
                if (value == @backingInt(@field(Tag, name))) return index;
            }
            unreachable;
        }
    };
}

const Token = enum(u8) { identifier, number, string, plus, minus, star, end };
const Tokens = TagSet(Token);

test "membership of a comptime set" {
    // Goal: sets built at compile time answer membership. Method: a literal set of three tags.
    const literals = comptime Tokens.of(&.{ .identifier, .number, .string });
    try std.testing.expect(literals.contains(.number));
    try std.testing.expect(!literals.contains(.plus));
    try std.testing.expectEqual(@as(u32, 3), literals.count());
    try std.testing.expectEqual(@as(u32, 0), Tokens.empty.count());
    try std.testing.expectEqual(@as(u32, 7), Tokens.full.count());
}

test "set algebra" {
    // Goal: union, intersection, difference and complement. Method: two overlapping sets.
    const a = comptime Tokens.of(&.{ .plus, .minus, .star });
    const b = comptime Tokens.of(&.{ .minus, .end });
    const all = comptime Tokens.of(&.{ .plus, .minus, .star, .end });
    try std.testing.expect(a.union_with(b).eql(all));
    try std.testing.expect(a.intersect_with(b).eql(comptime Tokens.of(&.{.minus})));
    try std.testing.expect(a.difference_with(b).eql(comptime Tokens.of(&.{ .plus, .star })));
    const not_a = a.complement();
    try std.testing.expect(not_a.contains(.identifier) and !not_a.contains(.plus));
    try std.testing.expect(not_a.complement().eql(a));
}

test "enums with gaps in their values" {
    // Goal: positions follow declaration order, not tag values. Method: a sparse enum.
    const Sparse = enum(u16) { low = 3, high = 900 };
    const set = comptime TagSet(Sparse).of(&.{.high});
    try std.testing.expect(set.contains(.high));
    try std.testing.expect(!set.contains(.low));
}

/// More tags than one 64-bit word holds, like the compiler's token tags.
const Wide = enum {
    t0,
    t1,
    t2,
    t3,
    t4,
    t5,
    t6,
    t7,
    t8,
    t9,
    t10,
    t11,
    t12,
    t13,
    t14,
    t15,
    t16,
    t17,
    t18,
    t19,
    t20,
    t21,
    t22,
    t23,
    t24,
    t25,
    t26,
    t27,
    t28,
    t29,
    t30,
    t31,
    t32,
    t33,
    t34,
    t35,
    t36,
    t37,
    t38,
    t39,
    t40,
    t41,
    t42,
    t43,
    t44,
    t45,
    t46,
    t47,
    t48,
    t49,
    t50,
    t51,
    t52,
    t53,
    t54,
    t55,
    t56,
    t57,
    t58,
    t59,
    t60,
    t61,
    t62,
    t63,
    t64,
    t65,
    t66,
    t67,
    t68,
    t69,
};

test "enums with more tags than a machine word" {
    // Goal: token enums have over 64 tags, which uses a multi-word bitset. Method: a 70-tag
    // enum and a set of its first and last tag.
    const set = comptime TagSet(Wide).of(&.{ .t0, .t69 });
    try std.testing.expect(set.contains(.t69));
    try std.testing.expect(!set.contains(.t50));
    try std.testing.expectEqual(@as(u32, 68), set.complement().count());
    try std.testing.expect(set.union_with(set.complement()).eql(TagSet(Wide).full));
}
