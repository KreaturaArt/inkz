const std = @import("std");
const value = @import("value.zig");
const lists = @import("lists.zig");

pub const RuntimeObject = value.RuntimeObject;
pub const NativeFunction = value.NativeFunction;
pub const InkList = lists.InkList;

/// Coerce a value to f64 for arithmetic. Returns null if not numeric.
fn toFloat(obj: RuntimeObject) ?f64 {
    return switch (obj) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        .bool => |b| if (b) 1.0 else 0.0,
        else => null,
    };
}

/// Coerce a value to i64 for arithmetic. Returns null if not numeric.
fn toInt(obj: RuntimeObject) ?i64 {
    return switch (obj) {
        .int => |n| n,
        .float => |f| @intFromFloat(f),
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}

/// Returns true if obj is "truthy" (non-zero, non-false, non-void).
/// Matches ink: empty list and empty string are false.
pub fn isTruthy(obj: RuntimeObject) bool {
    return switch (obj) {
        .bool => |b| b,
        .int => |n| n != 0,
        .float => |f| f != 0.0,
        .void => false,
        .list => |l| l.items.count() != 0,
        .string => |s| s.len != 0,
        else => true,
    };
}

// ── List helpers ─────────────────────────────────────────────────────────────

fn createListUnion(allocator: std.mem.Allocator, lhs: *const InkList, rhs: *const InkList) !*InkList {
    const result = try allocator.create(InkList);
    result.* = .{};
    var it = lhs.items.iterator();
    while (it.next()) |e| try result.items.put(allocator, e.key_ptr.*, e.value_ptr.*);
    var it2 = rhs.items.iterator();
    while (it2.next()) |e| try result.items.put(allocator, e.key_ptr.*, e.value_ptr.*);
    return result;
}

fn createListDiff(allocator: std.mem.Allocator, lhs: *const InkList, rhs: *const InkList) !*InkList {
    const result = try allocator.create(InkList);
    result.* = .{};
    var it = lhs.items.iterator();
    while (it.next()) |e| {
        if (!rhs.items.contains(e.key_ptr.*))
            try result.items.put(allocator, e.key_ptr.*, e.value_ptr.*);
    }
    return result;
}

fn createListIntersect(allocator: std.mem.Allocator, lhs: *const InkList, rhs: *const InkList) !*InkList {
    const result = try allocator.create(InkList);
    result.* = .{};
    var it = lhs.items.iterator();
    while (it.next()) |e| {
        if (rhs.items.contains(e.key_ptr.*))
            try result.items.put(allocator, e.key_ptr.*, e.value_ptr.*);
    }
    return result;
}

/// Returns true if rhs is non-empty and every item in rhs is present in lhs.
/// Ink semantics: `anything ? {}` is always false (empty list on right → false).
fn listContainsAll(lhs: *const InkList, rhs: *const InkList) bool {
    if (rhs.items.count() == 0) return false;
    var it = rhs.items.iterator();
    while (it.next()) |e| {
        if (!lhs.items.contains(e.key_ptr.*)) return false;
    }
    return true;
}

fn listEquals(lhs: *const InkList, rhs: *const InkList) bool {
    if (lhs.items.count() != rhs.items.count()) return false;
    var it = lhs.items.iterator();
    while (it.next()) |e| {
        const rv = rhs.items.get(e.key_ptr.*) orelse return false;
        if (rv != e.value_ptr.*) return false;
    }
    return true;
}

// ── Native function dispatch ──────────────────────────────────────────────────

/// Execute a native function by popping args from the stack and pushing the result.
pub fn callNativeFunction(allocator: std.mem.Allocator, op: NativeFunction, stack: *std.ArrayList(RuntimeObject)) !void {
    switch (op) {
        // Unary
        .negate => {
            const a = stack.pop().?;
            switch (a) {
                .int => |n| stack.appendAssumeCapacity(.{ .int = -n }),
                .float => |f| stack.appendAssumeCapacity(.{ .float = -f }),
                else => return error.TypeMismatch,
            }
        },
        .not => {
            const a = stack.pop().?;
            stack.appendAssumeCapacity(.{ .bool = !isTruthy(a) });
        },
        .int_cast => {
            const a = stack.pop().?;
            switch (a) {
                .int => stack.appendAssumeCapacity(a),
                .float => |f| stack.appendAssumeCapacity(.{ .int = @intFromFloat(f) }),
                .bool => |b| stack.appendAssumeCapacity(.{ .int = if (b) 1 else 0 }),
                .string => |s| {
                    const n = std.fmt.parseInt(i64, s, 10) catch return error.TypeMismatch;
                    stack.appendAssumeCapacity(.{ .int = n });
                },
                else => return error.TypeMismatch,
            }
        },
        .float_cast => {
            const a = stack.pop().?;
            switch (a) {
                .float => stack.appendAssumeCapacity(a),
                .int => |n| stack.appendAssumeCapacity(.{ .float = @floatFromInt(n) }),
                .bool => |b| stack.appendAssumeCapacity(.{ .float = if (b) 1.0 else 0.0 }),
                .string => |s| {
                    const f = std.fmt.parseFloat(f64, s) catch return error.TypeMismatch;
                    stack.appendAssumeCapacity(.{ .float = f });
                },
                else => return error.TypeMismatch,
            }
        },
        .floor => {
            const a = stack.pop().?;
            switch (a) {
                .int => stack.appendAssumeCapacity(a),
                .float => |f| stack.appendAssumeCapacity(.{ .int = @intFromFloat(@floor(f)) }),
                else => return error.TypeMismatch,
            }
        },
        .ceiling => {
            const a = stack.pop().?;
            switch (a) {
                .int => stack.appendAssumeCapacity(a),
                .float => |f| stack.appendAssumeCapacity(.{ .int = @intFromFloat(@ceil(f)) }),
                else => return error.TypeMismatch,
            }
        },
        // Binary arithmetic
        .add => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            // List union
            if (lhs == .list and rhs == .list) {
                const result = try createListUnion(allocator, lhs.list, rhs.list);
                stack.appendAssumeCapacity(.{ .list = result });
                return;
            }
            // String concatenation
            if (lhs == .string and rhs == .string) {
                // String concat is handled by story.handleNativeFunction before reaching here.
                return error.StringConcatNotSupported;
            }
            // Numeric
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .float = l + r });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .int = l + r });
            }
        },
        .subtract => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            // List difference
            if (lhs == .list and rhs == .list) {
                const result = try createListDiff(allocator, lhs.list, rhs.list);
                stack.appendAssumeCapacity(.{ .list = result });
                return;
            }
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .float = l - r });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .int = l - r });
            }
        },
        .multiply => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .float = l * r });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .int = l * r });
            }
        },
        .divide => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                if (r == 0.0) return error.DivisionByZero;
                stack.appendAssumeCapacity(.{ .float = l / r });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                if (r == 0) return error.DivisionByZero;
                // Integer division truncates toward zero
                stack.appendAssumeCapacity(.{ .int = @divTrunc(l, r) });
            }
        },
        .mod => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const l = toInt(lhs) orelse return error.TypeMismatch;
            const r = toInt(rhs) orelse return error.TypeMismatch;
            if (r == 0) return error.DivisionByZero;
            stack.appendAssumeCapacity(.{ .int = @mod(l, r) });
        },
        // Comparison
        .equal => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const result = valuesEqual(lhs, rhs);
            stack.appendAssumeCapacity(.{ .int = if (result) 1 else 0 });
        },
        .not_equal => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const result = valuesEqual(lhs, rhs);
            stack.appendAssumeCapacity(.{ .int = if (!result) 1 else 0 });
        },
        .greater => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const l = toFloat(lhs) orelse return error.TypeMismatch;
            const r = toFloat(rhs) orelse return error.TypeMismatch;
            stack.appendAssumeCapacity(.{ .int = if (l > r) 1 else 0 });
        },
        .less => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const l = toFloat(lhs) orelse return error.TypeMismatch;
            const r = toFloat(rhs) orelse return error.TypeMismatch;
            stack.appendAssumeCapacity(.{ .int = if (l < r) 1 else 0 });
        },
        .greater_or_equal => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const l = toFloat(lhs) orelse return error.TypeMismatch;
            const r = toFloat(rhs) orelse return error.TypeMismatch;
            stack.appendAssumeCapacity(.{ .int = if (l >= r) 1 else 0 });
        },
        .less_or_equal => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            const l = toFloat(lhs) orelse return error.TypeMismatch;
            const r = toFloat(rhs) orelse return error.TypeMismatch;
            stack.appendAssumeCapacity(.{ .int = if (l <= r) 1 else 0 });
        },
        .and_ => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            stack.appendAssumeCapacity(.{ .int = if (isTruthy(lhs) and isTruthy(rhs)) 1 else 0 });
        },
        .or_ => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            stack.appendAssumeCapacity(.{ .int = if (isTruthy(lhs) or isTruthy(rhs)) 1 else 0 });
        },
        .min => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .float = @min(l, r) });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .int = @min(l, r) });
            }
        },
        .max => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .float or rhs == .float) {
                const l = toFloat(lhs) orelse return error.TypeMismatch;
                const r = toFloat(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .float = @max(l, r) });
            } else {
                const l = toInt(lhs) orelse return error.TypeMismatch;
                const r = toInt(rhs) orelse return error.TypeMismatch;
                stack.appendAssumeCapacity(.{ .int = @max(l, r) });
            }
        },
        // List builtins handled by the Story (need list_defs access)
        .list_value, .list_count, .list_min, .list_max, .list_all, .list_invert => {
            // These are dispatched in story.handleNativeFunction before reaching here
            return error.UnhandledListBuiltin;
        },
        // List operations
        .list_intersect => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .list and rhs == .list) {
                const result = try createListIntersect(allocator, lhs.list, rhs.list);
                stack.appendAssumeCapacity(.{ .list = result });
            } else {
                stack.appendAssumeCapacity(.{ .int = 0 });
            }
        },
        .list_has => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .list and rhs == .list) {
                stack.appendAssumeCapacity(.{ .int = if (listContainsAll(lhs.list, rhs.list)) 1 else 0 });
            } else if (lhs == .string and rhs == .string) {
                stack.appendAssumeCapacity(.{ .int = if (std.mem.indexOf(u8, lhs.string, rhs.string) != null) 1 else 0 });
            } else {
                stack.appendAssumeCapacity(.{ .int = 0 });
            }
        },
        .list_hasnt => {
            const rhs = stack.pop().?;
            const lhs = stack.pop().?;
            if (lhs == .list and rhs == .list) {
                stack.appendAssumeCapacity(.{ .int = if (!listContainsAll(lhs.list, rhs.list)) 1 else 0 });
            } else if (lhs == .string and rhs == .string) {
                stack.appendAssumeCapacity(.{ .int = if (std.mem.indexOf(u8, lhs.string, rhs.string) == null) 1 else 0 });
            } else {
                stack.appendAssumeCapacity(.{ .int = 1 });
            }
        },
    }
}

/// String concatenation variant that takes an allocator.
pub fn addStrings(allocator: std.mem.Allocator, stack: *std.ArrayList(RuntimeObject)) !void {
    const rhs = stack.pop().?;
    const lhs = stack.pop().?;
    if (lhs != .string or rhs != .string) return error.TypeMismatch;
    const joined = try std.mem.concat(allocator, u8, &.{ lhs.string, rhs.string });
    stack.appendAssumeCapacity(.{ .string = joined });
}

fn valuesEqual(lhs: RuntimeObject, rhs: RuntimeObject) bool {
    switch (lhs) {
        .int => |l| switch (rhs) {
            .int => |r| return l == r,
            .float => |r| return @as(f64, @floatFromInt(l)) == r,
            .bool => |r| return (l != 0) == r,
            else => return false,
        },
        .float => |l| switch (rhs) {
            .float => |r| return l == r,
            .int => |r| return l == @as(f64, @floatFromInt(r)),
            else => return false,
        },
        .bool => |l| switch (rhs) {
            .bool => |r| return l == r,
            .int => |r| return l == (r != 0),
            else => return false,
        },
        .string => |l| switch (rhs) {
            .string => |r| return std.mem.eql(u8, l, r),
            else => return false,
        },
        .list => |l| switch (rhs) {
            .list => |r| return listEquals(l, r),
            else => return false,
        },
        .divert_target => |l| switch (rhs) {
            .divert_target => |r| return std.mem.eql(u8, l, r),
            else => return false,
        },
        else => return false,
    }
}
