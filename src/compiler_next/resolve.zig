//! Name resolution on the object tree (plan §4.12, P8.1), as ink does it in two phases:
//!
//! 1. While ink generates runtime objects, in tree order, it registers declarations (VAR,
//!    temp, LIST, EXTERNAL) and resolves each divert's target: a name declared so far as a
//!    variable or parameter makes it a variable divert, otherwise ink's Path lookup finds the
//!    knot, stitch or label (Divert.ResolveTargetContent).
//! 2. Then ResolveReferences checks everything with full knowledge: variable references
//!    (read counts first, then parameters, temps of the flow and globals), assignments,
//!    increments, the diverts' errors, and naming collisions.
//!
//! The scopes are ink's: a flow's sub-flows by name, the labels of a flow's root weave (ink
//! names no other weave), a flow's parameters and temps, and the story's globals, constants,
//! lists and externals. Path lookup follows Path.ResolveFromContext and
//! FlowBase.ContentWithNameAtLevel, with explicit stacks.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sema = @import("sema.zig");
const grammar = @import("grammar.zig");
const ast_module = @import("ast.zig");
const passes = @import("resolve_passes.zig");
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const NodeIndex = ast_module.NodeIndex;

pub const path_components_max = 16;

pub const FlowLevel = enum(u8) { story, knot, stitch, weave_point };

/// What a variable reference, assignment or increment resolved to.
pub const Reference = enum(u8) {
    none,
    unresolved,
    global,
    temporary,
    argument,
    constant,
    list_item,
    read_count,
};

pub const Code = enum(u8) {
    target_not_found,
    unresolved_variable,
    read_count_target_not_found,
    assignment_target_not_found,
    assignment_to_constant,
    increment_target_not_found,
    duplicate_label,
    duplicate_declaration,
    duplicate_argument,
    duplicate_external,
    name_conflict,
    reserved_name,
    builtin_name,
    not_a_function,
    function_diverted_to,
    builtin_not_called,
    ambiguous_list_item,
    global_refers_to_variable,
    duplicate_list_item,
    constant_redefined,
    unsupported_fold,
};

pub const Diagnostic = struct {
    code: Code,
    object: ObjectIndex,
};

pub const Resolution = struct {
    /// A divert's target content, a read count's target, or none.
    targets: []ObjectIndex,
    references: []Reference,
    /// Diverts whose target is a variable (ink's variableDivertName).
    variable_diverts: std.DynamicBitSetUnmanaged,
    /// A list item's value (ink's seriesValue), by object; 0 for other objects.
    item_values: []i32,
    diagnostics: []Diagnostic,

    pub fn deinit(resolution: *Resolution, gpa: Allocator) void {
        assert(resolution.targets.len == resolution.references.len);
        assert(resolution.variable_diverts.bit_length == resolution.targets.len);
        gpa.free(resolution.targets);
        gpa.free(resolution.references);
        gpa.free(resolution.item_values);
        resolution.variable_diverts.deinit(gpa);
        gpa.free(resolution.diagnostics);
        resolution.* = undefined;
    }
};

/// A scope and a name: the key of every name table.
pub const Key = struct {
    scope: ObjectIndex,
    name: []const u8,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        assert(!key.scope.is_none());
        assert(key.name.len < std.math.maxInt(u32));
        return std.hash.Wyhash.hash(@backingInt(key.scope), key.name);
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        assert(!a.scope.is_none() and !b.scope.is_none());
        assert(a.name.len < std.math.maxInt(u32));
        return a.scope == b.scope and std.mem.eql(u8, a.name, b.name);
    }
};

pub const Table = std.HashMapUnmanaged(Key, ObjectIndex, KeyContext, 80);

/// A dotted path's components.
pub const Path = struct {
    components: [path_components_max][]const u8 = undefined,
    count: u32 = 0,

    pub fn first(path: *const Path) []const u8 {
        assert(path.count > 0);
        assert(path.count <= path_components_max);
        return path.components[0];
    }

    pub fn is_single(path: *const Path, name: []const u8) bool {
        assert(path.count <= path_components_max);
        assert(name.len > 0);
        return path.count == 1 and std.mem.eql(u8, path.components[0], name);
    }
};

/// The names, scopes and lookups shared by both passes.
pub const Context = struct {
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    /// Story-level object for globals, constants, lists and externals: the root.
    subflows: Table = .empty,
    labels: Table = .empty,
    declarations: Table = .empty,
    constants: Table = .empty,
    lists: Table = .empty,
    externals: Table = .empty,
    /// Lists in declaration order (ink searches them in order for an unqualified item).
    list_order: std.ArrayList(ObjectIndex) = .empty,
    /// Each flow's root weave (or none).
    root_weaves: []ObjectIndex = &.{},
    targets: []ObjectIndex = &.{},
    references: []Reference = &.{},
    item_values: []i32 = &.{},
    variable_diverts: std.DynamicBitSetUnmanaged = .{},
    /// Proxy diverts of built-in calls: ink never generates or resolves them.
    skipped: std.DynamicBitSetUnmanaged = .{},
    /// Objects that already have an error (ink's _alreadyHadError).
    had_error: std.DynamicBitSetUnmanaged = .{},
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(context: *Context) void {
        assert(context.tree.count() > 0);
        const gpa = context.gpa;
        assert(context.root_weaves.len == context.tree.count() or context.root_weaves.len == 0);
        inline for (.{
            "subflows",
            "labels",
            "declarations",
            "constants",
            "lists",
            "externals",
        }) |name| {
            @field(context, name).deinit(gpa);
        }
        context.list_order.deinit(gpa);
        gpa.free(context.root_weaves);
        gpa.free(context.targets);
        gpa.free(context.references);
        gpa.free(context.item_values);
        context.variable_diverts.deinit(gpa);
        context.skipped.deinit(gpa);
        context.had_error.deinit(gpa);
        context.diagnostics.deinit(gpa);
    }

    pub fn ast(context: *const Context) *const ast_module.Ast {
        assert(context.parsed.tree.tags.len > 0);
        assert(context.tree.count() > 0);
        return &context.parsed.tree;
    }

    /// The text of an identifier leaf (empty for none or missing).
    pub fn leaf_text(context: *const Context, leaf: NodeIndex) []const u8 {
        assert(context.tree.count() > 0);
        const tree = context.ast();
        const tag = tree.tag(leaf);
        if (tag == .none or tag == .missing) return "";
        assert(ast_module.shape(tag) == .leaf);
        const token = tree.data[leaf.to_int()];
        const workspace = &context.parsed.workspace;
        return context.parsed.source[workspace.token_starts[token]..workspace.token_ends[token]];
    }

    /// Records an error on `object`; as in ink, an object gets at most one.
    pub fn report(context: *Context, code: Code, object: ObjectIndex) !void {
        assert(object.to_int() < context.tree.count());
        assert(context.diagnostics.items.len < std.math.maxInt(u32));
        if (context.had_error.isSet(object.to_int())) return;
        context.had_error.set(object.to_int());
        try context.diagnostics.append(context.gpa, .{ .code = code, .object = object });
    }

    pub fn level(context: *const Context, flow: ObjectIndex) FlowLevel {
        assert(context.tree.count() > 0);
        assert(context.tree.is_flow(flow));
        return switch (context.tree.kind(flow)) {
            .story => .story,
            .knot => .knot,
            else => .stitch,
        };
    }

    /// A flow's name (empty for the story).
    pub fn flow_name(context: *const Context, flow: ObjectIndex) []const u8 {
        assert(context.tree.count() > 0);
        assert(context.tree.is_flow(flow));
        if (context.tree.kind(flow) == .story) return "";
        return context.leaf_text(context.ast().child(context.tree.node(flow), 0));
    }

    /// A choice's or gather's label (empty if it has none).
    pub fn label(context: *const Context, point: ObjectIndex) []const u8 {
        assert(context.tree.count() > 0);
        const kind = context.tree.kind(point);
        assert(kind == .choice or kind == .gather);
        const node = context.tree.node(point);
        if (node.is_none()) return "";
        return context.leaf_text(context.ast().child(node, 1));
    }

    /// The flow's parameters, as their identifier leaves.
    pub fn parameters(context: *const Context, flow: ObjectIndex) []const ast_module.Tag {
        assert(context.tree.count() > 0);
        assert(context.tree.is_flow(flow));
        if (context.tree.kind(flow) == .story) return &.{};
        const list_node = context.ast().child(context.tree.node(flow), 1);
        if (context.ast().tag(list_node) == .none) return &.{};
        const listed = context.ast().list(list_node);
        return context.ast().tags[listed.first.to_int()..][0..listed.count];
    }

    /// The name of parameter `position` of `flow`.
    pub fn parameter_name(context: *const Context, flow: ObjectIndex, position: u32) []const u8 {
        assert(context.tree.count() > 0);
        const list_node = context.ast().child(context.tree.node(flow), 1);
        const listed = context.ast().list(list_node);
        assert(position < listed.count);
        return context.leaf_text(.from_int(listed.first.to_int() + position));
    }

    /// The components of a `path` node.
    pub fn path_of(context: *const Context, path_node: NodeIndex) Path {
        assert(context.tree.count() > 0);
        assert(context.ast().tag(path_node) == .path);
        const listed = context.ast().list(path_node);
        var path: Path = .{};
        for (0..@min(listed.count, path_components_max)) |position| {
            const component = context.ast().item(path_node, position);
            path.components[position] = context.leaf_text(component);
            path.count += 1;
        }
        return path;
    }

    pub fn lookup(
        context: *const Context,
        table: *const Table,
        scope: ObjectIndex,
        name: []const u8,
    ) ?ObjectIndex {
        assert(scope.to_int() < context.tree.count());
        assert(table.count() <= context.tree.count());
        return table.get(.{ .scope = scope, .name = name });
    }
};

/// Resolves every name of `tree`.
pub fn resolve(gpa: Allocator, parsed: *const grammar.Parsed, tree: *const Tree) !Resolution {
    assert(tree.kind(Tree.root) == .story);
    var context: Context = .{ .gpa = gpa, .parsed = parsed, .tree = tree };
    defer context.deinit();
    try passes.prepare(&context);
    try passes.generation_pass(&context);
    try passes.references_pass(&context);
    const resolution: Resolution = .{
        .targets = context.targets,
        .references = context.references,
        .variable_diverts = context.variable_diverts,
        .item_values = context.item_values,
        .diagnostics = try context.diagnostics.toOwnedSlice(gpa),
    };
    context.targets = &.{};
    context.references = &.{};
    context.item_values = &.{};
    context.variable_diverts = .{};
    assert(resolution.targets.len == tree.count());
    return resolution;
}

// Tests.

const Fixture = struct {
    parsed: grammar.Parsed,
    tree: Tree,
    resolution: Resolution,

    fn init(fixture: *Fixture, source: []const u8) !void {
        assert(source.len < std.math.maxInt(u32));
        const gpa = std.testing.allocator;
        fixture.parsed = try grammar.parse(gpa, source, .{});
        errdefer fixture.parsed.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), fixture.parsed.diagnostics_count);
        fixture.tree = try sema.build_tree(gpa, &fixture.parsed);
        errdefer fixture.tree.deinit(gpa);
        assert(fixture.tree.kind(Tree.root) == .story);
        fixture.resolution = try resolve(gpa, &fixture.parsed, &fixture.tree);
    }

    fn deinit(fixture: *Fixture) void {
        assert(fixture.tree.count() > 0);
        assert(fixture.resolution.targets.len == fixture.tree.count());
        const gpa = std.testing.allocator;
        fixture.resolution.deinit(gpa);
        fixture.tree.deinit(gpa);
        fixture.parsed.deinit(gpa);
    }

    /// The `nth` object of `kind` in tree order (pre-order).
    fn nth(fixture: *const Fixture, kind: sema.Kind, nth_wanted: u32) ObjectIndex {
        assert(fixture.tree.count() > 0);
        assert(fixture.resolution.targets.len == fixture.tree.count());
        var stack: [256]ObjectIndex = undefined;
        var depth: u32 = 1;
        stack[0] = Tree.root;
        var seen: u32 = 0;
        while (depth > 0) {
            depth -= 1;
            const object = stack[depth];
            if (fixture.tree.kind(object) == kind) {
                if (seen == nth_wanted) return object;
                seen += 1;
            }
            const children = fixture.tree.children_of(object);
            var position = children.len;
            while (position > 0) {
                position -= 1;
                stack[depth] = children[position];
                depth += 1;
            }
        }
        unreachable;
    }

    fn target(fixture: *const Fixture, object: ObjectIndex) ObjectIndex {
        assert(fixture.tree.count() > 0);
        assert(fixture.resolution.targets.len == fixture.tree.count());
        return fixture.resolution.targets[object.to_int()];
    }

    fn reference(fixture: *const Fixture, object: ObjectIndex) Reference {
        assert(fixture.tree.count() > 0);
        assert(fixture.resolution.targets.len == fixture.tree.count());
        return fixture.resolution.references[object.to_int()];
    }

    fn codes(fixture: *const Fixture) []const Diagnostic {
        assert(fixture.tree.count() > 0);
        assert(fixture.resolution.targets.len == fixture.tree.count());
        return fixture.resolution.diagnostics;
    }
};

test "the same label in two knots resolves within each knot" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\== a ==
        \\- (top) A
        \\-> top
        \\== b ==
        \\- (top) B
        \\-> top
        \\
    );
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.codes().len);
    // Diverts in order: the story's -> DONE, then a's and b's.
    // Gathers in order: the story's closing gather, then a's and b's labelled ones.
    try std.testing.expectEqual(fixture.nth(.gather, 1), fixture.target(fixture.nth(.divert, 1)));
    try std.testing.expectEqual(fixture.nth(.gather, 2), fixture.target(fixture.nth(.divert, 2)));
}

test "temps are scoped to their flow; a temp is known before its line, as in ink" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\== a ==
        \\{x}
        \\~ temp x = 1
        \\-> b
        \\== b ==
        \\{x}
        \\-> DONE
        \\
    );
    defer fixture.deinit();
    try std.testing.expectEqual(
        Reference.temporary,
        fixture.reference(fixture.nth(.variable_reference, 0)),
    );
    try std.testing.expectEqual(
        Reference.unresolved,
        fixture.reference(fixture.nth(.variable_reference, 1)),
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.codes().len);
    try std.testing.expectEqual(Code.unresolved_variable, fixture.codes()[0].code);
}

test "forward references: knots, stitches, labels and globals declared later" {
    // As in ink (checked with inklecate): the story level doesn't search inside knots for
    // labels, a knot does; so the top-level {later} is unresolved and the knot's resolves.
    var fixture: Fixture = undefined;
    try fixture.init(
        \\{g} {k} {k.s} {later}
        \\-> k.s
        \\VAR g = 1
        \\== k ==
        \\{later}
        \\-> s
        \\= s
        \\- (later) Done.
        \\-> DONE
        \\
    );
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.codes().len);
    try std.testing.expectEqual(Code.unresolved_variable, fixture.codes()[0].code);
    try std.testing.expectEqual(fixture.nth(.variable_reference, 3), fixture.codes()[0].object);
    try std.testing.expectEqual(
        Reference.global,
        fixture.reference(fixture.nth(.variable_reference, 0)),
    );
    const knot = fixture.nth(.knot, 0);
    const stitch = fixture.nth(.stitch, 0);
    try std.testing.expectEqual(knot, fixture.target(fixture.nth(.variable_reference, 1)));
    try std.testing.expectEqual(stitch, fixture.target(fixture.nth(.variable_reference, 2)));
    // Gathers: the story's closing one first, then `later`.
    const later = fixture.nth(.gather, 1);
    try std.testing.expectEqual(later, fixture.target(fixture.nth(.variable_reference, 4)));
    try std.testing.expectEqual(stitch, fixture.target(fixture.nth(.divert, 0)));
    try std.testing.expectEqual(stitch, fixture.target(fixture.nth(.divert, 2)));
}

test "unresolved names produce diagnostics" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\-> nowhere
        \\{nope}
        \\~ missing = 1
        \\~ gone++
        \\{a.b}
        \\
    );
    defer fixture.deinit();
    const expected = [_]Code{
        .target_not_found,
        .unresolved_variable,
        .assignment_target_not_found,
        .increment_target_not_found,
        .read_count_target_not_found,
    };
    try std.testing.expectEqual(expected.len, fixture.codes().len);
    for (expected, fixture.codes()) |code, diagnostic| {
        try std.testing.expectEqual(code, diagnostic.code);
    }
}

test "parameters, divert parameters, constants, list items and functions" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\CONST c = 1
        \\LIST colours = red, green
        \\VAR v = red
        \\-> k(-> k2, 2)
        \\== k(-> next, n) ==
        \\{n} {c} {green} {colours.red} {f()}
        \\-> next
        \\== k2 ==
        \\-> DONE
        \\== function f ==
        \\~ return 1
        \\
    );
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.codes().len);
    const kinds = [_]Reference{ .list_item, .argument, .constant, .list_item, .list_item };
    for (kinds, 0..) |kind, position| {
        try std.testing.expectEqual(
            kind,
            fixture.reference(fixture.nth(.variable_reference, @intCast(position))),
        );
    }
    // `-> next` is a variable divert (a divert parameter).
    const diverts = fixture.resolution.variable_diverts;
    var variable_count: u32 = 0;
    for (0..fixture.tree.count()) |position| {
        variable_count += @intFromBool(diverts.isSet(position));
    }
    try std.testing.expectEqual(@as(u32, 1), variable_count);
    // The call targets the function.
    const function = fixture.nth(.knot, 2);
    const call = fixture.tree.children_of(fixture.nth(.function_call, 0))[0];
    try std.testing.expectEqual(function, fixture.target(call));
}

fn expect_fixture_resolves(comptime path: []const u8) !void {
    assert(path.len > 0);
    comptime assert(std.mem.endsWith(u8, path, ".ink"));
    const gpa = std.testing.allocator;
    const limit: std.Io.Limit = .limited(4 * 1024 * 1024);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
    defer gpa.free(source);
    var fixture: Fixture = undefined;
    try fixture.init(source);
    defer fixture.deinit();
    for (fixture.codes()) |diagnostic| {
        std.debug.print("{s}: {t} on a {t}\n", .{
            path,
            diagnostic.code,
            fixture.tree.kind(diagnostic.object),
        });
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.codes().len);
}

test "crime_scene.ink resolves without diagnostics, as inklecate compiles it" {
    try expect_fixture_resolves("test/fixture/crime_scene.ink");
}

test "simple_taster_tutorial.ink resolves without diagnostics, as inklecate compiles it" {
    try expect_fixture_resolves("test/fixture/simple_taster_tutorial.ink");
}

test "naming collisions, as ink's CheckForNamingCollisions" {
    // The six errors inklecate reports for this source, in its order (one per object).
    var fixture: Fixture = undefined;
    try fixture.init(
        \\VAR k = 1
        \\LIST l = a, b
        \\VAR a = 2
        \\-> k
        \\== k(x, x) ==
        \\~ temp x = 1
        \\- (k) label
        \\-> DONE
        \\== TURNS ==
        \\-> DONE
        \\
    );
    defer fixture.deinit();
    const Expected = struct { code: Code, kind: sema.Kind };
    const expected = [_]Expected{
        .{ .code = .name_conflict, .kind = .variable_assignment },
        .{ .code = .name_conflict, .kind = .variable_assignment },
        .{ .code = .name_conflict, .kind = .variable_assignment },
        .{ .code = .name_conflict, .kind = .gather },
        .{ .code = .duplicate_argument, .kind = .knot },
        .{ .code = .builtin_name, .kind = .knot },
    };
    try std.testing.expectEqual(expected.len, fixture.codes().len);
    for (expected, fixture.codes()) |want, got| {
        try std.testing.expectEqual(want.code, got.code);
        try std.testing.expectEqual(want.kind, fixture.tree.kind(got.object));
    }
}

test "a resolve error in an included file reports that file's line and column" {
    const gpa = std.testing.allocator;
    const source_space = @import("source_space.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const main_text = "INCLUDE other.ink\n-> k\n";
    const other_text = "== k ==\nText.\n  -> nowhere\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "main.ink", .data = main_text });
    try temporary.dir.writeFile(io, .{ .sub_path = "other.ink", .data = other_text });
    var space = try source_space.load(gpa, io, temporary.dir, "main.ink", .{});
    defer space.deinit(gpa);
    var tree = try sema.build_space_tree(gpa, &space);
    defer tree.deinit(gpa);
    var resolution = try resolve(gpa, &space.parsed, &tree);
    defer resolution.deinit(gpa);
    // `-> k` resolves to the included knot; `-> nowhere` doesn't.
    try std.testing.expectEqual(@as(usize, 1), resolution.diagnostics.len);
    const diagnostic = resolution.diagnostics[0];
    try std.testing.expectEqual(Code.target_not_found, diagnostic.code);
    const where = space.location(sema.object_offset(&space.parsed, &tree, diagnostic.object));
    try std.testing.expectEqualStrings("other.ink", where.path);
    try std.testing.expectEqual(@as(u32, 3), where.line);
    try std.testing.expectEqual(@as(u32, 6), where.column);
}

test "nested_include.ink resolves: the main file diverts to the included knot" {
    const gpa = std.testing.allocator;
    const source_space = @import("source_space.zig");
    const misc = "test/fixture/original/runtime/misc";
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, misc, .{});
    defer directory.close(std.testing.io);
    var space = try source_space.load(gpa, std.testing.io, directory, "nested_include.ink", .{});
    defer space.deinit(gpa);
    var tree = try sema.build_space_tree(gpa, &space);
    defer tree.deinit(gpa);
    var resolution = try resolve(gpa, &space.parsed, &tree);
    defer resolution.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), resolution.diagnostics.len);
}

test "constants may repeat only with the same value; list items may not repeat" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\CONST a = 1
        \\CONST a = 1
        \\CONST b = 2
        \\CONST b = 3
        \\LIST l = x, y, x
        \\{a} {b}
        \\
    );
    defer fixture.deinit();
    const expected = [_]Code{ .constant_redefined, .duplicate_list_item };
    try std.testing.expectEqual(expected.len, fixture.codes().len);
    for (expected, fixture.codes()) |code, diagnostic| {
        try std.testing.expectEqual(code, diagnostic.code);
    }
    // The list's items are numbered all the same: 1, 2, 3.
    const definition = fixture.nth(.list_definition, 0);
    for (fixture.tree.children_of(definition), 1..) |element, value| {
        try std.testing.expectEqual(
            @as(i32, @intCast(value)),
            fixture.resolution.item_values[element.to_int()],
        );
    }
}
