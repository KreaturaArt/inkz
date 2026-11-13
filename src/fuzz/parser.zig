//! Fuzz target for the parser (plan P11.4): generated ink, with raw bytes spliced in, through
//! grammar.parse. A parse gives a tree or an error; a tree's every reachable node has a valid
//! shape, each node is reached once, and its tokens lie in the source.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const grammar = @import("../compiler/grammar.zig");
const ast_module = @import("../compiler/ast.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const NodeIndex = ast_module.NodeIndex;

const nodes_max = 1 << 16;

fn parse(_: void, smith: *Smith) anyerror!void {
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    const choices: fuzz_ink.Choices = .{ .smith = smith };
    const source = fuzz_ink.Generator.generate(choices, &buffer, .{ .splices = true });
    _ = try check_source(source);
}

/// Parses `source` and checks the tree; whether it parsed.
fn check_source(source: []const u8) !bool {
    assert(source.len <= fuzz_ink.source_bytes_max);
    const gpa = std.testing.allocator;
    var parsed = grammar.parse(gpa, source, .{}) catch |err| switch (err) {
        error.ParseFailed, error.WorkspaceFull => return false,
        else => return err,
    };
    defer parsed.deinit(gpa);
    for (parsed.diagnostics()) |diagnostic| assert(diagnostic.offset <= parsed.source.len);
    check_tokens(&parsed);
    try check_tree(&parsed);
    return true;
}

fn check_tokens(parsed: *const grammar.Parsed) void {
    const workspace = &parsed.workspace;
    assert(parsed.tokens_count <= workspace.token_starts.len);
    for (0..parsed.tokens_count) |token| {
        const start = workspace.token_starts[token];
        const end = workspace.token_ends[token];
        // Not in order: a peek rewinds the input but keeps the tokens it read.
        assert(start <= end and end <= parsed.source.len);
    }
}

/// Walks the tree from the root with an explicit stack.
fn check_tree(parsed: *const grammar.Parsed) !void {
    const tree = &parsed.tree;
    assert(tree.tags.len == tree.data.len);
    assert(tree.tags.len <= nodes_max);
    const gpa = std.testing.allocator;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, tree.tags.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, tree.root);
    while (stack.pop()) |node| {
        assert(node.to_int() < tree.tags.len);
        assert(!seen.isSet(node.to_int()));
        seen.set(node.to_int());
        switch (ast_module.shape(tree.tag(node))) {
            .leaf => switch (tree.tag(node)) {
                // Slots hold a length, a depth and flags, or nothing.
                .none, .missing, .count, .header, .sequence_kind => {},
                // Markers hold the source offset they were made at.
                .newline, .tag_end, .empty_divert => {
                    assert(tree.data[node.to_int()] <= parsed.source.len);
                },
                else => assert(tree.data[node.to_int()] < parsed.tokens_count),
            },
            .fixed => |count| for (0..count) |position| {
                try stack.append(gpa, tree.child(node, @intCast(position)));
            },
            .list => {
                const items = tree.list(node);
                for (0..items.count) |position| try stack.append(gpa, tree.item(node, position));
            },
        }
    }
}

test "fuzz: the parser builds a well-formed tree or fails" {
    // Seeded sources first, with and without splices: most parse, and their trees check.
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var parsed: u32 = 0;
    for (0..32) |seed| {
        const splices = seed % 2 == 1;
        const source = fuzz_ink.generate_seeded(seed, &buffer, .{ .splices = splices });
        if (try check_source(source)) parsed += 1;
    }
    try std.testing.expect(parsed > 16);
    try std.testing.fuzz({}, parse, .{ .corpus = &.{""} });
}
