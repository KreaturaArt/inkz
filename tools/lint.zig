//! TigerStyle lint for inkz (plan §3, P0.8), run with `zig build lint`.
//!
//! Rules: function length, line length, recursion (a name-based call graph), `usize` struct
//! fields, snake_case file names and assertion density (`assert` and `verify` calls). Old
//! code listed in `grandfathered` is skipped until it is deleted (plan P9).
//!
//! Suppressions are comments that must give a reason:
//! - `// lint: allow function_length: <reason>` or `// lint: allow recursion: <reason>` in the
//!   comment block directly above a function.
//! - `// lint: allow assertion_density: <reason>` anywhere in a file.
//!
//! The recursion check resolves calls by name: `f()` and `x.f()` match functions named `f` in
//! the same file, and `alias.f()` matches `f` in the file imported as `alias`. Calls through a
//! field chain (`a.b.f()`), a call result, or an alias of `std` or `builtin` go to other types
//! and are skipped. It cannot see types, so it over-approximates within a file; a false
//! positive needs a suppression.

const std = @import("std");
const assert = std.debug.assert;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const function_lines_max = 70;
pub const line_columns_max = 100;
pub const assertions_per_function_min = 2;
pub const file_bytes_max = 16 * 1024 * 1024;
pub const files_max = 4096;

/// Old code that predates the rules. Remove entries as the code is deleted (P9.1, P9.2).
pub const grandfathered = [_][]const u8{
    "src/runtime/",
    "src/compiler/",
    "src/test/",
    "src/ink_format.zig",
    "src/root.zig",
    "src/test_runtime.zig",
    "src/test_compiler.zig",
};

pub const Rule = enum {
    syntax,
    file_name,
    line_length,
    function_length,
    usize_field,
    assertion_density,
    recursion,
};

pub const Diagnostic = struct {
    path: []const u8,
    line: u32,
    rule: Rule,
    message: []const u8,
};

const Function = struct {
    file: u32,
    name: []const u8,
    token_first: Ast.TokenIndex,
    token_last: Ast.TokenIndex,
    line: u32,
    allow_recursion: bool,
    /// Returns `type`, like `fn BoundedStack(T) type { return struct { ... } }`. Its body is a
    /// type definition whose methods are checked one by one, so it is exempt from the length
    /// and density rules.
    returns_type: bool,
};

const Import = struct {
    alias: []const u8,
    path: []const u8,
};

const Call = struct {
    caller: u32,
    callee_name: []const u8,
    /// The file named by an import alias, or null for the caller's own file.
    target_path: ?[]const u8,
};

const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tree: Ast,
    line_starts: []const u32,
    functions_first: u32,
    functions_count: u32,
    imports: std.ArrayList(Import),
    /// Names bound to `std`, `builtin` or something inside them, such as `const mem = std.mem`.
    external_aliases: std.ArrayList([]const u8),
};

pub fn is_grandfathered(path: []const u8) bool {
    assert(path.len > 0);
    for (grandfathered) |prefix| {
        assert(prefix.len > 0);
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// Collects files, then reports every rule violation in `finish`. All memory comes from
/// `arena`, which the caller frees.
pub const Linter = struct {
    arena: Allocator,
    files: std.ArrayList(SourceFile) = .empty,
    functions: std.ArrayList(Function) = .empty,
    calls: std.ArrayList(Call) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(arena: Allocator) Linter {
        const linter: Linter = .{ .arena = arena };
        assert(linter.files.items.len == 0);
        assert(linter.diagnostics.items.len == 0);
        return linter;
    }

    pub fn add_file(linter: *Linter, path: []const u8, source: [:0]const u8) !void {
        assert(path.len > 0);
        assert(linter.files.items.len < files_max);
        try linter.check_file_name(path);
        const tree = try Ast.parse(linter.arena, source, .{ .mode = .zig });
        if (tree.errors.len > 0) {
            const line = tree.tokenLocation(0, tree.errors[0].token).line + 1;
            try linter.report(path, @intCast(line), .syntax, "file does not parse");
            return;
        }
        const line_starts = try compute_line_starts(linter.arena, source);
        try linter.files.append(linter.arena, .{
            .path = path,
            .source = source,
            .tree = tree,
            .line_starts = line_starts,
            .functions_first = @intCast(linter.functions.items.len),
            .functions_count = 0,
            .imports = .empty,
            .external_aliases = .empty,
        });
        const file_index: u32 = @intCast(linter.files.items.len - 1);
        try linter.check_lines(file_index);
        try linter.scan_declarations(file_index);
        try linter.scan_calls(file_index);
    }

    /// Resolves the call graph, reports cycles and returns all diagnostics sorted by place.
    pub fn finish(linter: *Linter) ![]const Diagnostic {
        assert(linter.functions.items.len <= std.math.maxInt(u32));
        try linter.check_recursion();
        const items = linter.diagnostics.items;
        std.mem.sort(Diagnostic, items, {}, diagnostic_less_than);
        if (items.len > 1) assert(!diagnostic_less_than({}, items[1], items[0]));
        return items;
    }

    fn report(
        linter: *Linter,
        path: []const u8,
        line: u32,
        rule: Rule,
        message: []const u8,
    ) !void {
        assert(path.len > 0);
        assert(line > 0);
        try linter.diagnostics.append(linter.arena, .{
            .path = path,
            .line = line,
            .rule = rule,
            .message = message,
        });
    }

    fn check_file_name(linter: *Linter, path: []const u8) !void {
        assert(path.len > 0);
        const name = std.fs.path.basename(path);
        assert(name.len > 0);
        if (!is_snake_case_file_name(name)) {
            try linter.report(path, 1, .file_name, "file name must be snake_case and end in .zig");
        }
    }

    fn check_lines(linter: *Linter, file_index: u32) !void {
        const file = &linter.files.items[file_index];
        assert(file.line_starts.len > 0);
        for (file.line_starts, 0..) |start, line_index| {
            const end = line_end(file.source, start);
            assert(end >= start);
            const columns = std.unicode.utf8CountCodepoints(file.source[start..end]) catch
                end - start;
            if (columns > line_columns_max) {
                const message = try std.fmt.allocPrint(
                    linter.arena,
                    "line is {d} columns, the limit is {d}",
                    .{ columns, line_columns_max },
                );
                try linter.report(file.path, @intCast(line_index + 1), .line_length, message);
            }
        }
    }

    /// One pass over every node: functions, `usize` fields and top-level imports.
    fn scan_declarations(linter: *Linter, file_index: u32) !void {
        const tree = &linter.files.items[file_index].tree;
        assert(tree.errors.len == 0);
        const nodes_count: u32 = @intCast(tree.nodes.len);
        var node_raw: u32 = 1;
        while (node_raw < nodes_count) : (node_raw += 1) {
            const node: Ast.Node.Index = @enumFromInt(node_raw);
            switch (tree.nodeTag(node)) {
                .fn_decl => try linter.add_function(file_index, node),
                .container_field_init,
                .container_field_align,
                .container_field,
                => try linter.check_field(file_index, node),
                .simple_var_decl => try linter.add_import(file_index, node),
                else => {},
            }
        }
        const file = &linter.files.items[file_index];
        file.functions_count = @as(u32, @intCast(linter.functions.items.len)) -
            file.functions_first;
        assert(file.functions_first + file.functions_count == linter.functions.items.len);
    }

    fn add_function(linter: *Linter, file_index: u32, node: Ast.Node.Index) !void {
        const file = &linter.files.items[file_index];
        assert(file.tree.nodeTag(node) == .fn_decl);
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = file.tree.fullFnProto(&buffer, node).?;
        const name_token = prototype.name_token orelse return;
        const token_first = file.tree.firstToken(node);
        const token_last = file.tree.lastToken(node);
        assert(token_first <= token_last);
        const line_first = token_line(&file.tree, token_first);
        const line_last = token_line(&file.tree, token_last);
        const name = file.tree.tokenSlice(name_token);
        const lines_count = line_last - line_first + 1;
        const returns_type = is_type_expression(&file.tree, prototype.ast.return_type);
        if (lines_count > function_lines_max and !returns_type and
            !comment_block_has(file, line_first, "lint: allow function_length:"))
        {
            const message = try std.fmt.allocPrint(
                linter.arena,
                "function '{s}' is {d} lines, the limit is {d}",
                .{ name, lines_count, function_lines_max },
            );
            try linter.report(file.path, line_first, .function_length, message);
        }
        try linter.functions.append(linter.arena, .{
            .file = file_index,
            .name = name,
            .token_first = token_first,
            .token_last = token_last,
            .line = line_first,
            .allow_recursion = comment_block_has(file, line_first, "lint: allow recursion:"),
            .returns_type = returns_type,
        });
    }

    fn check_field(linter: *Linter, file_index: u32, node: Ast.Node.Index) !void {
        const file = &linter.files.items[file_index];
        const field = file.tree.fullContainerField(node).?;
        assert(field.ast.main_token < file.tree.tokens.len);
        const type_node = field.ast.type_expr.unwrap() orelse return;
        const token_first = file.tree.firstToken(type_node);
        const token_last = file.tree.lastToken(type_node);
        assert(token_first <= token_last);
        var token = token_first;
        while (token <= token_last) : (token += 1) {
            if (file.tree.tokenTag(token) != .identifier) continue;
            if (!std.mem.eql(u8, file.tree.tokenSlice(token), "usize")) continue;
            const line = token_line(&file.tree, token);
            try linter.report(file.path, line, .usize_field, "struct field uses usize; use u32");
            return;
        }
    }

    /// Records `const alias = @import("file.zig");`, and aliases of `std` or `builtin`.
    fn add_import(linter: *Linter, file_index: u32, node: Ast.Node.Index) !void {
        const file = &linter.files.items[file_index];
        const declaration = file.tree.fullVarDecl(node).?;
        assert(declaration.ast.mut_token < file.tree.tokens.len);
        const initializer = declaration.ast.init_node.unwrap() orelse return;
        const alias = file.tree.tokenSlice(declaration.ast.mut_token + 1);
        const first = file.tree.tokenSlice(file.tree.firstToken(initializer));
        if (std.mem.eql(u8, first, "std") or std.mem.eql(u8, first, "builtin")) {
            try file.external_aliases.append(linter.arena, alias);
            return;
        }
        const relative = import_argument(&file.tree, initializer) orelse return;
        if (!std.mem.endsWith(u8, relative, ".zig")) {
            try file.external_aliases.append(linter.arena, alias);
            return;
        }
        const directory = std.fs.path.dirname(file.path) orelse "";
        const path = try join_normalized(linter.arena, directory, relative);
        assert(path.len > 0);
        try file.imports.append(linter.arena, .{ .alias = alias, .path = path });
    }

    /// Records calls for the call graph and counts assertions per function.
    fn scan_calls(linter: *Linter, file_index: u32) !void {
        const file = &linter.files.items[file_index];
        assert(file.tree.errors.len == 0);
        var assertions_count: u32 = 0;
        const nodes_count: u32 = @intCast(file.tree.nodes.len);
        var node_raw: u32 = 1;
        while (node_raw < nodes_count) : (node_raw += 1) {
            const node: Ast.Node.Index = @enumFromInt(node_raw);
            var buffer: [1]Ast.Node.Index = undefined;
            const call = file.tree.fullCall(&buffer, node) orelse continue;
            const caller = linter.enclosing_function(file_index, call.ast.lparen) orelse continue;
            const callee = callee_of(file, call.ast.fn_expr) orelse continue;
            if (is_assertion(callee.name)) assertions_count += 1;
            if (callee.target == .external) continue;
            try linter.calls.append(linter.arena, .{
                .caller = caller,
                .callee_name = callee.name,
                .target_path = switch (callee.target) {
                    .same_file => null,
                    .imported => |path| path,
                    .external => unreachable,
                },
            });
        }
        try linter.check_assertion_density(file_index, assertions_count);
    }

    fn check_assertion_density(linter: *Linter, file_index: u32, assertions_count: u32) !void {
        const file = &linter.files.items[file_index];
        assert(file.functions_first <= linter.functions.items.len);
        var functions_count: u32 = 0;
        const functions = linter.functions.items[file.functions_first..][0..file.functions_count];
        for (functions) |function| functions_count += @intFromBool(!function.returns_type);
        if (functions_count == 0) return;
        const required = functions_count * assertions_per_function_min;
        if (assertions_count >= required) return;
        if (std.mem.indexOf(u8, file.source, "lint: allow assertion_density:") != null) return;
        const message = try std.fmt.allocPrint(
            linter.arena,
            "{d} assertions in {d} functions; at least {d} per function on average",
            .{ assertions_count, functions_count, assertions_per_function_min },
        );
        assert(required > assertions_count);
        try linter.report(file.path, 1, .assertion_density, message);
    }

    /// The innermost function of `file_index` whose tokens contain `token`.
    fn enclosing_function(linter: *const Linter, file_index: u32, token: Ast.TokenIndex) ?u32 {
        const file = &linter.files.items[file_index];
        const functions = linter.functions.items[file.functions_first..][0..file.functions_count];
        var found: ?u32 = null;
        for (functions, file.functions_first..) |function, index| {
            assert(function.file == file_index);
            if (token < function.token_first or token > function.token_last) continue;
            if (found) |previous| {
                if (function.token_first < linter.functions.items[previous].token_first) continue;
            }
            found = @intCast(index);
        }
        return found;
    }

    fn check_recursion(linter: *Linter) !void {
        const graph = try linter.build_graph();
        const components = try strongly_connected_components(linter.arena, graph);
        assert(components.len == linter.functions.items.len);
        const members = try group_components(linter.arena, components);
        for (members.first, 0..) |first, component| {
            const count = members.first_next[component] - first;
            const nodes = members.nodes[first..][0..count];
            assert(nodes.len > 0);
            if (nodes.len == 1 and !graph.has_edge(nodes[0], nodes[0])) continue;
            try linter.report_cycle(nodes);
        }
    }

    fn report_cycle(linter: *Linter, nodes: []const u32) !void {
        assert(nodes.len > 0);
        for (nodes) |node| {
            if (linter.functions.items[node].allow_recursion) return;
        }
        var names: std.ArrayList(u8) = .empty;
        for (nodes, 0..) |node, index| {
            if (index > 0) try names.appendSlice(linter.arena, ", ");
            try names.appendSlice(linter.arena, linter.functions.items[node].name);
        }
        const function = linter.functions.items[nodes[0]];
        const path = linter.files.items[function.file].path;
        const message = try std.fmt.allocPrint(
            linter.arena,
            "functions call themselves: {s}",
            .{names.items},
        );
        assert(message.len > 0);
        try linter.report(path, function.line, .recursion, message);
    }

    /// Builds a compressed adjacency list from the recorded calls.
    fn build_graph(linter: *Linter) !Graph {
        const nodes_count: u32 = @intCast(linter.functions.items.len);
        var edges: std.ArrayList(Edge) = .empty;
        for (linter.calls.items) |call| {
            assert(call.caller < nodes_count);
            const caller_file = linter.functions.items[call.caller].file;
            const target_file = if (call.target_path) |path|
                linter.file_by_path(path) orelse continue
            else
                caller_file;
            const file = &linter.files.items[target_file];
            const first = file.functions_first;
            const functions = linter.functions.items[first..][0..file.functions_count];
            for (functions, first..) |function, callee| {
                if (!std.mem.eql(u8, function.name, call.callee_name)) continue;
                try edges.append(linter.arena, .{ .from = call.caller, .to = @intCast(callee) });
            }
        }
        const graph = try Graph.from_edges(linter.arena, nodes_count, edges.items);
        assert(graph.edge_first.len == nodes_count + 1);
        return graph;
    }

    fn file_by_path(linter: *const Linter, path: []const u8) ?u32 {
        assert(path.len > 0);
        for (linter.files.items, 0..) |file, index| {
            assert(file.path.len > 0);
            if (std.mem.eql(u8, file.path, path)) return @intCast(index);
        }
        return null;
    }
};

const Callee = struct {
    name: []const u8,
    target: union(enum) {
        same_file,
        imported: []const u8,
        external,
    },
};

/// The name a call resolves to, and where to look for it.
fn callee_of(file: *const SourceFile, expression: Ast.Node.Index) ?Callee {
    const tree = &file.tree;
    assert(tree.errors.len == 0);
    switch (tree.nodeTag(expression)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(expression));
            return .{ .name = name, .target = .same_file };
        },
        .field_access => {
            const data = tree.nodeData(expression).node_and_token;
            const name = tree.tokenSlice(data[1]);
            assert(name.len > 0);
            if (tree.nodeTag(data[0]) != .identifier) return .{ .name = name, .target = .external };
            const receiver = tree.tokenSlice(tree.nodeMainToken(data[0]));
            for (file.imports.items) |import| {
                if (std.mem.eql(u8, import.alias, receiver)) {
                    return .{ .name = name, .target = .{ .imported = import.path } };
                }
            }
            for (file.external_aliases.items) |alias| {
                if (std.mem.eql(u8, alias, receiver)) return .{ .name = name, .target = .external };
            }
            return .{ .name = name, .target = .same_file };
        },
        else => return null,
    }
}

fn is_type_expression(tree: *const Ast, node: Ast.Node.OptionalIndex) bool {
    const expression = node.unwrap() orelse return false;
    assert(tree.errors.len == 0);
    if (tree.nodeTag(expression) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(expression));
    assert(name.len > 0);
    return std.mem.eql(u8, name, "type");
}

/// The string argument of `@import("...")`, without quotes.
fn import_argument(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    const argument = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(argument) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(argument));
    assert(literal.len >= 2);
    assert(literal[0] == '"');
    return literal[1 .. literal.len - 1];
}

const Edge = struct {
    from: u32,
    to: u32,
};

/// Compressed adjacency: the targets of node `n` are `targets[edge_first[n]..edge_first[n + 1]]`.
const Graph = struct {
    edge_first: []u32,
    targets: []u32,

    fn from_edges(arena: Allocator, nodes_count: u32, edges: []const Edge) !Graph {
        const edge_first = try arena.alloc(u32, nodes_count + 1);
        @memset(edge_first, 0);
        for (edges) |edge| {
            assert(edge.from < nodes_count);
            assert(edge.to < nodes_count);
            edge_first[edge.from + 1] += 1;
        }
        for (1..edge_first.len) |index| edge_first[index] += edge_first[index - 1];
        const targets = try arena.alloc(u32, edges.len);
        const cursor = try arena.dupe(u32, edge_first[0..nodes_count]);
        for (edges) |edge| {
            targets[cursor[edge.from]] = edge.to;
            cursor[edge.from] += 1;
        }
        assert(edge_first[nodes_count] == edges.len);
        return .{ .edge_first = edge_first, .targets = targets };
    }

    fn successors(graph: Graph, node: u32) []const u32 {
        assert(node + 1 < graph.edge_first.len);
        const first = graph.edge_first[node];
        const last = graph.edge_first[node + 1];
        assert(first <= last);
        return graph.targets[first..last];
    }

    fn has_edge(graph: Graph, from: u32, to: u32) bool {
        assert(to + 1 < graph.edge_first.len);
        for (graph.successors(from)) |target| {
            if (target == to) return true;
        }
        return false;
    }
};

const unvisited = std.math.maxInt(u32);

const Frame = struct {
    node: u32,
    edge: u32,
};

const Tarjan = struct {
    graph: Graph,
    index: []u32,
    low: []u32,
    on_stack: []bool,
    component: []u32,
    stack: std.ArrayList(u32) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    index_next: u32 = 0,
    component_next: u32 = 0,

    fn visit(tarjan: *Tarjan, arena: Allocator, node: u32) !void {
        assert(tarjan.index[node] == unvisited);
        tarjan.index[node] = tarjan.index_next;
        tarjan.low[node] = tarjan.index_next;
        tarjan.index_next += 1;
        tarjan.on_stack[node] = true;
        try tarjan.stack.append(arena, node);
        try tarjan.frames.append(arena, .{ .node = node, .edge = tarjan.graph.edge_first[node] });
        assert(tarjan.frames.items.len <= tarjan.index.len);
    }

    /// Pops a finished frame, propagates its low link and emits its component if it is a root.
    fn leave(tarjan: *Tarjan) void {
        const node = tarjan.frames.pop().?.node;
        assert(tarjan.on_stack[node]);
        if (tarjan.frames.items.len > 0) {
            const parent = tarjan.frames.items[tarjan.frames.items.len - 1].node;
            tarjan.low[parent] = @min(tarjan.low[parent], tarjan.low[node]);
        }
        if (tarjan.low[node] != tarjan.index[node]) return;
        while (true) {
            const member = tarjan.stack.pop().?;
            tarjan.on_stack[member] = false;
            tarjan.component[member] = tarjan.component_next;
            if (member == node) break;
        }
        tarjan.component_next += 1;
        assert(tarjan.component_next <= tarjan.index_next);
    }
};

/// Tarjan's algorithm with an explicit frame stack (no recursion). Returns a component id per
/// node; ids are dense, starting at 0.
fn strongly_connected_components(arena: Allocator, graph: Graph) ![]u32 {
    const nodes_count: u32 = @intCast(graph.edge_first.len - 1);
    var tarjan: Tarjan = .{
        .graph = graph,
        .index = try arena.alloc(u32, nodes_count),
        .low = try arena.alloc(u32, nodes_count),
        .on_stack = try arena.alloc(bool, nodes_count),
        .component = try arena.alloc(u32, nodes_count),
    };
    @memset(tarjan.index, unvisited);
    @memset(tarjan.on_stack, false);
    const steps_max = nodes_count + graph.targets.len;
    var steps: u64 = 0;
    for (0..nodes_count) |root| {
        if (tarjan.index[root] != unvisited) continue;
        try tarjan.visit(arena, @intCast(root));
        while (tarjan.frames.items.len > 0) : (steps += 1) {
            assert(steps <= 2 * steps_max);
            const frame = &tarjan.frames.items[tarjan.frames.items.len - 1];
            if (frame.edge == graph.edge_first[frame.node + 1]) {
                tarjan.leave();
                continue;
            }
            const target = graph.targets[frame.edge];
            frame.edge += 1;
            if (tarjan.index[target] == unvisited) {
                try tarjan.visit(arena, target);
            } else if (tarjan.on_stack[target]) {
                tarjan.low[frame.node] = @min(tarjan.low[frame.node], tarjan.index[target]);
            }
        }
    }
    assert(tarjan.stack.items.len == 0);
    return tarjan.component;
}

const ComponentMembers = struct {
    /// `nodes[first[c]..first_next[c]]` are the members of component `c`.
    first: []u32,
    first_next: []u32,
    nodes: []u32,
};

fn group_components(arena: Allocator, components: []const u32) !ComponentMembers {
    var components_count: u32 = 0;
    for (components) |component| components_count = @max(components_count, component + 1);
    const counts = try arena.alloc(u32, components_count + 1);
    @memset(counts, 0);
    for (components) |component| counts[component + 1] += 1;
    for (1..counts.len) |index| counts[index] += counts[index - 1];
    const nodes = try arena.alloc(u32, components.len);
    const cursor = try arena.dupe(u32, counts[0..components_count]);
    for (components, 0..) |component, node| {
        nodes[cursor[component]] = @intCast(node);
        cursor[component] += 1;
    }
    assert(counts[components_count] == components.len);
    assert(std.mem.eql(u32, cursor, counts[1..]));
    return .{ .first = counts[0..components_count], .first_next = counts[1..], .nodes = nodes };
}

/// `assert` and `verify` (the D20 convention, which asserts on `check()`) count as assertions.
fn is_assertion(name: []const u8) bool {
    assert(name.len > 0);
    const result = std.mem.eql(u8, name, "assert") or std.mem.eql(u8, name, "verify");
    if (result) assert(name.len == 6);
    return result;
}

fn diagnostic_less_than(_: void, a: Diagnostic, b: Diagnostic) bool {
    assert(a.path.len > 0);
    assert(b.path.len > 0);
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    if (a.line != b.line) return a.line < b.line;
    return @intFromEnum(a.rule) < @intFromEnum(b.rule);
}

pub fn is_snake_case_file_name(name: []const u8) bool {
    assert(name.len > 0);
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    const stem = name[0 .. name.len - ".zig".len];
    if (stem.len == 0) return false;
    if (!std.ascii.isLower(stem[0])) return false;
    for (stem) |character| {
        const allowed = std.ascii.isLower(character) or std.ascii.isDigit(character) or
            character == '_';
        if (!allowed) return false;
    }
    assert(stem.len > 0);
    return true;
}

fn compute_line_starts(arena: Allocator, source: []const u8) ![]u32 {
    assert(source.len < file_bytes_max);
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |character, offset| {
        if (character == '\n' and offset + 1 < source.len) {
            try starts.append(arena, @intCast(offset + 1));
        }
    }
    assert(starts.items.len > 0);
    return starts.items;
}

fn line_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    const end: u32 = if (std.mem.indexOfScalarPos(u8, source, start, '\n')) |newline|
        @intCast(newline)
    else
        @intCast(source.len);
    assert(end >= start);
    return end;
}

fn token_line(tree: *const Ast, token: Ast.TokenIndex) u32 {
    assert(token < tree.tokens.len);
    const line: u32 = @intCast(tree.tokenLocation(0, token).line + 1);
    assert(line > 0);
    return line;
}

/// Whether the run of `//` comment lines directly above `line` (1-based) contains `needle`.
fn comment_block_has(file: *const SourceFile, line: u32, needle: []const u8) bool {
    assert(line > 0);
    assert(needle.len > 0);
    var above = line - 1;
    while (above > 0) : (above -= 1) {
        const start = file.line_starts[above - 1];
        const text = std.mem.trim(u8, file.source[start..line_end(file.source, start)], " \t");
        if (!std.mem.startsWith(u8, text, "//")) return false;
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// Joins `directory` and `relative` and removes `.` and `..` segments.
fn join_normalized(arena: Allocator, directory: []const u8, relative: []const u8) ![]const u8 {
    assert(relative.len > 0);
    var segments: std.ArrayList([]const u8) = .empty;
    const parts = [_][]const u8{ directory, relative };
    for (parts) |part| {
        var iterator = std.mem.tokenizeScalar(u8, part, '/');
        while (iterator.next()) |segment| {
            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                _ = segments.pop();
                continue;
            }
            try segments.append(arena, segment);
        }
    }
    const joined = try std.mem.join(arena, "/", segments.items);
    assert(joined.len > 0);
    return joined;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    assert(arguments.len > 0);
    var paths: std.ArrayList([]const u8) = .empty;
    for (arguments[1..]) |argument| try collect_paths(arena, io, argument, &paths);
    std.mem.sort([]const u8, paths.items, {}, path_less_than);

    var linter = Linter.init(arena);
    var skipped_count: u32 = 0;
    for (paths.items) |path| {
        if (is_grandfathered(path)) {
            skipped_count += 1;
            continue;
        }
        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            arena,
            .limited(file_bytes_max),
            .of(u8),
            0,
        );
        try linter.add_file(path, source);
    }
    const diagnostics = try linter.finish();
    assert(skipped_count <= paths.items.len);
    try print_report(io, diagnostics, .{
        .files_count = @intCast(paths.items.len - skipped_count),
        .skipped_count = skipped_count,
    });
    if (diagnostics.len > 0) std.process.exit(1);
}

const ReportCounts = struct {
    files_count: u32,
    skipped_count: u32,
};

fn print_report(io: std.Io, diagnostics: []const Diagnostic, counts: ReportCounts) !void {
    assert(counts.files_count <= files_max);
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    for (diagnostics) |diagnostic| {
        try writer.print("{s}:{d}: {t}: {s}\n", .{
            diagnostic.path,
            diagnostic.line,
            diagnostic.rule,
            diagnostic.message,
        });
    }
    try writer.print("lint: {d} files checked, {d} grandfathered, {d} problems\n", .{
        counts.files_count,
        counts.skipped_count,
        diagnostics.len,
    });
    try writer.flush();
    assert(file_writer.interface.end == 0);
}

fn path_less_than(_: void, a: []const u8, b: []const u8) bool {
    assert(a.len > 0);
    assert(b.len > 0);
    return std.mem.order(u8, a, b) == .lt;
}

/// Adds `argument` if it is a `.zig` file, or every `.zig` file below it if it is a directory.
fn collect_paths(
    arena: Allocator,
    io: std.Io,
    argument: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    assert(argument.len > 0);
    if (std.mem.endsWith(u8, argument, ".zig")) {
        try paths.append(arena, argument);
        return;
    }
    var directory = try std.Io.Dir.cwd().openDir(io, argument, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const trimmed = std.mem.trimEnd(u8, argument, "/");
        try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ trimmed, entry.path }));
        assert(paths.items.len <= files_max);
    }
}

// ── Tests: each rule fires on a sample, and suppressions work ──────────────────────────────

fn lint_samples(arena: Allocator, samples: []const [2][:0]const u8) ![]const Diagnostic {
    var linter = Linter.init(arena);
    for (samples) |sample| try linter.add_file(sample[0], sample[1]);
    return linter.finish();
}

fn expect_rules(diagnostics: []const Diagnostic, expected: []const Rule) !void {
    var actual: [16]Rule = undefined;
    for (diagnostics, 0..) |diagnostic, index| actual[index] = diagnostic.rule;
    try std.testing.expectEqualSlices(Rule, expected, actual[0..diagnostics.len]);
}

const clean_function =
    \\fn half(value: u32) u32 {
    \\    assert(value % 2 == 0);
    \\    assert(value > 0);
    \\    return value / 2;
    \\}
    \\
;

test "a clean file has no problems" {
    // Goal: the rules don't fire on code that follows them. Method: lint one small function.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const samples = [_][2][:0]const u8{.{ "src/core/half.zig", clean_function }};
    const diagnostics = try lint_samples(arena.allocator(), &samples);
    try expect_rules(diagnostics, &.{});
}

test "file names must be snake_case" {
    // Goal: the file-name rule. Method: check accepted and rejected names directly.
    try std.testing.expect(is_snake_case_file_name("string_pool.zig"));
    try std.testing.expect(is_snake_case_file_name("utf16.zig"));
    try std.testing.expect(!is_snake_case_file_name("StringPool.zig"));
    try std.testing.expect(!is_snake_case_file_name("string-pool.zig"));
    try std.testing.expect(!is_snake_case_file_name("_hidden.zig"));
    try std.testing.expect(!is_snake_case_file_name("notes.md"));
}

test "long lines and long functions are reported" {
    // Goal: line-length and function-length rules. Method: generate a 71-line function whose
    // first line is also 101 columns wide.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena.allocator(), "fn long() void { // ");
    try source.appendNTimes(arena.allocator(), 'x', 81);
    try source.append(arena.allocator(), '\n');
    for (0..69) |_| try source.appendSlice(arena.allocator(), "    assert(true);\n");
    try source.appendSlice(arena.allocator(), "}\n");
    const text = try arena.allocator().dupeSentinel(u8, source.items, 0);
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/long.zig", text }});
    try expect_rules(diagnostics, &.{ .line_length, .function_length });
}

test "a suppression comment allows a long function" {
    // Goal: suppressions need the comment block above the function. Method: the same long
    // function with a reasoned suppression and a doc comment in between.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena.allocator(), "// lint: allow function_length: dispatch (D10)\n");
    try source.appendSlice(arena.allocator(), "/// Runs the VM.\nfn run() void {\n");
    for (0..70) |_| try source.appendSlice(arena.allocator(), "    assert(true);\n");
    try source.appendSlice(arena.allocator(), "}\n");
    const text = try arena.allocator().dupeSentinel(u8, source.items, 0);
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/vm/vm.zig", text }});
    try expect_rules(diagnostics, &.{});
}

test "usize struct fields are reported, usize locals are not" {
    // Goal: the usize-field rule. Method: one struct with a usize field and a u32 field, and a
    // function using usize only for a local.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\const Bad = struct { count: u32, offsets: ?[]usize };
        \\
    ++ clean_function;
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/bad.zig", source }});
    try expect_rules(diagnostics, &.{.usize_field});
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].line);
}

test "assertion density below two per function is reported" {
    // Goal: the density rule, verify() counting as an assertion, and the file-level
    // suppression. Method: sparse and verified samples, with and without the suppression.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sparse =
        \\fn a() void {
        \\    assert(true);
        \\}
        \\fn b() void {}
        \\
    ;
    const without = try lint_samples(arena.allocator(), &.{.{ "src/core/sparse.zig", sparse }});
    try expect_rules(without, &.{.assertion_density});
    const verified =
        \\fn a(s: S) void {
        \\    assert(s.ok);
        \\    fault.verify(s.check());
        \\}
        \\
    ;
    const counted = try lint_samples(arena.allocator(), &.{.{ "src/core/verified.zig", verified }});
    try expect_rules(counted, &.{});
    const suppressed = "// lint: allow assertion_density: generated tables\n" ++ sparse;
    const with = try lint_samples(arena.allocator(), &.{.{ "src/core/tables.zig", suppressed }});
    try expect_rules(with, &.{});
}

test "direct, mutual and cross-file recursion are reported" {
    // Goal: the call-graph rule. Method: a self-call, a two-function cycle through a method
    // call, and a cycle across two files through an import alias.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const local =
        \\fn self_call(n: u32) u32 {
        \\    assert(n > 0);
        \\    assert(n < 10);
        \\    return self_call(n - 1);
        \\}
        \\fn ping(s: *S) void {
        \\    assert(s.ok);
        \\    assert(true);
        \\    s.pong();
        \\}
        \\fn pong(s: *S) void {
        \\    assert(s.ok);
        \\    assert(true);
        \\    ping(s);
        \\}
        \\
    ;
    const a =
        \\const b = @import("../b/b.zig");
        \\fn there() void {
        \\    assert(true);
        \\    assert(true);
        \\    b.back();
        \\}
        \\
    ;
    const b =
        \\const a = @import("../a/a.zig");
        \\fn back() void {
        \\    assert(true);
        \\    assert(true);
        \\    a.there();
        \\}
        \\
    ;
    const diagnostics = try lint_samples(arena.allocator(), &.{
        .{ "src/local.zig", local },
        .{ "src/a/a.zig", a },
        .{ "src/b/b.zig", b },
    });
    try expect_rules(diagnostics, &.{ .recursion, .recursion, .recursion });
    try std.testing.expectEqualStrings("src/a/a.zig", diagnostics[0].path);
    try std.testing.expectEqualStrings("src/local.zig", diagnostics[1].path);
}

test "type-returning functions are exempt from length and density" {
    // Goal: the generic-type idiom isn't one long function. Method: a 72-line type function
    // whose methods each follow the rules.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena.allocator(), "fn Stack(comptime T: type) type {\n");
    try source.appendSlice(arena.allocator(), "    return struct {\n");
    for (0..14) |_| {
        try source.appendSlice(arena.allocator(),
            \\        fn m() void {
            \\            assert(true);
            \\            assert(true);
            \\        }
            \\
            \\
        );
    }
    try source.appendSlice(arena.allocator(), "    };\n}\n");
    const text = try arena.allocator().dupeSentinel(u8, source.items, 0);
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/stack.zig", text }});
    try expect_rules(diagnostics, &.{});
}

test "calls into std and through field chains are not recursion" {
    // Goal: the common false positives are gone. Method: functions named like std functions
    // that call them through `std.x`, an alias of std, and a field chain.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\fn hash(bytes: []const u8) u64 {
        \\    assert(bytes.len > 0);
        \\    assert(true);
        \\    return std.hash.Wyhash.hash(0, bytes);
        \\}
        \\fn eql(a: []const u8, b: []const u8) bool {
        \\    assert(a.len > 0);
        \\    assert(b.len > 0);
        \\    return mem.eql(u8, a, b);
        \\}
        \\fn deinit(pool: *Pool) void {
        \\    assert(pool.ok);
        \\    assert(true);
        \\    pool.table.deinit();
        \\}
        \\
    ;
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/pool.zig", source }});
    try expect_rules(diagnostics, &.{});
}

test "a suppressed false positive is not reported" {
    // Goal: name-based resolution can confuse two `init`s; a reasoned suppression silences it.
    // Method: `init` calls `other.init()` on a local whose type has its own `init`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\// lint: allow recursion: calls Other.init, not itself
        \\fn init(other: *Other) void {
        \\    assert(other.ready);
        \\    assert(true);
        \\    other.init();
        \\}
        \\
    ;
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/init.zig", source }});
    try expect_rules(diagnostics, &.{});
}

test "unparsable files and grandfathered paths" {
    // Goal: syntax errors are reported, and old code is skipped. Method: lint a broken file;
    // check the grandfathered prefixes directly.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/broken.zig", "fn (" }});
    try expect_rules(diagnostics, &.{.syntax});
    try std.testing.expect(is_grandfathered("src/runtime/story.zig"));
    try std.testing.expect(!is_grandfathered("src/core/index.zig"));
    try std.testing.expect(!is_grandfathered("tools/lint.zig"));
}
