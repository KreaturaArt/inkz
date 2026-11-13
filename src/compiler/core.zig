//! The parser core (plan §4.11, P7.3, D9): an explicit-stack machine that runs backtracking
//! grammar rules the way ink's StringParser does, without recursion.
//!
//! A rule is a step function with phases. A step returns an `Action`: call another rule,
//! succeed, fail, or go on with its next phase. A call pushes a frame holding a checkpoint
//! (the input position and the token, node and scratch counts); a failed rule restores its
//! checkpoint, which gives StringParser's BeginRule/FailRule/SucceedRule and so OneOf,
//! Optional and Interleave. The caller reads the callee's outcome in its next phase.
//!
//! Nodes are built with zirp's scratch stack (T4): finished nodes are values on the scratch
//! stack, and `wrap` moves a parent's children into one contiguous run of the node arrays.
//! Diagnostics survive backtracking, as ink's errors do.
//!
//! Bounds: frames are limited by `parse_depth_max` (deeper input gets one diagnostic and the
//! parse unwinds, it doesn't crash); a gas counter bounds the steps by the input length, so a
//! grammar bug that stops making progress ends with a diagnostic too.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const Diagnostic = struct {
    code: Code,
    /// Byte offset in the (comment-free) source where it was raised.
    offset: u32,
    /// A code-specific number (such as the expected token tag).
    extra: u32 = 0,

    pub const Code = enum(u8) {
        too_deep,
        no_progress,
        /// `extra` is an Expectation of grammar.zig.
        expected,
        /// ink's other parse errors and warnings; `extra` is a grammar.zig Message.
        message,
        _,
    };
};

pub const Error = error{
    /// The workspace is too small for this source: retry with more (plan T15).
    WorkspaceFull,
};

/// Fixed-capacity arrays, sized once from the source length (T15).
pub const Workspace = struct {
    node_tags: []ast.Tag,
    node_data: []u32,
    scratch_tags: []ast.Tag,
    scratch_data: []u32,
    token_starts: []u32,
    token_ends: []u32,
    diagnostics: []Diagnostic,

    /// Capacities proportional to the source, from what ink stories use: about 0.17 nodes
    /// and 0.04 stored tokens per byte, and up to 0.43 nodes and 0.1 tokens in dense stories
    /// of short knots (the bench's generated story). A full workspace means a whole new
    /// parse, so the estimate covers dense stories (P12.2); `settle` gives back what wasn't
    /// used. `scale` doubles on each retry (plan T15).
    pub fn init(gpa: Allocator, source_length: u32, diagnostics_max: u32, scale: u32) !Workspace {
        assert(scale >= 1);
        const length: usize = source_length;
        const nodes: usize = (length / 2 + 256) * scale;
        const tokens: usize = (length / 6 + 256) * scale;
        var workspace: Workspace = undefined;
        workspace.node_tags = try gpa.alloc(ast.Tag, nodes);
        errdefer gpa.free(workspace.node_tags);
        workspace.node_data = try gpa.alloc(u32, nodes);
        errdefer gpa.free(workspace.node_data);
        workspace.scratch_tags = try gpa.alloc(ast.Tag, nodes);
        errdefer gpa.free(workspace.scratch_tags);
        workspace.scratch_data = try gpa.alloc(u32, nodes);
        errdefer gpa.free(workspace.scratch_data);
        workspace.token_starts = try gpa.alloc(u32, tokens);
        errdefer gpa.free(workspace.token_starts);
        workspace.token_ends = try gpa.alloc(u32, tokens);
        errdefer gpa.free(workspace.token_ends);
        workspace.diagnostics = try gpa.alloc(Diagnostic, diagnostics_max);
        assert(workspace.node_tags.len == nodes);
        return workspace;
    }

    /// After a parse: drops the scratch stack (only the parse uses it)
    /// and shrinks the node and token arrays to what was used (plan P8.6).
    pub fn settle(workspace: *Workspace, gpa: Allocator, nodes: u32, tokens: u32) !void {
        assert(nodes <= workspace.node_tags.len);
        assert(tokens <= workspace.token_starts.len);
        gpa.free(workspace.scratch_tags);
        gpa.free(workspace.scratch_data);
        workspace.scratch_tags = &.{};
        workspace.scratch_data = &.{};
        workspace.node_tags = try gpa.realloc(workspace.node_tags, nodes);
        workspace.node_data = try gpa.realloc(workspace.node_data, nodes);
        workspace.token_starts = try gpa.realloc(workspace.token_starts, tokens);
        workspace.token_ends = try gpa.realloc(workspace.token_ends, tokens);
    }

    /// Frees the nodes and the tokens, keeping the diagnostics.
    pub fn release_syntax(workspace: *Workspace, gpa: Allocator) void {
        assert(workspace.node_tags.len == workspace.node_data.len);
        assert(workspace.token_starts.len == workspace.token_ends.len);
        gpa.free(workspace.node_tags);
        gpa.free(workspace.node_data);
        gpa.free(workspace.token_starts);
        gpa.free(workspace.token_ends);
        workspace.node_tags = &.{};
        workspace.node_data = &.{};
        workspace.token_starts = &.{};
        workspace.token_ends = &.{};
    }

    pub fn deinit(workspace: *Workspace, gpa: Allocator) void {
        assert(workspace.diagnostics.len > 0);
        assert(workspace.node_tags.len == workspace.node_data.len);
        gpa.free(workspace.node_tags);
        gpa.free(workspace.node_data);
        gpa.free(workspace.scratch_tags);
        gpa.free(workspace.scratch_data);
        gpa.free(workspace.token_starts);
        gpa.free(workspace.token_ends);
        gpa.free(workspace.diagnostics);
        workspace.* = undefined;
    }
};

/// What a rule step does next.
pub fn Action(comptime Rule: type) type {
    comptime assert(@typeInfo(Rule) == .@"enum");
    comptime assert(@sizeOf(Rule) <= 4);
    return union(enum) {
        /// Run `rule`, then come back to this frame's next phase.
        call: Rule,
        /// Run `rule` and come back, but undo what it consumed even if it matched (ink's
        /// Peek).
        peek: Rule,
        /// This rule matched; its nodes are on the scratch stack.
        succeed,
        /// This rule didn't match: everything since its call is undone.
        fail,
        /// Run this frame again (its phase changed).
        again,
    };
}

pub const Outcome = enum { none, succeeded, failed };

/// The machine for a grammar, which provides `Rule` (an enum) and
/// `step(machine: *Machine(Grammar), frame: *Frame(Rule)) Action(Rule)`.
pub fn Machine(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        pub const Rule = Grammar.Rule;

        pub const Frame = struct {
            rule: Rule,
            phase: u8 = 0,
            /// Undo the rule's input even when it succeeds.
            peek: bool = false,
            checkpoint: Checkpoint,
            /// Rule-specific scratch: counts, saved positions.
            locals: [3]u32 = .{ 0, 0, 0 },
        };

        pub const Checkpoint = struct {
            at: u32,
            tokens: u32,
            nodes: u32,
            scratch: u32,
            /// The flags restored on failure (ink keeps its custom flags in the parser state).
            flags: u32,
        };

        source: []const u8,
        /// The input position.
        at: u32 = 0,
        workspace: *Workspace,
        frames: []Frame,
        frames_count: u32 = 0,
        nodes_count: u32 = 0,
        scratch_count: u32 = 0,
        tokens_count: u32 = 0,
        diagnostics_count: u32 = 0,
        /// The outcome of the frame that just returned.
        outcome: Outcome = .none,
        /// Set when the input is too deep or stopped progressing: every frame fails.
        abandoned: bool = false,
        /// Set when the workspace ran out: the parse must be retried with more room.
        workspace_full: bool = false,
        /// Grammar flags that backtracking restores (ink's ParsingString and TagActive).
        flags: u32 = 0,
        /// Grammar flags that backtracking keeps (ink's _parsingChoice field).
        plain_flags: u32 = 0,
        /// A value the caller passes to the rule it calls (ink's rule parameters, such as a
        /// statement level), read in the callee's first phase.
        argument: u32 = 0,
        /// A value a rule returns besides its nodes (such as whether a knot is a function).
        result: u32 = 0,

        pub fn init(source: []const u8, workspace: *Workspace, frames: []Frame) Self {
            assert(frames.len > 0);
            assert(source.len < std.math.maxInt(u32));
            return .{
                .source = source,
                .workspace = workspace,
                .frames = frames,
            };
        }

        pub fn checkpoint(machine: *const Self) Checkpoint {
            assert(machine.at <= machine.source.len);
            assert(machine.nodes_count <= machine.workspace.node_tags.len);
            return .{
                .at = machine.at,
                .tokens = machine.tokens_count,
                .nodes = machine.nodes_count,
                .scratch = machine.scratch_count,
                .flags = machine.flags,
            };
        }

        pub fn restore(machine: *Self, saved: Checkpoint) void {
            assert(saved.at <= machine.source.len);
            assert(saved.tokens <= machine.workspace.token_starts.len);
            machine.at = saved.at;
            machine.tokens_count = saved.tokens;
            machine.nodes_count = saved.nodes;
            machine.scratch_count = saved.scratch;
            machine.flags = saved.flags;
        }

        /// Runs `start` to the end; returns its outcome.
        pub fn run(machine: *Self, start: Rule) Error!Outcome {
            assert(machine.frames_count == 0);
            const gas_max: u64 = 64 * (@as(u64, machine.source.len) + 64);
            var gas: u64 = 0;
            try machine.push(start);
            while (machine.frames_count > 0) : (gas += 1) {
                if (gas == gas_max) {
                    machine.report(.no_progress, machine.at, 0);
                    machine.abandoned = true;
                }
                const frame = &machine.frames[machine.frames_count - 1];
                const action = if (machine.abandoned) Action(Rule).fail else Grammar.step(
                    machine,
                    frame,
                );
                try machine.apply(action);
            }
            assert(machine.outcome != .none);
            return machine.outcome;
        }

        fn apply(machine: *Self, action: Action(Rule)) Error!void {
            assert(machine.at <= machine.source.len);
            assert(machine.frames_count > 0);
            switch (action) {
                .call => |rule| {
                    machine.outcome = .none;
                    try machine.push(rule);
                },
                .peek => |rule| {
                    machine.outcome = .none;
                    try machine.push(rule);
                    const callee = &machine.frames[machine.frames_count - 1];
                    if (machine.outcome == .none) callee.peek = true;
                },
                .succeed => {
                    const frame = machine.frames[machine.frames_count - 1];
                    if (frame.peek) machine.restore(frame.checkpoint);
                    machine.frames_count -= 1;
                    machine.outcome = .succeeded;
                },
                .fail => {
                    machine.restore(machine.frames[machine.frames_count - 1].checkpoint);
                    machine.frames_count -= 1;
                    machine.outcome = .failed;
                },
                .again => {},
            }
        }

        fn push(machine: *Self, rule: Rule) Error!void {
            assert(machine.at <= machine.source.len);
            assert(machine.frames_count <= machine.frames.len);
            if (machine.frames_count == machine.frames.len) {
                // Too deep: one diagnostic, then everything unwinds.
                if (!machine.abandoned) machine.report(.too_deep, machine.at, 0);
                machine.abandoned = true;
                machine.outcome = .failed;
                return;
            }
            const saved = machine.checkpoint();
            machine.frames[machine.frames_count] = .{ .rule = rule, .checkpoint = saved };
            machine.frames_count += 1;
        }

        pub fn report(machine: *Self, code: Diagnostic.Code, offset: u32, extra: u32) void {
            assert(machine.diagnostics_count <= machine.workspace.diagnostics.len);
            assert(offset <= machine.source.len);
            if (machine.diagnostics_count == machine.workspace.diagnostics.len) return;
            const diagnostic: Diagnostic = .{ .code = code, .offset = offset, .extra = extra };
            machine.workspace.diagnostics[machine.diagnostics_count] = diagnostic;
            machine.diagnostics_count += 1;
        }

        // Tokens.

        /// Stores a token for a range the grammar scanned itself (character-level rules).
        pub fn add_token(machine: *Self, start: u32, end: u32) Error!ast.TokenIndex {
            assert(start <= end and end <= machine.source.len);
            const workspace = machine.workspace;
            if (machine.tokens_count == workspace.token_starts.len) return error.WorkspaceFull;
            workspace.token_starts[machine.tokens_count] = start;
            workspace.token_ends[machine.tokens_count] = end;
            machine.tokens_count += 1;
            return .from_int(machine.tokens_count - 1);
        }

        // Nodes.

        /// Pushes a finished node value on the scratch stack.
        pub fn push_node(machine: *Self, tag: ast.Tag, data: u32) Error!void {
            assert(machine.scratch_count <= machine.workspace.scratch_tags.len);
            assert(@backingInt(tag) < 256);
            const workspace = machine.workspace;
            if (machine.scratch_count == workspace.scratch_tags.len) return error.WorkspaceFull;
            workspace.scratch_tags[machine.scratch_count] = tag;
            workspace.scratch_data[machine.scratch_count] = data;
            machine.scratch_count += 1;
        }

        /// zirp's wrap: the values above `marker` become `tag`'s children, in one contiguous
        /// run of the node arrays (a list gets its count node first), and `tag` is pushed.
        pub fn wrap(machine: *Self, tag: ast.Tag, marker: u32) Error!void {
            assert(marker <= machine.scratch_count);
            const workspace = machine.workspace;
            const count = machine.scratch_count - marker;
            const is_list = ast.shape(tag) == .list;
            const total = count + @intFromBool(is_list);
            if (machine.nodes_count + total > workspace.node_tags.len) return error.WorkspaceFull;
            const first = machine.nodes_count;
            if (is_list) {
                workspace.node_tags[first] = .count;
                workspace.node_data[first] = count;
            }
            const into = first + @intFromBool(is_list);
            @memcpy(
                workspace.node_tags[into..][0..count],
                workspace.scratch_tags[marker..][0..count],
            );
            @memcpy(
                workspace.node_data[into..][0..count],
                workspace.scratch_data[marker..][0..count],
            );
            machine.nodes_count += total;
            machine.scratch_count = marker;
            if (ast.shape(tag) == .fixed) assert(count == ast.shape(tag).fixed);
            try machine.push_node(tag, first);
        }

        /// Starts the next region of a shared source space (plan §4.11): `source` ends where
        /// the region ends, and parsing starts at `start`. Tokens, nodes and diagnostics
        /// accumulate across regions, so their indices are global.
        pub fn begin_region(machine: *Self, source: []const u8, start: u32) void {
            assert(machine.frames_count == 0 and machine.scratch_count == 0);
            assert(start <= source.len);
            machine.source = source;
            machine.at = start;
            machine.outcome = .none;
            machine.flags = 0;
            machine.plain_flags = 0;
        }

        /// Moves a region's finished tree (the one scratch value) into the node arrays.
        pub fn commit_root(machine: *Self) Error!ast.NodeIndex {
            assert(machine.frames_count == 0);
            assert(machine.scratch_count == 1);
            const workspace = machine.workspace;
            if (machine.nodes_count == workspace.node_tags.len) return error.WorkspaceFull;
            const root = machine.nodes_count;
            workspace.node_tags[root] = workspace.scratch_tags[0];
            workspace.node_data[root] = workspace.scratch_data[0];
            machine.nodes_count += 1;
            machine.scratch_count = 0;
            return .from_int(root);
        }

        /// The tree of all committed regions, rooted at `root`.
        pub fn finish_regions(machine: *const Self, root: ast.NodeIndex) ast.Ast {
            assert(machine.scratch_count == 0);
            assert(root.to_int() < machine.nodes_count);
            const workspace = machine.workspace;
            return .{
                .tags = workspace.node_tags[0..machine.nodes_count],
                .data = workspace.node_data[0..machine.nodes_count],
                .root = root,
            };
        }
    };
}

/// A toy grammar for the core's tests: `expression = term (' + ' term)*`,
/// `term = letter | '(' expression ')'`.
const Toy = struct {
    pub const Rule = enum { expression, term, stall };
    const M = Machine(Toy);

    pub fn step(machine: *M, frame: *M.Frame) Action(Rule) {
        assert(machine.frames_count > 0);
        return switch (frame.rule) {
            .expression => expression(machine, frame),
            .term => term(machine, frame),
            // A broken rule that never makes progress.
            .stall => .again,
        } catch return .fail;
    }

    fn accept(machine: *M, text: []const u8) bool {
        if (!std.mem.startsWith(u8, machine.source[machine.at..], text)) return false;
        machine.at += @intCast(text.len);
        return true;
    }

    fn expression(machine: *M, frame: *M.Frame) Error!Action(Rule) {
        switch (frame.phase) {
            0 => {
                frame.locals[0] = machine.scratch_count;
                frame.phase = 1;
                return .{ .call = .term };
            },
            1 => {
                if (machine.outcome == .failed) return .fail;
                if (!accept(machine, " + ")) {
                    frame.phase = 2;
                    return .again;
                }
                return .{ .call = .term };
            },
            else => {
                try machine.wrap(.path, frame.locals[0]);
                return .succeed;
            },
        }
    }

    fn term(machine: *M, frame: *M.Frame) Error!Action(Rule) {
        switch (frame.phase) {
            0 => {
                const rest = machine.source[machine.at..];
                if (rest.len > 0 and std.ascii.isAlphabetic(rest[0])) {
                    const token = try machine.add_token(machine.at, machine.at + 1);
                    machine.at += 1;
                    try machine.push_node(.identifier, token.to_int());
                    return .succeed;
                }
                if (!accept(machine, "(")) return .fail;
                frame.phase = 1;
                return .{ .call = .expression };
            },
            else => {
                if (machine.outcome == .failed) return .fail;
                if (!accept(machine, ")")) {
                    machine.report(.expected, machine.at, ')');
                    return .fail;
                }
                return .succeed;
            },
        }
    }
};

const ToyResult = struct {
    outcome: Outcome,
    diagnostics: u32,
    first: ?Diagnostic.Code,
    nodes: u32,
};

fn parse_toy(source: []const u8, depth_max: u32, start: Toy.Rule) !ToyResult {
    assert(source.len > 0);
    assert(depth_max > 0);
    const gpa = std.testing.allocator;
    var workspace = try Workspace.init(gpa, @intCast(source.len), 16, 1);
    defer workspace.deinit(gpa);
    const frames = try gpa.alloc(Toy.M.Frame, depth_max);
    defer gpa.free(frames);
    var machine: Toy.M = .init(source, &workspace, frames);
    const outcome = try machine.run(start);
    const first = if (machine.diagnostics_count > 0) workspace.diagnostics[0].code else null;
    return .{
        .outcome = outcome,
        .diagnostics = machine.diagnostics_count,
        .first = first,
        .nodes = machine.nodes_count,
    };
}

test "the core runs nested rules without recursion" {
    // Goal: P7.3. Method: a toy grammar with parentheses; the result keeps its shape.
    const result = try parse_toy("a + (b + (c)) + d", 64, .expression);
    try std.testing.expectEqual(Outcome.succeeded, result.outcome);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);
    try std.testing.expect(result.nodes > 4);
}

test "10k-deep nesting yields a diagnostic, not a crash" {
    // Goal: P7.3 bound. Method: 10,000 opening parentheses with parse_depth_max 256.
    var source: [20_001]u8 = undefined;
    @memset(source[0..10_000], '(');
    source[10_000] = 'x';
    @memset(source[10_001..], ')');
    const result = try parse_toy(&source, 256, .expression);
    try std.testing.expectEqual(Outcome.failed, result.outcome);
    try std.testing.expectEqual(Diagnostic.Code.too_deep, result.first.?);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
}

test "a failed rule undoes everything since its call" {
    // Goal: P7.3 backtracking. Method: an unclosed parenthesis fails the term, leaving the
    // expression's earlier terms as they were, and records one diagnostic.
    const result = try parse_toy("(a + b", 64, .expression);
    try std.testing.expectEqual(Outcome.failed, result.outcome);
    try std.testing.expectEqual(Diagnostic.Code.expected, result.first.?);
    try std.testing.expectEqual(@as(u32, 0), result.nodes);
}

test "a rule that stops making progress runs out of gas" {
    // Goal: P7.3 progress invariant: steps are bounded by the input length. Method: a rule
    // that repeats forever ends with a no_progress diagnostic.
    const result = try parse_toy("anything", 8, .stall);
    try std.testing.expectEqual(Outcome.failed, result.outcome);
    try std.testing.expectEqual(Diagnostic.Code.no_progress, result.first.?);
}
