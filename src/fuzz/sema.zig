//! Fuzz target for the object tree and name resolution: generated ink that
//! parses without errors, as the compiler takes it, through sema.build_tree and
//! resolve.resolve.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const grammar = @import("../compiler/grammar.zig");
const sema = @import("../compiler/sema.zig");
const resolve = @import("../compiler/resolve.zig");
const compile = @import("../compiler/compile.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;

fn sema_resolve(_: void, smith: *Smith) anyerror!void {
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    const choices: fuzz_ink.Choices = .{ .smith = smith };
    const splices = smith.boolWeighted(7, 1);
    const source = fuzz_ink.Generator.generate(choices, &buffer, .{ .splices = splices });
    _ = try check_source(source);
}

/// Builds and resolves `source`'s tree when it parses as the compiler needs; whether it did.
fn check_source(source: []const u8) !bool {
    assert(source.len <= fuzz_ink.source_bytes_max);
    const gpa = std.testing.allocator;
    var parsed = grammar.parse(gpa, source, .{}) catch |err| switch (err) {
        error.ParseFailed, error.WorkspaceFull => return false,
        else => return err,
    };
    defer parsed.deinit(gpa);
    for (parsed.diagnostics()) |diagnostic| {
        if (!compile.is_warning(diagnostic)) return false;
    }
    var tree = try sema.build_tree(gpa, &parsed);
    defer tree.deinit(gpa);
    check_tree(&tree, @intCast(parsed.tree.tags.len));
    var resolution = try resolve.resolve(gpa, &parsed, &tree);
    defer resolution.deinit(gpa);
    check_resolution(&resolution, &tree);
    return true;
}

/// Every object but the root is the child of exactly its parent, once.
fn check_tree(tree: *const Tree, nodes_count: u32) void {
    const count = tree.count();
    assert(tree.parent(Tree.root) == .none);
    assert(tree.kind(Tree.root) == .story);
    var children_total: u64 = 0;
    for (0..count) |position| {
        const object: ObjectIndex = .from_int(@intCast(position));
        const node = tree.node(object);
        assert(node == .none or node.to_int() < nodes_count);
        for (tree.children_of(object)) |child| {
            assert(child.to_int() < count and child != Tree.root);
            assert(tree.parent(child) == object);
        }
        children_total += tree.children_of(object).len;
        if (position == 0) continue;
        const parent = tree.parent(object);
        assert(parent.to_int() < count);
        assert(std.mem.indexOfScalar(ObjectIndex, tree.children_of(parent), object) != null);
    }
    assert(children_total == count - 1);
}

fn check_resolution(resolution: *const resolve.Resolution, tree: *const Tree) void {
    const count = tree.count();
    assert(resolution.targets.len == count);
    assert(resolution.item_values.len == count);
    for (resolution.targets) |target| assert(target == .none or target.to_int() < count);
    for (resolution.lists) |list| assert(list.to_int() < count);
    for (resolution.diagnostics) |diagnostic| {
        assert(diagnostic.object == .none or diagnostic.object.to_int() < count);
    }
}

test "fuzz: sema and resolve build a consistent tree and resolution" {
    // Seeded sources first: most reach resolution, and their trees and resolutions check.
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var resolved: u32 = 0;
    for (0..32) |seed| {
        const source = fuzz_ink.generate_seeded(seed, &buffer, .{});
        if (try check_source(source)) resolved += 1;
    }
    try std.testing.expect(resolved > 16);
    try std.testing.fuzz({}, sema_resolve, .{ .corpus = &.{""} });
}
