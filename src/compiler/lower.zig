//! Lowering (plan §4.12, P8.4): the object tree to ink's runtime container tree (lower_ir.zig),
//! following each class's GenerateRuntimeObject, then ink's ExportRuntime: the "global decl"
//! container, `done`, FlattenContainersIn, and the path resolution of ResolveReferences
//! (lower_layout.zig), which also emits the result through ProgramBuilder.
//!
//! Generation is a post-order walk without recursion: an object's children are generated
//! before it, so each GenerateRuntimeObject finds its children's runtime objects ready.
//! Expressions are the exception, as in ink: a parent emits them into its own container
//! (GenerateIntoContainer, lower_expressions.zig), or wraps one in `ev ... /ev` when it uses
//! it as content.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const grammar = @import("grammar.zig");
const ast_module = @import("ast.zig");
const ir_module = @import("lower_ir.zig");
const weave = @import("lower_weave.zig");
const logic = @import("lower_logic.zig");
const expressions = @import("lower_expressions.zig");
const Tree = sema.Tree;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const Kind = sema.Kind;
const NodeIndex = ast_module.NodeIndex;
const Ir = ir_module.Ir;
const ContainerId = ir_module.ContainerId;
const Item = ir_module.Item;

/// An object's runtime object (ink's runtimeObject): nothing, a value the parent adds, or a
/// container.
pub const Result = union(enum) {
    none,
    /// An item not yet in any container.
    item: ir_module.ItemId,
    container: ContainerId,
};

pub const ListDefinition = struct { name: []const u8, items: []const ir_module.ListItem };

/// The lowered story, free of the object tree: what lay_out and emission read.
pub const Lowered = struct {
    ir: Ir,
    root: ContainerId,
    /// ink's listDefs: each list with its items' values (in the IR's arena).
    lists: []const ListDefinition,

    pub fn deinit(lowered: *Lowered) void {
        assert(!lowered.root.is_none());
        assert(lowered.lists.len < std.math.maxInt(u32));
        lowered.ir.deinit();
        lowered.* = undefined;
    }
};

pub const Lowering = struct {
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    tree: *const Tree,
    resolution: *const resolve.Resolution,
    ir: Ir,
    results: []Result,
    /// ink's containerForCounting and runtimePath: a flow's or gather's container, a choice's
    /// inner content container; none for other objects.
    runtime_containers: []ContainerId,
    /// Weave state that outlives a weave's generation (its loose ends go to an ancestor).
    weaves: weave.States,
    /// ink's countAllVisits compiler option: every flow, gather and choice counts visits.
    count_all_visits: bool = false,
    root: ContainerId = .none,
    /// ink's errors and warnings from lowering (the termination checks).
    diagnostics: std.ArrayList(resolve.Diagnostic) = .empty,

    pub fn init(
        gpa: Allocator,
        parsed: *const grammar.Parsed,
        tree: *const Tree,
        resolution: *const resolve.Resolution,
    ) !Lowering {
        assert(resolution.targets.len == tree.count());
        assert(parsed.tree.tags.len > 0);
        const results = try gpa.alloc(Result, tree.count());
        errdefer gpa.free(results);
        @memset(results, .none);
        const runtime_containers = try gpa.alloc(ContainerId, tree.count());
        errdefer gpa.free(runtime_containers);
        @memset(runtime_containers, .none);
        return .{
            .gpa = gpa,
            .parsed = parsed,
            .tree = tree,
            .resolution = resolution,
            .ir = .init(gpa),
            .results = results,
            .runtime_containers = runtime_containers,
            .weaves = .init(gpa),
        };
    }

    pub fn deinit(lowering: *Lowering) void {
        assert(lowering.runtime_containers.len == lowering.tree.count());
        assert(lowering.results.len == lowering.tree.count());
        lowering.gpa.free(lowering.results);
        lowering.gpa.free(lowering.runtime_containers);
        lowering.weaves.deinit();
        lowering.diagnostics.deinit(lowering.gpa);
        lowering.ir.deinit();
        lowering.* = undefined;
    }

    /// The IR on its own, once flattened (plan P8.6): object targets become containers and the
    /// list definitions are copied out, so the object tree, the resolution and the syntax can
    /// be freed before emission. Everything but the IR is freed; on error nothing is.
    pub fn into_lowered(lowering: *Lowering) !Lowered {
        assert(lowering.results.len == lowering.tree.count());
        assert(!lowering.root.is_none());
        const arena = lowering.ir.arena.allocator();
        const resolution = lowering.resolution;
        const lists = try arena.alloc(ListDefinition, resolution.lists.len);
        for (resolution.lists, lists) |definition, *list| {
            const elements = lowering.tree.children_of(definition);
            const items = try arena.alloc(ir_module.ListItem, elements.len);
            const name = lowering.child_name(lowering.tree.parent(definition), 0);
            list.* = .{ .name = name, .items = items };
            for (elements, items) |element, *entry| entry.* = .{
                .origin = list.name,
                .name = lowering.child_name(element, 0),
                .value = resolution.item_values[element.to_int()],
            };
        }
        lowering.ir.resolve_objects(lowering.runtime_containers);
        lowering.ir.release_links();
        const lowered: Lowered = .{ .ir = lowering.ir, .root = lowering.root, .lists = lists };
        lowering.ir = .init(lowering.gpa);
        lowering.deinit();
        return lowered;
    }

    /// Records an error or a warning on `object`; as in ink, an object gets at most one of
    /// each.
    pub fn report(lowering: *Lowering, code: resolve.Code, object: ObjectIndex) !void {
        assert(object.to_int() < lowering.tree.count());
        assert(lowering.diagnostics.items.len < std.math.maxInt(u32));
        for (lowering.diagnostics.items) |diagnostic| {
            if (diagnostic.object != object) continue;
            if (diagnostic.code.is_warning() == code.is_warning()) return;
        }
        try lowering.diagnostics.append(lowering.gpa, .{ .code = code, .object = object });
    }

    /// Whether lowering found an error (warnings don't stop compilation).
    pub fn failed(lowering: *const Lowering) bool {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.diagnostics.items.len < std.math.maxInt(u32));
        for (lowering.diagnostics.items) |diagnostic| {
            if (!diagnostic.code.is_warning()) return true;
        }
        return false;
    }

    pub fn ast(lowering: *const Lowering) *const ast_module.Ast {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.parsed.tree.tags.len > 0);
        return &lowering.parsed.tree;
    }

    /// The name in an object's syntax node child `position` (an identifier leaf).
    pub fn child_name(lowering: *const Lowering, object: ObjectIndex, position: u32) []const u8 {
        return lowering.parsed.child_text(lowering.tree.node(object), position);
    }

    /// Whether `name` is an EXTERNAL function (ink's story.externals).
    pub fn is_external(lowering: *const Lowering, name: []const u8) bool {
        assert(name.len < std.math.maxInt(u32));
        return lowering.resolution.externals.contains(.{ .scope = Tree.root, .name = name });
    }

    /// Whether a divert is a built-in call's proxy, which ink never generates.
    pub fn resolution_skipped(lowering: *const Lowering, divert: ObjectIndex) bool {
        assert(lowering.results.len == lowering.tree.count());
        if (!lowering.tree.has(divert, Flags.function_call)) return false;
        const call = lowering.tree.parent(divert);
        assert(lowering.tree.kind(call) == .function_call);
        if (!lowering.resolution.targets[call.to_int()].is_none()) return true;
        return expressions.is_builtin_call(lowering.child_name(call, 0));
    }

    pub fn result(lowering: *const Lowering, object: ObjectIndex) Result {
        assert(object.to_int() < lowering.results.len);
        assert(lowering.results.len == lowering.tree.count());
        return lowering.results[object.to_int()];
    }

    /// Adds an object's runtime object to `container` (ink's AddContent(obj.runtimeObject)).
    pub fn add_result(lowering: *Lowering, container: ContainerId, object: ObjectIndex) !void {
        assert(lowering.results.len == lowering.tree.count());
        switch (lowering.result(object)) {
            .none => {},
            .item => |id| try lowering.ir.attach_or_copy(container, id),
            .container => |child| _ = try lowering.ir.add_container(container, child),
        }
        assert(container.to_int() < lowering.ir.containers.items.len);
    }

    /// The runtime object of an object used as content: an expression is wrapped in
    /// `ev ... /ev` (Expression.GenerateRuntimeObject).
    pub fn content_result(lowering: *Lowering, object: ObjectIndex) !Result {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        if (!is_expression(lowering.tree.kind(object))) return lowering.result(object);
        const container = try lowering.ir.new_container();
        _ = try lowering.ir.add_command(container, .eval_start);
        try expressions.emit(lowering, container, object);
        if (lowering.tree.has(object, Flags.output)) _ = try lowering.ir.add_command(
            container,
            .eval_output,
        );
        _ = try lowering.ir.add_command(container, .eval_end);
        return .{ .container = container };
    }

    pub fn add_content(lowering: *Lowering, container: ContainerId, object: ObjectIndex) !void {
        assert(lowering.results.len == lowering.tree.count());
        switch (try lowering.content_result(object)) {
            .none => {},
            .item => |id| try lowering.ir.attach_or_copy(container, id),
            .container => |child| _ = try lowering.ir.add_container(container, child),
        }
        assert(object.to_int() < lowering.tree.count());
    }

    /// Generates every object, children first.
    pub fn generate_all(lowering: *Lowering) !void {
        assert(lowering.results.len == lowering.tree.count());
        var objects = lowering.tree.walk(lowering.gpa, Tree.root, .post);
        defer objects.deinit();
        while (try objects.next()) |object| {
            lowering.results[object.to_int()] = try lowering.generate(object);
        }
    }

    /// One object's GenerateRuntimeObject.
    fn generate(lowering: *Lowering, object: ObjectIndex) !Result {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        const tree = lowering.tree;
        return switch (tree.kind(object)) {
            .story, .knot, .stitch => lowering.generate_flow(object),
            .weave => weave.generate_weave(lowering, object),
            .choice => weave.generate_choice(lowering, object),
            .gather => weave.generate_gather(lowering, object),
            .content_list => lowering.generate_content_list(object),
            .text => .{
                .item = try lowering.ir.new_item(.{ .text = try lowering.text_of(object) }),
            },
            .glue => .{ .item = try lowering.ir.new_item(.{ .command = .glue }) },
            .tag => {
                const is_start = tree.has(object, Flags.tag_start);
                const command: ir_module.Command = if (is_start) .begin_tag else .end_tag;
                return .{ .item = try lowering.ir.new_item(.{ .command = command }) };
            },
            .divert => logic.generate_divert(lowering, object),
            .tunnel_onwards => logic.generate_tunnel_onwards(lowering, object),
            .conditional => logic.generate_conditional(lowering, object),
            .conditional_branch => logic.generate_branch(lowering, object),
            .sequence => logic.generate_sequence(lowering, object),
            .variable_assignment => logic.generate_assignment(lowering, object),
            .@"return" => logic.generate_return(lowering, object),
            // These generate nothing (ink returns null), or only in the global declarations.
            .constant_declaration, .external_declaration, .included_file, .author_warning => .none,
            .list_definition, .list_element => .none,
            // Expressions are generated by the objects that use them.
            else => .none,
        };
    }

    /// ContentList.GenerateRuntimeObject.
    fn generate_content_list(lowering: *Lowering, list: ObjectIndex) !Result {
        assert(lowering.results.len == lowering.tree.count());
        const container = try lowering.ir.new_container();
        for (lowering.tree.children_of(list)) |child| try lowering.add_content(container, child);
        assert(lowering.tree.kind(list) == .content_list);
        return .{ .container = container };
    }

    /// A Text's text: the token without its `\` escapes; ink's "\n"s and its error text.
    fn text_of(lowering: *Lowering, object: ObjectIndex) ![]const u8 {
        assert(lowering.results.len == lowering.tree.count());
        const tree = lowering.tree;
        if (tree.has(object, Flags.newline) or tree.node(object).is_none()) return "\n";
        const node = tree.node(object);
        const tag = lowering.ast().tag(node);
        if (tag == .error_text) return "<ERROR IN FLOW>";
        const raw = lowering.parsed.leaf_text(node);
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            // Without escapes the text is the source itself; text_space's space usually is too.
            if (tag != .text_space) return raw;
            const source = lowering.parsed.source;
            const end = @intFromPtr(raw.ptr) - @intFromPtr(source.ptr) + raw.len;
            if (end < source.len and source[end] == ' ') return source[end - raw.len .. end + 1];
        }
        var buffer: std.ArrayList(u8) = .empty;
        const arena = lowering.ir.arena.allocator();
        var position: usize = 0;
        while (position < raw.len) : (position += 1) {
            if (raw[position] == '\\' and position + 1 < raw.len) position += 1;
            try buffer.append(arena, raw[position]);
        }
        if (tag == .text_space) try buffer.append(arena, ' ');
        assert(buffer.items.len <= raw.len + 1);
        return buffer.items;
    }

    /// FlowBase.GenerateRuntimeObject.
    fn generate_flow(lowering: *Lowering, flow: ObjectIndex) !Result {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        const tree = lowering.tree;
        const ir = &lowering.ir;
        const container = try ir.new_container();
        lowering.runtime_containers[flow.to_int()] = container;
        if (tree.kind(flow) != .story) ir.container(container).name = try ir.text(
            lowering.child_name(flow, 0),
        );
        if (lowering.count_all_visits) ir.container(container).flags |= ir_module.count_visits;
        try lowering.add_parameter_assignments(container, flow);
        const children = tree.children_of(flow);
        for (children, 0..) |child, position| {
            if (!tree.is_flow(child)) {
                try lowering.add_content(container, child);
                continue;
            }
            const sub_flow = lowering.runtime_containers[child.to_int()];
            // A knot that starts with a stitch diverts into it.
            if (position == 0 and tree.kind(flow) == .knot and !has_parameters(lowering, child)) {
                _ = try ir.add(container, .{ .divert = .{ .target = .{ .container = sub_flow } } });
            }
            try ir.add_named(container, sub_flow);
        }
        try weave.check_flow_termination(lowering, flow);
        return .{ .container = container };
    }

    fn add_parameter_assignments(
        lowering: *Lowering,
        container: ContainerId,
        flow: ObjectIndex,
    ) !void {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        if (lowering.tree.kind(flow) == .story) return;
        const parameters = lowering.ast().child(lowering.tree.node(flow), 1);
        if (lowering.ast().tag(parameters) == .none) return;
        var position = lowering.ast().list(parameters).count;
        while (position > 0) {
            position -= 1;
            const parameter = lowering.ast().item(parameters, position);
            const name = try lowering.ir.text(lowering.parsed.leaf_text(parameter));
            _ = try lowering.ir.add(
                container,
                .{ .assignment = .{ .name = name, .global = false, .new = true } },
            );
        }
    }

    /// Story.ExportRuntime after generation: the "global decl" container and `done`.
    pub fn finish_story(lowering: *Lowering) !void {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        const ir = &lowering.ir;
        const root = lowering.result(Tree.root).container;
        lowering.root = root;
        const declarations = try ir.new_container();
        _ = try ir.add_command(declarations, .eval_start);
        var any = false;
        var objects = lowering.tree.walk(lowering.gpa, Tree.root, .pre);
        defer objects.deinit();
        while (try objects.next()) |object| {
            any = try lowering.add_declaration(declarations, object) or any;
        }
        _ = try ir.add_command(declarations, .eval_end);
        _ = try ir.add_command(declarations, .end);
        if (any) {
            ir.container(declarations).name = "global decl";
            try ir.add_named(root, declarations);
        }
        _ = try ir.add_command(root, .done);
    }

    /// One entry of the story's variableDeclarations: true if the object declares one (a
    /// story-level temp counts for the name, but only globals are initialised).
    fn add_declaration(lowering: *Lowering, declarations: ContainerId, object: ObjectIndex) !bool {
        assert(lowering.results.len == lowering.tree.count());
        assert(lowering.runtime_containers.len == lowering.tree.count());
        const tree = lowering.tree;
        if (tree.kind(object) != .variable_assignment) return false;
        const is_global = tree.has(object, Flags.global);
        if (!is_global) {
            const at_story = tree.closest_flow(object) == Tree.root;
            return tree.has(object, Flags.new_temporary) and at_story;
        }
        const name = try lowering.ir.text(lowering.child_name(object, 0));
        if (tree.has(object, Flags.list)) {
            const definition = tree.children_of(object)[0];
            _ = try lowering.ir.add(
                declarations,
                try expressions.list_definition_value(lowering, definition, name),
            );
        } else if (tree.children_of(object).len > 0) {
            try expressions.emit(lowering, declarations, tree.children_of(object)[0]);
        }
        _ = try lowering.ir.add(
            declarations,
            .{ .assignment = .{ .name = name, .global = true, .new = true } },
        );
        return true;
    }
};

fn has_parameters(lowering: *const Lowering, flow: ObjectIndex) bool {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.tree.is_flow(flow));
    assert(lowering.tree.kind(flow) != .story);
    const parameters = lowering.ast().child(lowering.tree.node(flow), 1);
    return lowering.ast().tag(parameters) != .none and lowering.ast().list(parameters).count > 0;
}

pub fn is_expression(kind: Kind) bool {
    assert(@backingInt(kind) < @typeInfo(Kind).@"enum".field_names.len);
    return switch (kind) {
        .number, .string_expression, .variable_reference, .function_call, .divert_target => true,
        .binary, .unary, .increment, .list_literal, .multiple_condition => true,
        else => false,
    };
}
