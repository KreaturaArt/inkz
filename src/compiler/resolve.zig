//! Name resolution on the object tree, as ink does it in two phases:
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
const lookups = @import("resolve_lookups.zig");
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

/// What a divert resolved to; lowering generates it from this.
pub const DivertKind = enum(u8) {
    /// Not a divert, or `->` alone (an empty divert).
    none,
    /// Content found by its path (`targets` holds it; none if not found).
    target,
    /// A variable or parameter holds the target (ink's variableDivertName).
    variable,
    /// A call to an EXTERNAL function (ink's isExternal).
    external,
    end,
    done,
    /// A built-in call's or a list constructor's proxy: ink never generates or resolves it.
    skipped,
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
    /// DivertTarget.ResolveReferences: "Can't use -> DONE or -> END as variable divert
    /// targets".
    done_or_end_as_value,
    /// `->-> END` or `->-> DONE` (inklecate crashes on it): "Can't use '->-> END' or
    /// '->-> DONE': a tunnel can only return onwards to a knot, stitch or label. Write
    /// '->->' and then '-> END' instead".
    tunnel_onwards_to_end_or_done,
    // Divert.CheckArgumentValidity, on the divert.
    /// "Divert target needs to be a knot or stitch in order to pass arguments".
    arguments_to_non_flow,
    /// "Divert target (k) doesn't take parameters".
    flow_takes_no_parameters,
    /// "Divert can't store arguments in a divert target variable".
    arguments_in_divert_target,
    /// "Divert to 'k' requires 1 arguments, but there weren't any passed to it" (also
    /// "but only got n" and "but got n"; "Function call ..." for a call).
    wrong_argument_count,
    /// On the argument: "Target 'k' expects a divert target for the parameter named -> x
    /// but saw 5".
    divert_target_argument_expected,
    /// "Divert Passing read count of 'k' instead of a divert target. You probably meant
    /// '-> k'".
    read_count_instead_of_divert_target,
    // Divert.GenerateRuntimeObject's arguments, on the divert.
    /// "Function call Expected variable name to pass by reference to 'ref a' but saw 5".
    reference_argument_not_variable,
    /// "Function call can't pass a read count by reference. 'k' is a knot/stitch/label, but
    /// 'f' requires the name of a VAR to be passed."
    read_count_by_reference,
    /// Divert.ResolveTargetContent, on the parameter's flow: "Since 'x' is used as a
    /// variable divert target (on line 3), it should be marked as: -> x".
    divert_parameter_unmarked,
    /// Divert.CheckExternalArgumentValidity: "Function call incorrect number of arguments
    /// sent to external function 'e'. Expected 1 but got 2".
    external_argument_count,
    // FunctionCall.GenerateIntoContainer, on the call.
    /// "POW should take 2 parameters", "FLOOR should take 1 parameter", "The TURNS()
    /// function shouldn't take any arguments", "RANDOM should take 2 parameters: a minimum
    /// and a maximum integer", "SEED_RANDOM should take 1 parameter - an integer seed",
    /// "LIST_RANGE should take 3 parameters - a list, a min and a max", "LIST_RANDOM should
    /// take 1 parameter - a list", and "The TURNS_SINCE() function should take one argument:
    /// a divert target to the target knot, stitch, gather or choice you want to check. e.g.
    /// TURNS_SINCE(-> myKnot)" (inklecate crashes on TURNS_SINCE(), SEED_RANDOM() and
    /// LIST_RANDOM() with no argument).
    builtin_argument_count,
    /// "RANDOM's minimum parameter should be an integer", "SEED_RANDOM's parameter should be
    /// an integer seed".
    builtin_argument_not_integer,
    /// "Can currently only construct a list from one integer (or an empty list from a given
    /// list definition)".
    list_from_more_than_one_value,
    ambiguous_list_item,
    global_refers_to_variable,
    duplicate_list_item,
    list_item_not_found,
    constant_redefined,
    /// BinaryExpression.ResolveReferences, on `not A ? B` (parentheses don't count): "Using
    /// 'not' or '!' here negates 'A' rather than the result of the '?' or 'has' operator. You
    /// need to add parentheses around the (A ? B) expression."
    negated_has_operand,
    /// DivertTarget.ResolveReferences, a divert-target value used other than as a value, a
    /// compared operand or TURNS_SINCE's argument: "Can't use a divert target like that. Did
    /// you intend to call '-> k' as a function: likeThis(), or check the read count:
    /// likeThis, with no arrows?"
    divert_target_misused,
    /// DivertTarget.ResolveReferences, on `-> x` for a variable `x`: "Since 'x' is a
    /// variable, it shouldn't be preceded by '->' here."
    variable_divert_target,
    /// FunctionCall.ResolveReferences, on the call `TURNS_SINCE(-> x)` or `READ_COUNT(-> x)`
    /// for a variable `x` (ink names TURNS_SINCE in both): "When
    /// getting the TURNS_SINCE() of a variable target, remove the '->' - i.e. it should just
    /// be TURNS_SINCE(x)".
    turns_since_variable_target,
    /// UnaryExpression.WithInner on a literal it can't fold, `- true` (inklecate throws
    /// "Unexpected operation or number type").
    unsupported_fold,
    // FlowBase.GenerateRuntimeObject's flow checks.
    function_is_stitch,
    function_has_stitch,
    function_has_divert,
    function_has_choice,
    return_outside_function,
    // Weave.ValidateTermination (lowering): a weave nested in a conditional or sequence.
    nested_choice_needs_divert,
    /// The same, for a conditional with one choice ("Choices with conditions should be
    /// written: '* {condition} choice'...").
    conditional_choice_syntax,
    /// A warning: "Apparent loose end exists where the flow runs out...".
    loose_end,
    /// FlowBase.GenerateRuntimeObject, on the later of two flows with one name: "Story
    /// already contains flow named 'k' (at line 2 of f.ink)".
    duplicate_flow,
    /// Story.CheckForNamingCollisions, a temp named like its flow's parameter: "temp '': Name
    /// has already been used for a argument to f on line 3 of f.ink" (ink prints the story's
    /// empty name).
    argument_name_conflict,
    /// FunctionCall.ResolveReferences, on TURNS_SINCE(-> x) or READ_COUNT(-> x) whose target
    /// isn't found: "Failed to find target for TURNS_SINCE: '-> x'".
    turns_since_target_not_found,
    /// FunctionCall.ResolveReferences, on READ_COUNT(k) of a knot, stitch or label: "Should be
    /// READ_COUNT(-> k). Usage without the '->' only makes sense for variable targets."
    count_without_arrow,
    /// IncDecExpression.ResolveReferences, `x++` inside an expression: "Can't use increment
    /// as sub-expression".
    increment_as_sub_expression,
    /// DivertTarget.ResolveReferences, `-> f` of a flow with a `ref` parameter: "Can't store a
    /// divert target to a knot or function that has by-reference arguments ('f' has 'ref x')."
    divert_target_to_reference_flow,
    /// A warning from List.GenerateIntoContainer: "Duplicate of item 'a' in list."
    duplicate_list_literal_item,

    pub fn is_warning(code: Code) bool {
        return code == .loose_end or code == .duplicate_list_literal_item;
    }

    /// Whether ink reports it through Story.Error, which keeps no one-error-per-object rule:
    /// it neither checks nor marks the object.
    pub fn reported_by_story(code: Code) bool {
        return switch (code) {
            .constant_redefined, .ambiguous_list_item, .duplicate_external => true,
            else => false,
        };
    }
};

pub const Diagnostic = struct {
    code: Code,
    object: ObjectIndex,
    /// The object a message points back to (the first declaration of a duplicate), or none.
    other: ObjectIndex = .none,
    /// A name the message prints that isn't the object's own (a repeated parameter's, a
    /// list item's), as a slice of the parsed source; empty if none.
    name: []const u8 = "",
    /// Counts the message prints (parameters expected and arguments given).
    numbers: [2]u32 = .{ 0, 0 },
};

/// What a diagnostic carries besides its code and object.
pub const Details = struct {
    other: ObjectIndex = .none,
    name: []const u8 = "",
    numbers: [2]u32 = .{ 0, 0 },
};

pub const Resolution = struct {
    /// A divert's target content, a read count's target, a constant reference's
    /// declaration, a list item reference's element, a list constructor's definition.
    targets: []ObjectIndex,
    references: []Reference,
    /// Each divert's kind, by object.
    diverts: []DivertKind,
    /// A list item's value (ink's seriesValue), by object; 0 for other objects.
    item_values: []i32,
    /// Each list literal's items, in order and without repeats: its run in `literal_items`
    /// starts at `literal_starts[literal]` and ends at a `.none`.
    literal_items: []ObjectIndex,
    literal_starts: []u32,
    /// The list definitions in declaration order (ink's _listDefs).
    lists: []ObjectIndex,
    /// The EXTERNAL declarations, by name (at the root scope).
    externals: Table,
    diagnostics: []Diagnostic,

    /// Whether resolution found an error (warnings don't stop compilation).
    pub fn failed(resolution: *const Resolution) bool {
        for (resolution.diagnostics) |diagnostic| {
            if (!diagnostic.code.is_warning()) return true;
        }
        return false;
    }

    /// The list items a list literal names.
    pub fn list_literal_items(resolution: *const Resolution, literal: ObjectIndex) []ObjectIndex {
        const run = resolution.literal_items[resolution.literal_starts[literal.to_int()]..];
        return run[0..std.mem.indexOfScalar(ObjectIndex, run, .none).?];
    }

    pub fn deinit(resolution: *Resolution, gpa: Allocator) void {
        resolution.externals.deinit(gpa);
        gpa.free(resolution.targets);
        gpa.free(resolution.references);
        gpa.free(resolution.item_values);
        gpa.free(resolution.literal_items);
        gpa.free(resolution.literal_starts);
        gpa.free(resolution.lists);
        gpa.free(resolution.diverts);
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
        return std.hash.Wyhash.hash(@backingInt(key.scope), key.name);
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
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
        return path.components[0];
    }

    pub fn is_single(path: *const Path, name: []const u8) bool {
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
    literal_items: std.ArrayList(ObjectIndex) = .empty,
    literal_starts: []u32 = &.{},
    diverts: []DivertKind = &.{},
    /// Objects that already have an error or a warning (ink's _alreadyHadError and
    /// _alreadyHadWarning).
    had_error: std.DynamicBitSetUnmanaged = .{},
    had_warning: std.DynamicBitSetUnmanaged = .{},
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(context: *Context) void {
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
        context.literal_items.deinit(gpa);
        gpa.free(context.literal_starts);
        gpa.free(context.diverts);
        context.had_error.deinit(gpa);
        context.had_warning.deinit(gpa);
        context.diagnostics.deinit(gpa);
    }

    pub fn ast(context: *const Context) *const ast_module.Ast {
        return &context.parsed.tree;
    }

    /// The name in an object's syntax node child `position` (an identifier leaf).
    /// The text of slot `which` of the object's node (its name, mostly).
    pub fn slot_name(
        context: *const Context,
        object: ObjectIndex,
        comptime which: ast_module.Slot,
    ) []const u8 {
        return context.parsed.slot_text(context.tree.node(object), which);
    }

    /// Records an error on `object`; as in ink, an object gets at most one.
    pub fn report(context: *Context, code: Code, object: ObjectIndex) !void {
        return context.report_with(code, object, .none);
    }

    /// `report`, with the object the message points back to.
    pub fn report_with(
        context: *Context,
        code: Code,
        object: ObjectIndex,
        other: ObjectIndex,
    ) !void {
        return context.report_details(code, object, .{ .other = other });
    }

    /// `report`, with what the message prints besides the object. As ink's Object.Error,
    /// an object gets one error at most.
    pub fn report_details(
        context: *Context,
        code: Code,
        object: ObjectIndex,
        details: Details,
    ) !void {
        // A global VAR's duplicate goes through Story.Error too (its scope is the story).
        const by_story = code.reported_by_story() or (code == .duplicate_declaration and
            context.tree.has(object, sema.Flags.global));
        if (code.is_warning()) {
            if (context.had_warning.isSet(object.to_int())) return;
            context.had_warning.set(object.to_int());
        } else if (!by_story) {
            if (context.had_error.isSet(object.to_int())) return;
            context.had_error.set(object.to_int());
        }
        try context.diagnostics.append(context.gpa, .{
            .code = code,
            .object = object,
            .other = details.other,
            .name = details.name,
            .numbers = details.numbers,
        });
    }

    pub fn level(context: *const Context, flow: ObjectIndex) FlowLevel {
        assert(context.tree.is_flow(flow));
        return switch (context.tree.kind(flow)) {
            .story => .story,
            .knot => .knot,
            else => .stitch,
        };
    }

    /// A flow's name (empty for the story).
    pub fn flow_name(context: *const Context, flow: ObjectIndex) []const u8 {
        assert(context.tree.is_flow(flow));
        if (context.tree.kind(flow) == .story) return "";
        return context.slot_name(flow, .name);
    }

    /// A choice's or gather's label (empty if it has none).
    pub fn label(context: *const Context, point: ObjectIndex) []const u8 {
        const kind = context.tree.kind(point);
        assert(kind == .choice or kind == .gather);
        const node = context.tree.node(point);
        if (node.is_none()) return "";
        return context.parsed.slot_text(node, .label);
    }

    /// The flow's parameters, as their identifier leaves.
    pub fn parameters(context: *const Context, flow: ObjectIndex) []const ast_module.Tag {
        assert(context.tree.is_flow(flow));
        if (context.tree.kind(flow) == .story) return &.{};
        const list_node = context.ast().slot(context.tree.node(flow), .parameters);
        if (context.ast().tag(list_node) == .none) return &.{};
        const listed = context.ast().list(list_node);
        return context.ast().tags[listed.first.to_int()..][0..listed.count];
    }

    /// The name of parameter `position` of `flow`.
    pub fn parameter_name(context: *const Context, flow: ObjectIndex, position: u32) []const u8 {
        const list_node = context.ast().slot(context.tree.node(flow), .parameters);
        const listed = context.ast().list(list_node);
        assert(position < listed.count);
        return context.parsed.leaf_text(.from_int(listed.first.to_int() + position));
    }

    /// The components of a `path` node.
    pub fn path_of(context: *const Context, path_node: NodeIndex) Path {
        assert(context.ast().tag(path_node) == .path);
        const listed = context.ast().list(path_node);
        var path: Path = .{};
        for (0..@min(listed.count, path_components_max)) |position| {
            const component = context.ast().item(path_node, position);
            path.components[position] = context.parsed.leaf_text(component);
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
        return table.get(.{ .scope = scope, .name = name });
    }
};

/// Resolves every name of `tree`.
pub fn resolve(gpa: Allocator, parsed: *const grammar.Parsed, tree: *const Tree) !Resolution {
    assert(tree.kind(Tree.root) == .story);
    var context: Context = .{ .gpa = gpa, .parsed = parsed, .tree = tree };
    defer context.deinit();
    try lookups.prepare(&context);
    // The passes index the per-object tables by object without checking their length.
    assert(context.targets.len == tree.count());
    assert(context.references.len == tree.count());
    assert(context.root_weaves.len == tree.count());
    try passes.generation_pass(&context);
    try passes.references_pass(&context);
    const resolution: Resolution = .{
        .targets = context.targets,
        .references = context.references,
        .diverts = context.diverts,
        .item_values = context.item_values,
        .literal_items = try context.literal_items.toOwnedSlice(gpa),
        .literal_starts = context.literal_starts,
        .lists = try context.list_order.toOwnedSlice(gpa),
        .externals = context.externals,
        .diagnostics = try context.diagnostics.toOwnedSlice(gpa),
    };
    context.externals = .empty;
    context.targets = &.{};
    context.references = &.{};
    context.item_values = &.{};
    context.literal_starts = &.{};
    context.diverts = &.{};
    assert(resolution.targets.len == tree.count());
    return resolution;
}

// Tests.

const Fixture = struct {
    parsed: grammar.Parsed,
    tree: Tree,
    resolution: Resolution,

    fn init(fixture: *Fixture, source: []const u8) !void {
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
        const gpa = std.testing.allocator;
        fixture.resolution.deinit(gpa);
        fixture.tree.deinit(gpa);
        fixture.parsed.deinit(gpa);
    }

    /// The `nth` object of `kind` in tree order (pre-order).
    fn nth(fixture: *const Fixture, kind: sema.Kind, nth_wanted: u32) ObjectIndex {
        var objects = fixture.tree.walk(std.testing.allocator, Tree.root, .pre);
        defer objects.deinit();
        var seen: u32 = 0;
        while (objects.next() catch unreachable) |object| {
            if (fixture.tree.kind(object) != kind) continue;
            if (seen == nth_wanted) return object;
            seen += 1;
        }
        unreachable;
    }

    fn target(fixture: *const Fixture, object: ObjectIndex) ObjectIndex {
        return fixture.resolution.targets[object.to_int()];
    }

    fn reference(fixture: *const Fixture, object: ObjectIndex) Reference {
        return fixture.resolution.references[object.to_int()];
    }

    fn codes(fixture: *const Fixture) []const Diagnostic {
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
    var variable_count: u32 = 0;
    for (fixture.resolution.diverts) |kind| variable_count += @intFromBool(kind == .variable);
    try std.testing.expectEqual(@as(u32, 1), variable_count);
    // The call targets the function.
    const function = fixture.nth(.knot, 2);
    const call = fixture.tree.children_of(fixture.nth(.function_call, 0))[0];
    try std.testing.expectEqual(function, fixture.target(call));
}

fn expect_fixture_resolves(comptime path: []const u8) !void {
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
    // The six errors inklecate reports for this source, in its order (one per object). The
    // temp named like its knot's parameter is ink's argument variant.
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
        .{ .code = .argument_name_conflict, .kind = .variable_assignment },
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
    const offset = sema.object_offset(&space.parsed, &tree, diagnostic.object);
    const where = try space.locate(gpa, offset);
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
