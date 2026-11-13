//! Ink path strings, parsed and resolved without allocating. Used on the control
//! plane only: the loader, `choose_path_string`, `visit_count_at_path_string` and save/load.
//!
//! A path is components separated by `.`: a name (`knot`), an index into a container's content
//! (`2`), or `^` for the parent. A leading `.` makes it relative. The empty path is the root.
//!
//! Resolution follows ink's `Object.ResolvePath` and `Container.ContentAtPath`. A relative path
//! from a non-container object starts at that object's container, and its first component must
//! be `^`, which moves from the object to the container. A path that runs out of matches stops
//! at the last thing it found and is marked `approximate`, as ink does.

const std = @import("std");
const assert = std.debug.assert;
const ContainerIndex = @import("index.zig").ContainerIndex;

pub const parent_name = "^";

/// ink's shuffle seed for a container: the sum of its path's UTF-16 code units, as C# sums the
/// `char`s of a string. Invalid UTF-8 counts byte by byte.
pub fn shuffle_hash(path_text: []const u8) u32 {
    var hash: u32 = 0;
    var view = std.unicode.Utf8View.init(path_text) catch {
        for (path_text) |byte| hash +%= byte;
        return hash;
    };
    var code_points = view.iterator();
    while (code_points.nextCodepoint()) |code_point| {
        if (code_point < 0x10000) {
            hash +%= code_point;
        } else {
            // A surrogate pair: both halves count.
            const offset = code_point - 0x10000;
            hash +%= 0xD800 + (offset >> 10);
            hash +%= 0xDC00 + (offset & 0x3FF);
        }
    }
    assert(path_text.len > 0 or hash == 0);
    return hash;
}

pub const Component = union(enum) {
    index: u32,
    name: []const u8,
    parent,
};

pub const Error = error{
    /// `a..b`, a trailing `.`, or `.` alone.
    EmptyComponent,
    /// More than `components_max` components.
    TooManyComponents,
    /// `-1`: ink parses it as an index and then asserts that indices are not negative.
    NegativeIndex,
    /// A relative path from a non-container object that doesn't start with `^`.
    RelativeFromContentWithoutParent,
};

pub const Path = struct {
    /// The components, without the leading `.` of a relative path.
    text: []const u8,
    relative: bool,
    components_count: u32,

    /// Validates `text` completely, so iterating it later can't fail.
    pub fn parse(text: []const u8, components_max: u32) Error!Path {
        assert(components_max > 0);
        const relative = text.len > 0 and text[0] == '.';
        const rest = if (relative) text[1..] else text;
        var path: Path = .{ .text = rest, .relative = relative, .components_count = 0 };
        if (rest.len == 0) {
            if (relative) return error.EmptyComponent;
            return path;
        }
        var parts = std.mem.splitScalar(u8, rest, '.');
        while (parts.next()) |part| {
            if (path.components_count == components_max) return error.TooManyComponents;
            _ = try parse_component(part);
            path.components_count += 1;
        }
        assert(path.components_count > 0);
        assert(path.components_count <= components_max);
        return path;
    }

    pub fn iterator(path: Path) Iterator {
        assert(path.text.len > 0 or path.components_count == 0);
        const result: Iterator = .{
            .parts = std.mem.splitScalar(u8, path.text, '.'),
            .remaining = path.components_count,
        };
        assert(result.remaining == path.components_count);
        return result;
    }

    pub fn first(path: Path) ?Component {
        assert(path.text.len > 0 or path.components_count == 0);
        var components = path.iterator();
        const component = components.next();
        assert((component == null) == (path.components_count == 0));
        return component;
    }
};

pub const Iterator = struct {
    parts: std.mem.SplitIterator(u8, .scalar),
    remaining: u32,

    pub fn next(iterator: *Iterator) ?Component {
        if (iterator.remaining == 0) return null;
        const part = iterator.parts.next().?;
        iterator.remaining -= 1;
        // `Path.parse` validated every component, so this can't fail.
        const component = parse_component(part) catch unreachable;
        assert(part.len > 0);
        return component;
    }
};

fn parse_component(part: []const u8) Error!Component {
    if (part.len == 0) return error.EmptyComponent;
    if (std.mem.eql(u8, part, parent_name)) return .parent;
    const negative = part[0] == '-' and part.len > 1;
    const digits = if (negative) part[1..] else part;
    for (digits) |character| {
        if (!std.ascii.isDigit(character)) return .{ .name = part };
    }
    if (negative) return error.NegativeIndex;
    // Ink uses int.TryParse, so an index too large for an int is a name; it never matches.
    const value = std.fmt.parseInt(i32, digits, 10) catch return .{ .name = part };
    assert(value >= 0);
    assert(part.len > 0);
    return .{ .index = @intCast(value) };
}

/// Where a path ends: a container, or a content item inside one.
pub const Target = struct {
    container: ContainerIndex,
    /// The content index inside `container`, or null when the target is `container` itself.
    content_index: ?u32,
    /// Part of the path didn't match; the target is where matching stopped.
    approximate: bool,
};

/// Where resolution starts: the root, a container, or a content item inside a container.
pub const Origin = struct {
    container: ContainerIndex,
    /// Set when the path is relative to a content item rather than to `container`.
    from_content: bool = false,
};

/// Resolves `path` against `table`, which provides:
///   `root_container() ContainerIndex`, `parent(ContainerIndex) ContainerIndex` (`.none` for
///   the root),
///   `named_child(ContainerIndex, []const u8) ?ContainerIndex`,
///   `content_count(ContainerIndex) u32`, and
///   `container_at(ContainerIndex, u32) ?ContainerIndex` (when that content item is one).
pub fn resolve(table: anytype, origin: Origin, path: Path) Error!Target {
    assert(!origin.container.is_none());
    var components = path.iterator();
    var current = if (path.relative) origin.container else table.root_container();
    if (path.relative and origin.from_content) {
        // Ink drops the first `^`: it moves from the content item to its container.
        if (components.next()) |component| {
            if (component != .parent) return error.RelativeFromContentWithoutParent;
        } else return error.RelativeFromContentWithoutParent;
    }
    var result = found(current, null);
    while (components.next()) |component| {
        if (result.content_index != null) {
            // The previous component found content that isn't a container.
            result.approximate = true;
            break;
        }
        const step = resolve_component(table, current, component) orelse {
            result.approximate = true;
            break;
        };
        result = step;
        current = step.container;
    }
    assert(!result.container.is_none());
    if (result.content_index) |index| assert(index < table.content_count(result.container));
    return result;
}

/// One step from `container` through `component`, or null if nothing matches.
fn resolve_component(table: anytype, container: ContainerIndex, component: Component) ?Target {
    assert(!container.is_none());
    // An index into an empty container finds nothing (a corrupt or changed path).
    if (component == .index and table.content_count(container) == 0) return null;
    const result: ?Target = switch (component) {
        .parent => parent: {
            const parent = table.parent(container);
            break :parent if (parent.is_none()) null else found(parent, null);
        },
        .name => |name| named: {
            const child = table.named_child(container, name) orelse break :named null;
            break :named found(child, null);
        },
        .index => |index| indexed: {
            if (index >= table.content_count(container)) break :indexed null;
            const child = table.container_at(container, index) orelse
                break :indexed found(container, index);
            break :indexed found(child, null);
        },
    };
    if (result) |step| assert(!step.container.is_none());
    return result;
}

fn found(container: ContainerIndex, content_index: ?u32) Target {
    assert(!container.is_none());
    const result: Target = .{
        .container = container,
        .content_index = content_index,
        .approximate = false,
    };
    assert(!result.approximate);
    return result;
}

/// A small container tree for the tests:
///   root (0): content [text, c-0 (1), text]; named-only: knot (2)
///   c-0 (1): content [text, text]
///   knot (2): content [text]; named-only: stitch (3)
///   stitch (3): content [text, text, text]
const TestTable = struct {
    const Node = struct { parent: u32, content_count: u32, container_at: ?struct { u32, u32 } };
    const nodes = [_]Node{
        .{ .parent = none, .content_count = 3, .container_at = .{ 1, 1 } },
        .{ .parent = 0, .content_count = 2, .container_at = null },
        .{ .parent = 0, .content_count = 1, .container_at = null },
        .{ .parent = 2, .content_count = 3, .container_at = null },
    };
    const none = std.math.maxInt(u32);
    const Named = struct { container: u32, name: []const u8, child: u32 };
    const named = [_]Named{
        .{ .container = 0, .name = "c-0", .child = 1 },
        .{ .container = 0, .name = "knot", .child = 2 },
        .{ .container = 2, .name = "stitch", .child = 3 },
    };

    fn root_container(_: TestTable) ContainerIndex {
        assert(nodes.len > 0);
        assert(nodes[0].parent == none);
        return .from_int(0);
    }

    fn parent(_: TestTable, container: ContainerIndex) ContainerIndex {
        const node = nodes[container.to_int()];
        assert(node.parent == none or node.parent < nodes.len);
        return if (node.parent == none) .none else .from_int(node.parent);
    }

    fn named_child(_: TestTable, container: ContainerIndex, name: []const u8) ?ContainerIndex {
        assert(container.to_int() < nodes.len);
        for (named) |entry| {
            assert(entry.child < nodes.len);
            if (entry.container != container.to_int()) continue;
            if (std.mem.eql(u8, entry.name, name)) return .from_int(entry.child);
        }
        return null;
    }

    fn content_count(_: TestTable, container: ContainerIndex) u32 {
        const count = nodes[container.to_int()].content_count;
        assert(count > 0);
        assert(count < 16);
        return count;
    }

    fn container_at(_: TestTable, container: ContainerIndex, index: u32) ?ContainerIndex {
        const node = nodes[container.to_int()];
        assert(index < node.content_count);
        const entry = node.container_at orelse return null;
        assert(entry[1] < nodes.len);
        return if (entry[0] == index) .from_int(entry[1]) else null;
    }
};

fn expect_target(text: []const u8, origin: Origin, expected: Target) !void {
    assert(text.len < 64);
    assert(!origin.container.is_none());
    const path = try Path.parse(text, 8);
    const resolved = try resolve(TestTable{}, origin, path);
    try std.testing.expectEqual(expected, resolved);
}

/// A target in the test table: container `container`, optionally a content index in it.
fn test_target(container: u32, content_index: ?u32, is_approximate: bool) Target {
    assert(container < TestTable.nodes.len);
    if (content_index) |index| assert(index < TestTable.nodes[container].content_count);
    return .{
        .container = .from_int(container),
        .content_index = content_index,
        .approximate = is_approximate,
    };
}

const root_origin: Origin = .{ .container = .from_int(0) };
const exact = false;
const inexact = true;

test "shuffle_hash sums UTF-16 code units like ink" {
    // Values from test/ground_truth/audit/unicode_paths.paths (ink on
    // .NET 8), and a character outside the Basic Multilingual Plane.
    try std.testing.expectEqual(@as(u32, 0), shuffle_hash(""));
    try std.testing.expectEqual(@as(u32, 290), shuffle_hash("0.g-0"));
    try std.testing.expectEqual(@as(u32, 531), shuffle_hash("café"));
    try std.testing.expectEqual(@as(u32, 1723), shuffle_hash("naïve.ünïcode"));
    // U+1F600 is the pair D83D DE00 in UTF-16.
    try std.testing.expectEqual(@as(u32, 0xD83D + 0xDE00), shuffle_hash("\u{1F600}"));
}

test "parse components, relative paths and the root path" {
    // The component grammar: parse each kind and walk the components.
    const path = try Path.parse(".^.knot.2", 8);
    try std.testing.expect(path.relative);
    var components = path.iterator();
    try std.testing.expectEqual(Component.parent, components.next().?);
    try std.testing.expectEqualStrings("knot", components.next().?.name);
    try std.testing.expectEqual(@as(u32, 2), components.next().?.index);
    try std.testing.expectEqual(@as(?Component, null), components.next());
    const root_path = try Path.parse("", 8);
    try std.testing.expectEqual(@as(u32, 0), root_path.components_count);
    // Too large for an int, so ink treats it as a name.
    const huge = try Path.parse("99999999999", 8);
    try std.testing.expectEqualStrings("99999999999", huge.first().?.name);
}

test "malformed paths return named errors" {
    // Negative space for the parser: one string per error.
    try std.testing.expectError(error.EmptyComponent, Path.parse("a..b", 8));
    try std.testing.expectError(error.EmptyComponent, Path.parse("knot.", 8));
    try std.testing.expectError(error.EmptyComponent, Path.parse(".", 8));
    try std.testing.expectError(error.NegativeIndex, Path.parse("knot.-1", 8));
    try std.testing.expectError(error.TooManyComponents, Path.parse("a.b.c", 2));
}

test "absolute paths resolve through names, indices and nested containers" {
    // The common absolute forms: resolve against the test table.
    try expect_target("", root_origin, test_target(0, null, exact));
    try expect_target("knot.stitch", root_origin, test_target(3, null, exact));
    try expect_target("knot.stitch.2", root_origin, test_target(3, 2, exact));
    // Index 1 of the root is the nested container c-0.
    try expect_target("1.0", root_origin, test_target(1, 0, exact));
    try expect_target("c-0", root_origin, test_target(1, null, exact));
}

test "relative paths from a container and from a content item" {
    // Ink's two relative cases: `.^` from a container goes to its parent; from a
    // content item the first `^` only leaves the item.
    const stitch: Origin = .{ .container = .from_int(3) };
    try expect_target(".^", stitch, test_target(2, null, exact));
    const in_stitch: Origin = .{ .container = .from_int(3), .from_content = true };
    try expect_target(".^", in_stitch, test_target(3, null, exact));
    try expect_target(".^.^.0", in_stitch, test_target(2, 0, exact));
    const path = try Path.parse(".knot", 8);
    const result = resolve(TestTable{}, in_stitch, path);
    try std.testing.expectError(error.RelativeFromContentWithoutParent, result);
}

test "paths that stop matching are approximate" {
    // Ink's fallback for stale paths (for example after a story changed under a save).
    // A missing name, an index out of range, descending into plain content, and going
    // above the root.
    try expect_target("knot.missing", root_origin, test_target(2, null, inexact));
    try expect_target("knot.5", root_origin, test_target(2, null, inexact));
    try expect_target("knot.stitch.0.1", root_origin, test_target(3, 0, inexact));
    try expect_target(".^", root_origin, test_target(0, null, inexact));
}
