//! Containers: the unit of addressing. Their instructions are one contiguous
//! range of the program's instruction array; named children (knots, stitches, labelled
//! gathers) are a range of the named table. Stored as SoA (`std.MultiArrayList`).

const std = @import("std");
const assert = std.debug.assert;
const index = @import("index.zig");
const ContainerIndex = index.ContainerIndex;
const InstructionIndex = index.InstructionIndex;
const StringId = index.StringId;

/// `index_in_parent` of a container that is only reachable by name.
pub const named_only = std.math.maxInt(u32);

pub const ContainerFlags = packed struct(u8) {
    visits_counted: bool = false,
    turns_counted: bool = false,
    /// Count a visit only when the container is entered at its start.
    count_start_only: bool = false,
    padding: u5 = 0,
};

pub const ContainerInfo = struct {
    instruction_first: InstructionIndex,
    instruction_count: u32,
    parent: ContainerIndex,
    /// The content index of this container in its parent, or `named_only`.
    index_in_parent: u32,
    /// The root has depth 0.
    depth: u16,
    flags: ContainerFlags,
    /// `.none` for anonymous containers.
    name: StringId,
    /// The dotted path, for save/load and choice ids.
    path: StringId,
    /// ink's shuffle seed for this container.
    path_hash: u32,
    named_first: u32,
    named_count: u32,
    /// The dense index into the visit and turn arrays, or `none` if neither is counted.
    count_slot: u32,
};

pub const no_count_slot = std.math.maxInt(u32);

pub const NamedEntry = struct {
    name: StringId,
    child: ContainerIndex,
};

/// Read access to the container tree.
pub const ContainerTable = struct {
    containers: std.MultiArrayList(ContainerInfo).Slice,
    named: []const NamedEntry,

    pub const Fault = enum {
        ok,
        empty,
        root_has_parent,
        root_depth_not_zero,
        parent_out_of_range,
        parent_after_child,
        depth_not_parent_plus_one,
        named_range_out_of_bounds,
        named_child_out_of_range,
        named_child_has_other_parent,
        instructions_out_of_bounds,
    };

    pub fn count(table: *const ContainerTable) u32 {
        const containers_count: u32 = @intCast(table.containers.len);
        assert(containers_count == table.containers.len);
        assert(containers_count < std.math.maxInt(u32));
        return containers_count;
    }

    pub fn get(table: *const ContainerTable, container: ContainerIndex) ContainerInfo {
        const position = container.to_int();
        assert(position < table.containers.len);
        const info = table.containers.get(position);
        assert(info.named_first + info.named_count <= table.named.len);
        return info;
    }

    pub fn parent(table: *const ContainerTable, container: ContainerIndex) ContainerIndex {
        const position = container.to_int();
        assert(position < table.containers.len);
        const result = table.containers.items(.parent)[position];
        assert(result.is_none() == (position == 0));
        return result;
    }

    pub fn depth(table: *const ContainerTable, container: ContainerIndex) u16 {
        const position = container.to_int();
        assert(position < table.containers.len);
        const result = table.containers.items(.depth)[position];
        assert(result > 0 or position == 0);
        return result;
    }

    /// The named child `name` of `container`. Compares string ids only, never bytes.
    pub fn named_child(
        table: *const ContainerTable,
        container: ContainerIndex,
        name: StringId,
    ) ?ContainerIndex {
        assert(!name.is_none());
        const position = container.to_int();
        assert(position < table.containers.len);
        const first = table.containers.items(.named_first)[position];
        const entries = table.named[first..][0..table.containers.items(.named_count)[position]];
        for (entries) |entry| {
            if (entry.name == name) {
                assert(!entry.child.is_none());
                return entry.child;
            }
        }
        return null;
    }

    /// Structural invariants; `instructions_count` is the program's instruction count.
    pub fn check(table: *const ContainerTable, instructions_count: u32) Fault {
        assert(instructions_count < std.math.maxInt(u32));
        if (table.containers.len == 0) return .empty;
        const parents = table.containers.items(.parent);
        const depths = table.containers.items(.depth);
        if (!parents[0].is_none()) return .root_has_parent;
        if (depths[0] != 0) return .root_depth_not_zero;
        for (1..table.containers.len) |position| {
            const container_parent = parents[position];
            if (container_parent.is_none() or container_parent.to_int() >= table.containers.len) {
                return .parent_out_of_range;
            }
            // Parents come first, so one forward pass can check depths.
            if (container_parent.to_int() >= position) return .parent_after_child;
            if (depths[position] != depths[container_parent.to_int()] + 1) {
                return .depth_not_parent_plus_one;
            }
        }
        const result = table.check_ranges(instructions_count);
        assert(result != .empty);
        return result;
    }

    fn check_ranges(table: *const ContainerTable, instructions_count: u32) Fault {
        const slice = table.containers;
        assert(slice.len > 0);
        for (0..slice.len) |position| {
            const first = slice.items(.instruction_first)[position].to_int();
            if (first + slice.items(.instruction_count)[position] > instructions_count) {
                return .instructions_out_of_bounds;
            }
            const named_first = slice.items(.named_first)[position];
            const named_count = slice.items(.named_count)[position];
            if (named_first + named_count > table.named.len) return .named_range_out_of_bounds;
            for (table.named[named_first..][0..named_count]) |entry| {
                if (entry.child.is_none() or entry.child.to_int() >= slice.len) {
                    return .named_child_out_of_range;
                }
                const child_parent = slice.items(.parent)[entry.child.to_int()];
                if (child_parent != ContainerIndex.from_int(@intCast(position))) {
                    return .named_child_has_other_parent;
                }
            }
        }
        assert(table.named.len < std.math.maxInt(u32));
        return .ok;
    }
};

/// A root with two children: `knot` (named only) containing `stitch` (named only), and an
/// anonymous nested container at index 1 of the root.
fn build_test_table(gpa: std.mem.Allocator) !std.MultiArrayList(ContainerInfo) {
    assert(test_named.len == 2);
    var containers: std.MultiArrayList(ContainerInfo) = .empty;
    errdefer containers.deinit(gpa);
    const rows = [_]struct { u32, u32, u32, ?u32, u32, u32 }{
        // instruction_first, count, index_in_parent, parent, named_first, named_count
        .{ 0, 3, named_only, null, 0, 1 },
        .{ 3, 2, named_only, 0, 1, 1 },
        .{ 5, 1, named_only, 1, 2, 0 },
        .{ 6, 2, 1, 0, 2, 0 },
    };
    const depths = [_]u16{ 0, 1, 2, 1 };
    for (rows, depths, 0..) |row, container_depth, position| {
        try containers.append(gpa, .{
            .instruction_first = .from_int(row[0]),
            .instruction_count = row[1],
            .parent = .from_optional(row[3]),
            .index_in_parent = row[2],
            .depth = container_depth,
            .flags = .{},
            .name = if (position == 1 or position == 2) .from_int(@intCast(position)) else .none,
            .path = .from_int(10 + @as(u32, @intCast(position))),
            .path_hash = 0,
            .named_first = row[4],
            .named_count = row[5],
            .count_slot = no_count_slot,
        });
    }
    assert(containers.len == rows.len);
    return containers;
}

const test_named = [_]NamedEntry{
    .{ .name = .from_int(1), .child = .from_int(1) },
    .{ .name = .from_int(2), .child = .from_int(2) },
};

test "named lookup and tree navigation" {
    // Names resolve by id within one container only: look up `knot` at the root
    // and `stitch` inside it, and miss `stitch` at the root.
    const gpa = std.testing.allocator;
    var containers = try build_test_table(gpa);
    defer containers.deinit(gpa);
    const table: ContainerTable = .{ .containers = containers.slice(), .named = &test_named };
    try std.testing.expectEqual(ContainerTable.Fault.ok, table.check(8));
    const root: ContainerIndex = .from_int(0);
    const knot = table.named_child(root, .from_int(1)).?;
    try std.testing.expectEqual(ContainerIndex.from_int(1), knot);
    const stitch = table.named_child(knot, .from_int(2)).?;
    try std.testing.expectEqual(ContainerIndex.from_int(2), stitch);
    try std.testing.expectEqual(@as(?ContainerIndex, null), table.named_child(root, .from_int(2)));
    try std.testing.expectEqual(@as(u16, 2), table.depth(.from_int(2)));
    try std.testing.expectEqual(root, table.parent(knot));
}

test "check reports broken tree invariants" {
    // Negative space: corrupt one field at a time.
    const gpa = std.testing.allocator;
    var containers = try build_test_table(gpa);
    defer containers.deinit(gpa);
    const table: ContainerTable = .{ .containers = containers.slice(), .named = &test_named };
    const Fault = ContainerTable.Fault;
    try std.testing.expectEqual(Fault.ok, table.check(8));
    try std.testing.expectEqual(Fault.instructions_out_of_bounds, table.check(7));
    containers.items(.depth)[3] = 2;
    try std.testing.expectEqual(Fault.depth_not_parent_plus_one, table.check(8));
    containers.items(.depth)[3] = 1;
    containers.items(.parent)[1] = .from_int(3);
    try std.testing.expectEqual(Fault.parent_after_child, table.check(8));
    containers.items(.parent)[1] = .from_int(0);
    const stray: NamedEntry = .{ .name = .from_int(2), .child = .from_int(3) };
    const bad_named = [_]NamedEntry{ test_named[0], stray };
    const wrong: ContainerTable = .{ .containers = containers.slice(), .named = &bad_named };
    try std.testing.expectEqual(Fault.named_child_has_other_parent, wrong.check(8));
}
