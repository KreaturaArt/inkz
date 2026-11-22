//! TigerStyle lint for inkz, run with `zig build lint`.
//!
//! Rules: function length, line length, recursion (a name-based call graph), `usize` struct
//! fields and snake_case file names on all code, and assertion density (`assert` and `verify`
//! calls) on library code: src/core, src/runtime and src/compiler, without their test files.
//!
//! Suppressions are comments that must give a reason:
//! - `// lint: allow function_length: <reason>` or `// lint: allow recursion: <reason>` in the
//!   comment block directly above a function.
//! - `// lint: allow assertion_density: <reason>` anywhere in a file.
//! - `// lint: allow hot_path: <reason>` in the comment block directly above a function in a
//!   hot-path file, for code there that the step doesn't run (loading, the host API, path
//!   lookups). An empty reason is reported.
//!
//! The recursion check resolves calls by name: `f()` and `x.f()` match functions named `f` in
//! the same file, and `alias.f()` matches `f` in the file imported as `alias`. Calls through a
//! field chain (`a.b.f()`), a call result, or an alias of `std` or `builtin` go to other types
//! and are skipped. It cannot see types, so it over-approximates within a file; a false
//! positive needs a suppression.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const function_lines_max = 70;
pub const line_columns_max = 100;
pub const assertions_per_function_min = 1;
/// The library's directories; tests, harnesses, benchmarks, fuzz targets and tools assert
/// where it helps but have no density rule.
const density_directories = [_][]const u8{ "src/core/", "src/runtime/", "src/compiler/" };
pub const file_bytes_max = 16 * 1024 * 1024;

pub const Rule = enum {
    syntax,
    file_name,
    line_length,
    function_length,
    usize_field,
    assertion_density,
    recursion,
    /// Path-string resolution, string hashing or `mem.eql` in the VM's hot path.
    hot_path,
};

/// The files the VM's step reaches, which must not resolve paths, compare or hash strings, or
/// find names (tests in them are not checked).
pub const hot_path_files = [_][]const u8{
    "src/runtime/vm.zig",
    "src/runtime/ops.zig",
    "src/runtime/native.zig",
    "src/runtime/call_stack.zig",
    "src/runtime/lists.zig",
    "src/runtime/output.zig",
    "src/runtime/heap.zig",
    "src/runtime/text_cache.zig",
    "src/runtime/choices.zig",
    "src/runtime/lookahead.zig",
    "src/runtime/state.zig",
    "src/runtime/value.zig",
};
const hot_path_forbidden = [_][]const u8{
    "mem.eql",
    "hash(",
    "Hash(",
    "std.hash",
    "resolve_path",
    "path_string",
    "strings.find",
    "_by_name(",
    "global_slot(",
};
const hot_path_allow = "lint: allow hot_path:";

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

/// Collects files, then reports every rule violation in `finish`. All memory comes from
/// `arena`, which the caller frees.
pub const Linter = struct {
    arena: Allocator,
    files: std.ArrayList(SourceFile) = .empty,
    functions: std.ArrayList(Function) = .empty,
    calls: std.ArrayList(Call) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn add_file(linter: *Linter, path: []const u8, source: [:0]const u8) !void {
        if (!is_snake_case_file_name(std.fs.path.basename(path))) {
            try linter.report(path, 1, .file_name, "file name must be snake_case and end in .zig");
        }
        const tree = try Ast.parse(linter.arena, source, .{ .mode = .zig });
        if (tree.errors.len > 0) {
            const line = tree.tokenLocation(0, tree.errors[0].token).line + 1;
            try linter.report(path, @intCast(line), .syntax, "file does not parse");
            return;
        }
        var line_starts: std.ArrayList(u32) = .empty;
        try line_starts.append(linter.arena, 0);
        for (source, 0..) |character, offset| {
            if (character == '\n' and offset + 1 < source.len) {
                try line_starts.append(linter.arena, @intCast(offset + 1));
            }
        }
        try linter.files.append(linter.arena, .{
            .path = path,
            .source = source,
            .tree = tree,
            .line_starts = line_starts.items,
            .functions_first = @intCast(linter.functions.items.len),
            .functions_count = 0,
            .imports = .empty,
            .external_aliases = .empty,
        });
        const file_index: u32 = @intCast(linter.files.items.len - 1);
        try linter.check_lines(file_index);
        try linter.scan_declarations(file_index);
        if (is_hot_path(path)) try linter.check_hot_path(file_index);
        try linter.scan_calls(file_index);
    }

    /// Resolves the call graph, reports cycles and returns all diagnostics sorted by place.
    pub fn finish(linter: *Linter) ![]const Diagnostic {
        try linter.check_recursion();
        const items = linter.diagnostics.items;
        std.mem.sort(Diagnostic, items, {}, diagnostic_less_than);
        return items;
    }

    fn report(
        linter: *Linter,
        path: []const u8,
        line: u32,
        rule: Rule,
        message: []const u8,
    ) !void {
        try linter.diagnostics.append(linter.arena, .{
            .path = path,
            .line = line,
            .rule = rule,
            .message = message,
        });
    }

    fn check_lines(linter: *Linter, file_index: u32) !void {
        const file = &linter.files.items[file_index];
        for (file.line_starts, 0..) |start, line_index| {
            const end = line_end(file.source, start);
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

    /// The hot-path gate on a hot-path file's code, outside tests and suppressed functions
    /// (comments may name what is forbidden).
    fn check_hot_path(linter: *Linter, file_index: u32) !void {
        const file = &linter.files.items[file_index];
        const skipped = try linter.arena.alloc(bool, file.line_starts.len);
        @memset(skipped, false);
        try linter.skip_hot_path_exempt(file_index, skipped);
        for (file.line_starts, 0..) |start, line_index| {
            if (skipped[line_index]) continue;
            const text = file.source[start..line_end(file.source, start)];
            const code_end = std.mem.indexOf(u8, text, "//") orelse text.len;
            for (hot_path_forbidden) |forbidden| {
                if (std.mem.indexOf(u8, text[0..code_end], forbidden) == null) continue;
                const message = try std.fmt.allocPrint(
                    linter.arena,
                    "'{s}' in the VM's hot path",
                    .{forbidden},
                );
                try linter.report(file.path, @intCast(line_index + 1), .hot_path, message);
            }
        }
    }

    /// Marks the lines of tests, comptime blocks and functions under a hot-path suppression;
    /// reports a suppression without a reason.
    fn skip_hot_path_exempt(linter: *Linter, file_index: u32, skipped: []bool) !void {
        const file = &linter.files.items[file_index];
        const nodes_count: u32 = @intCast(file.tree.nodes.len);
        var node_raw: u32 = 1;
        while (node_raw < nodes_count) : (node_raw += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(node_raw));
            const tag = file.tree.nodeTag(node);
            if (tag != .test_decl and tag != .@"comptime") continue;
            const first = token_line(&file.tree, file.tree.firstToken(node));
            const last = token_line(&file.tree, file.tree.lastToken(node));
            @memset(skipped[first - 1 .. last], true);
        }
        const functions = linter.functions.items[file.functions_first..][0..file.functions_count];
        for (functions) |function| {
            const reason = comment_above(file, function.line, hot_path_allow) orelse
                continue;
            if (reason.len == 0) {
                const message = "a hot-path suppression needs a reason";
                try linter.report(file.path, function.line, .hot_path, message);
                continue;
            }
            const last = token_line(&file.tree, function.token_last);
            @memset(skipped[function.line - 1 .. last], true);
        }
    }

    /// One pass over every node: functions, `usize` fields and top-level imports.
    fn scan_declarations(linter: *Linter, file_index: u32) !void {
        const tree = &linter.files.items[file_index].tree;
        const nodes_count: u32 = @intCast(tree.nodes.len);
        var node_raw: u32 = 1;
        while (node_raw < nodes_count) : (node_raw += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(node_raw));
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
    }

    fn add_function(linter: *Linter, file_index: u32, node: Ast.Node.Index) !void {
        const file = &linter.files.items[file_index];
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = file.tree.fullFnProto(&buffer, node).?;
        const name_token = prototype.name_token orelse return;
        const token_first = file.tree.firstToken(node);
        const token_last = file.tree.lastToken(node);
        const line_first = token_line(&file.tree, token_first);
        const line_last = token_line(&file.tree, token_last);
        const name = file.tree.tokenSlice(name_token);
        const lines_count = line_last - line_first + 1;
        const returns_type = if (prototype.ast.return_type.unwrap()) |return_type|
            file.tree.nodeTag(return_type) == .identifier and
                std.mem.eql(u8, file.tree.tokenSlice(file.tree.nodeMainToken(return_type)), "type")
        else
            false;
        if (lines_count > function_lines_max and !returns_type and
            comment_above(file, line_first, "lint: allow function_length:") == null)
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
            .allow_recursion = comment_above(file, line_first, "lint: allow recursion:") != null,
            .returns_type = returns_type,
        });
    }

    fn check_field(linter: *Linter, file_index: u32, node: Ast.Node.Index) !void {
        const file = &linter.files.items[file_index];
        const field = file.tree.fullContainerField(node).?;
        const type_node = field.ast.type_expr.unwrap() orelse return;
        const token_first = file.tree.firstToken(type_node);
        const token_last = file.tree.lastToken(type_node);
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
        try file.imports.append(linter.arena, .{ .alias = alias, .path = path });
    }

    /// Records calls for the call graph and counts assertions per function.
    fn scan_calls(linter: *Linter, file_index: u32) !void {
        const file = &linter.files.items[file_index];
        var assertions_count: u32 = 0;
        const nodes_count: u32 = @intCast(file.tree.nodes.len);
        var node_raw: u32 = 1;
        while (node_raw < nodes_count) : (node_raw += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(node_raw));
            var buffer: [1]Ast.Node.Index = undefined;
            const call = file.tree.fullCall(&buffer, node) orelse continue;
            const caller = linter.enclosing_function(file_index, call.ast.lparen) orelse continue;
            const callee = callee_of(file, call.ast.fn_expr) orelse continue;
            // `assert` and `verify` (the `check()`/`verify()` convention) count as assertions.
            if (std.mem.eql(u8, callee.name, "assert") or std.mem.eql(u8, callee.name, "verify")) {
                assertions_count += 1;
            }
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
        // Library code only: the density directories, without their test files.
        if (std.mem.endsWith(u8, file.path, "_test.zig")) return;
        if (std.mem.endsWith(u8, file.path, "_tests.zig")) return;
        for (density_directories) |directory| {
            if (std.mem.startsWith(u8, file.path, directory)) break;
        } else return;
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
        try linter.report(file.path, 1, .assertion_density, message);
    }

    /// The innermost function of `file_index` whose tokens contain `token`.
    fn enclosing_function(linter: *const Linter, file_index: u32, token: Ast.TokenIndex) ?u32 {
        const file = &linter.files.items[file_index];
        const functions = linter.functions.items[file.functions_first..][0..file.functions_count];
        var found: ?u32 = null;
        for (functions, file.functions_first..) |function, index| {
            if (token < function.token_first or token > function.token_last) continue;
            if (found) |previous| {
                if (function.token_first < linter.functions.items[previous].token_first) continue;
            }
            found = @intCast(index);
        }
        return found;
    }

    /// Reports each call cycle on which no function has a recursion suppression.
    fn check_recursion(linter: *Linter) !void {
        const cycles = try call_cycles(linter.arena, try linter.call_graph());
        cycles: for (cycles) |cycle| {
            for (cycle) |node| {
                if (linter.functions.items[node].allow_recursion) continue :cycles;
            }
            var names: std.ArrayList(u8) = .empty;
            for (cycle, 0..) |node, index| {
                if (index > 0) try names.appendSlice(linter.arena, ", ");
                try names.appendSlice(linter.arena, linter.functions.items[node].name);
            }
            const function = linter.functions.items[cycle[0]];
            const path = linter.files.items[function.file].path;
            const message = try std.fmt.allocPrint(
                linter.arena,
                "functions call themselves: {s}",
                .{names.items},
            );
            try linter.report(path, function.line, .recursion, message);
        }
    }

    /// The functions each function calls, resolved by name, without duplicates.
    fn call_graph(linter: *Linter) ![]const []const u32 {
        const callees = try linter.arena.alloc(std.ArrayList(u32), linter.functions.items.len);
        @memset(callees, .empty);
        calls: for (linter.calls.items) |call| {
            var target_file = linter.functions.items[call.caller].file;
            if (call.target_path) |path| {
                target_file = for (linter.files.items, 0..) |file, index| {
                    if (std.mem.eql(u8, file.path, path)) break @intCast(index);
                } else continue :calls;
            }
            const file = &linter.files.items[target_file];
            const first = file.functions_first;
            const functions = linter.functions.items[first..][0..file.functions_count];
            const list = &callees[call.caller];
            for (functions, first..) |function, callee| {
                if (!std.mem.eql(u8, function.name, call.callee_name)) continue;
                if (std.mem.indexOfScalar(u32, list.items, @intCast(callee)) != null) continue;
                try list.append(linter.arena, @intCast(callee));
            }
        }
        const graph = try linter.arena.alloc([]const u32, callees.len);
        for (graph, callees) |*successors, list| successors.* = list.items;
        return graph;
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
    switch (tree.nodeTag(expression)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(expression));
            return .{ .name = name, .target = .same_file };
        },
        .field_access => {
            const data = tree.nodeData(expression).node_and_token;
            const name = tree.tokenSlice(data[1]);
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

/// The string argument of `@import("...")`, without quotes.
fn import_argument(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    const argument = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(argument) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(argument));
    return literal[1 .. literal.len - 1];
}

/// The cycles of `graph` (`graph[n]` are the successors of node `n`) as the back edges of an
/// iterative depth-first search: each cycle is the search path from the edge's target to its
/// source. A graph has a cycle exactly when it has a back edge, and a strongly connected
/// component with no suppressed member always yields a cycle inside it.
fn call_cycles(arena: Allocator, graph: []const []const u32) ![]const []const u32 {
    const State = enum { unvisited, on_path, done };
    const states = try arena.alloc(State, graph.len);
    @memset(states, .unvisited);
    // The search path, and for each node on it the index of its next edge to follow.
    var path: std.ArrayList(u32) = .empty;
    var edges_next: std.ArrayList(u32) = .empty;
    var cycles: std.ArrayList([]const u32) = .empty;
    for (0..graph.len) |root| {
        if (states[root] != .unvisited) continue;
        states[root] = .on_path;
        try path.append(arena, @intCast(root));
        try edges_next.append(arena, 0);
        while (path.items.len > 0) {
            const node = path.items[path.items.len - 1];
            const edge = &edges_next.items[edges_next.items.len - 1];
            if (edge.* == graph[node].len) {
                states[node] = .done;
                _ = path.pop();
                _ = edges_next.pop();
                continue;
            }
            const target = graph[node][edge.*];
            edge.* += 1;
            switch (states[target]) {
                .unvisited => {
                    states[target] = .on_path;
                    try path.append(arena, target);
                    try edges_next.append(arena, 0);
                },
                .on_path => {
                    const first = std.mem.indexOfScalar(u32, path.items, target).?;
                    try cycles.append(arena, try arena.dupe(u32, path.items[first..]));
                },
                .done => {},
            }
        }
    }
    return cycles.items;
}

fn diagnostic_less_than(_: void, a: Diagnostic, b: Diagnostic) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    if (a.line != b.line) return a.line < b.line;
    return @backingInt(a.rule) < @backingInt(b.rule);
}

pub fn is_snake_case_file_name(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    const stem = name[0 .. name.len - ".zig".len];
    if (stem.len == 0) return false;
    if (!std.ascii.isLower(stem[0])) return false;
    for (stem) |character| {
        const allowed = std.ascii.isLower(character) or std.ascii.isDigit(character) or
            character == '_';
        if (!allowed) return false;
    }
    return true;
}

fn line_end(source: []const u8, start: u32) u32 {
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return @intCast(end);
}

fn token_line(tree: *const Ast, token: Ast.TokenIndex) u32 {
    return @intCast(tree.tokenLocation(0, token).line + 1);
}

/// Whether `path` is one of the files the VM's step reaches.
fn is_hot_path(path: []const u8) bool {
    for (hot_path_files) |hot| {
        if (std.mem.endsWith(u8, path, hot)) return true;
    }
    return false;
}

/// The text after `needle` (trimmed) in the run of `//` comment lines directly above `line`
/// (1-based), or null if no line there contains it.
fn comment_above(file: *const SourceFile, line: u32, needle: []const u8) ?[]const u8 {
    var above = line - 1;
    while (above > 0) : (above -= 1) {
        const start = file.line_starts[above - 1];
        const text = std.mem.trim(u8, file.source[start..line_end(file.source, start)], " \t");
        if (!std.mem.startsWith(u8, text, "//")) return null;
        const at = std.mem.indexOf(u8, text, needle) orelse continue;
        return std.mem.trim(u8, text[at + needle.len ..], " \t");
    }
    return null;
}

/// Joins `directory` and `relative` and removes `.` and `..` segments.
fn join_normalized(arena: Allocator, directory: []const u8, relative: []const u8) ![]const u8 {
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
    return std.mem.join(arena, "/", segments.items);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    for (arguments[1..]) |argument| try collect_paths(arena, io, argument, &paths);
    std.mem.sort([]const u8, paths.items, {}, path_less_than);

    var linter: Linter = .{ .arena = arena };
    for (paths.items) |path| {
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
    const files_count = paths.items.len;
    try writer.print("lint: {d} files checked, {d} problems\n", .{ files_count, diagnostics.len });
    try writer.flush();
    if (diagnostics.len > 0) std.process.exit(1);
}

fn path_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Adds `argument` if it is a `.zig` file, or every `.zig` file below it if it is a directory.
fn collect_paths(
    arena: Allocator,
    io: std.Io,
    argument: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
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
    }
}

// ── Tests: each rule fires on a sample, and suppressions work ──────────────────────────────

fn lint_samples(arena: Allocator, samples: []const [2][:0]const u8) ![]const Diagnostic {
    var linter: Linter = .{ .arena = arena };
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
    // The rules don't fire on code that follows them: lint one small function.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const samples = [_][2][:0]const u8{.{ "src/core/half.zig", clean_function }};
    const diagnostics = try lint_samples(arena.allocator(), &samples);
    try expect_rules(diagnostics, &.{});
}

test "file names must be snake_case" {
    // The file-name rule: check accepted and rejected names directly.
    try std.testing.expect(is_snake_case_file_name("string_pool.zig"));
    try std.testing.expect(is_snake_case_file_name("utf16.zig"));
    try std.testing.expect(!is_snake_case_file_name("StringPool.zig"));
    try std.testing.expect(!is_snake_case_file_name("string-pool.zig"));
    try std.testing.expect(!is_snake_case_file_name("_hidden.zig"));
    try std.testing.expect(!is_snake_case_file_name("notes.md"));
}

test "long lines and long functions are reported" {
    // Line-length and function-length rules: generate a 71-line function whose
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

test "the VM's hot path may not compare or hash strings" {
    // The hot-path grep gate: the same line in the VM and in a file the step doesn't
    // reach, and in a comment.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "fn f(a: []const u8) bool {\n    assert(a.len > 0);\n    assert(true);\n" ++
        "    // mem.eql is named here only\n    return std.mem.eql(u8, a, \"x\");\n}\n";
    const in_vm = try lint_samples(arena.allocator(), &.{.{ "src/runtime/vm.zig", text }});
    try expect_rules(in_vm, &.{.hot_path});
    const elsewhere = try lint_samples(arena.allocator(), &.{.{ "src/runtime/load.zig", text }});
    try expect_rules(elsewhere, &.{});
}

test "every file the step reaches is on the hot path" {
    // A name lookup in ops.zig, which the step runs, is reported; the same lookup in a
    // test there is not.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lookup = "fn temp(s: S, name: []const u8) ?u32 {\n    assert(name.len > 0);\n" ++
        "    return s.strings.find(name);\n}\n";
    const in_ops = try lint_samples(arena.allocator(), &.{.{ "src/runtime/ops.zig", lookup }});
    try expect_rules(in_ops, &.{.hot_path});
    try std.testing.expectEqual(@as(u32, 3), in_ops[0].line);
    const in_test = "test \"t\" {\n    _ = s.strings.find(\"x\");\n}\n";
    const tested = try lint_samples(arena.allocator(), &.{.{ "src/runtime/ops.zig", in_test }});
    try expect_rules(tested, &.{});
    const names = "fn g(p: P) void {\n    assert(true);\n    _ = p.global_slot(1);\n" ++
        "    _ = p.list_item_by_name(\"a\");\n}\n";
    const found = try lint_samples(arena.allocator(), &.{.{ "src/runtime/lists.zig", names }});
    try expect_rules(found, &.{ .hot_path, .hot_path });
}

test "a hot-path suppression needs a reason" {
    // The same lookup under a reasoned suppression (with a doc comment between) is
    // allowed; under an empty one it is reported, and so is the suppression.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = "fn temp(s: S, name: []const u8) ?u32 {\n    assert(name.len > 0);\n" ++
        "    return s.strings.find(name);\n}\n";
    const reasoned = "// lint: allow hot_path: the host names it\n/// Finds a temp.\n" ++ body;
    const allowed = try lint_samples(arena.allocator(), &.{.{ "src/runtime/ops.zig", reasoned }});
    try expect_rules(allowed, &.{});
    const empty = "// lint: allow hot_path:\n" ++ body;
    const unreasoned = try lint_samples(arena.allocator(), &.{.{ "src/runtime/ops.zig", empty }});
    try expect_rules(unreasoned, &.{ .hot_path, .hot_path });
}

test "a suppression comment allows a long function" {
    // Suppressions need the comment block above the function: the same long
    // function with a reasoned suppression and a doc comment in between.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena.allocator(), "// lint: allow function_length: dispatch (D10)\n");
    try source.appendSlice(arena.allocator(), "/// Runs the VM.\nfn run() void {\n");
    for (0..70) |_| try source.appendSlice(arena.allocator(), "    assert(true);\n");
    try source.appendSlice(arena.allocator(), "}\n");
    const text = try arena.allocator().dupeSentinel(u8, source.items, 0);
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/runtime/vm.zig", text }});
    try expect_rules(diagnostics, &.{});
}

test "usize struct fields are reported, usize locals are not" {
    // The usize-field rule: one struct with a usize field and a u32 field, and a
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

test "library code below one assertion per function is reported" {
    // The density rule, verify() counting as an assertion, and the file-level
    // suppression. Sparse and verified samples, with and without the suppression.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sparse =
        \\fn a() void {}
        \\fn b() void {}
        \\fn c(x: u32) void {
        \\    assert(x > 0);
        \\}
        \\
    ;
    const without = try lint_samples(arena.allocator(), &.{.{ "src/core/sparse.zig", sparse }});
    try expect_rules(without, &.{.assertion_density});
    const verified =
        \\fn a(s: S) void {
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

test "tests, harnesses and tools have no density rule" {
    // Only the library's directories count; their test files don't.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bare = "fn a() void {}\nfn b() void {}\n";
    const paths = [_][:0]const u8{
        "src/testing/oracle.zig", "src/fuzz/vm.zig",          "tools/doctest.zig",
        "src/bench.zig",          "src/runtime/api_test.zig", "src/compiler/lowering_tests.zig",
    };
    for (paths) |path| {
        const diagnostics = try lint_samples(arena.allocator(), &.{.{ path, bare }});
        try expect_rules(diagnostics, &.{});
    }
    const library = try lint_samples(arena.allocator(), &.{.{ "src/runtime/ops.zig", bare }});
    try expect_rules(library, &.{.assertion_density});
}

test "direct, mutual and cross-file recursion are reported" {
    // The call-graph rule: a self-call, a two-function cycle through a method
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
    // The generic-type idiom isn't one long function: a 72-line type function
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
    // The common false positives are gone: functions named like std functions
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
    // Name-based resolution can confuse two `init`s; a reasoned suppression silences it.
    // `init` calls `other.init()` on a local whose type has its own `init`.
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

test "unparsable files are reported" {
    // Syntax errors are reported: lint a broken file.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const diagnostics = try lint_samples(arena.allocator(), &.{.{ "src/core/broken.zig", "fn (" }});
    try expect_rules(diagnostics, &.{.syntax});
}

test "the cycle search reports exactly the functions on a cycle" {
    // A self-loop (0), a 3-cycle (2, 3, 4) reached from an acyclic caller (1), and an
    // acyclic chain (5, 6, 7) with a shared callee, so a done node is reached twice.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const graph = [_][]const u32{
        &.{ 0, 1 }, &.{2}, &.{3}, &.{4}, &.{ 2, 5 },
        &.{ 6, 7 }, &.{7}, &.{},
    };
    const cycles = try call_cycles(arena.allocator(), &graph);
    try std.testing.expectEqual(@as(usize, 2), cycles.len);
    try std.testing.expectEqualSlices(u32, &.{0}, cycles[0]);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, cycles[1]);
}
