//! Builds sema.zig's object tree from the syntax tree, following ink's constructors (see
//! sema.zig). Weaves hold item runs of `items`: syntax nodes (with `statements` spliced in,
//! as ink's lists are flat) or the two objects ink synthesizes at the story's end. A nested
//! weave is a sub-run of its parent's run, so nesting copies nothing.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sema = @import("sema.zig");
const ast_module = @import("ast.zig");
const grammar = @import("grammar.zig");
const source_space = @import("source_space.zig");
const includes = @import("sema_includes.zig");
const Ast = ast_module.Ast;
const NodeIndex = ast_module.NodeIndex;
const Tag = ast_module.Tag;
const ObjectIndex = sema.ObjectIndex;
const Kind = sema.Kind;
const Flags = sema.Flags;

/// The story's closing `- ` gather and `-> DONE`, which have no syntax node.
const item_gather: u32 = std.math.maxInt(u32) - 1;
const item_done: u32 = std.math.maxInt(u32) - 2;
/// The "\n" ink adds after an included story's content.
const item_newline: u32 = std.math.maxInt(u32) - 3;
/// An INCLUDE node with this bit set stands for the included story's weave.
const item_included_weave: u32 = 1 << 31;

pub const Builder = struct {
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    /// The files of the compilation, for INCLUDE (none: a single file).
    space: ?*const source_space.Space = null,
    objects: std.MultiArrayList(sema.Object) = .empty,
    /// A weave's run of `items` and base indentation, by object (other objects: zeros).
    runs: std.ArrayList(Run) = .empty,
    children: std.ArrayList(ObjectIndex) = .empty,
    items: std.ArrayList(u32) = .empty,
    /// Objects whose children are still to be created.
    work: std.ArrayList(ObjectIndex) = .empty,

    const Run = struct { first: u32 = 0, count: u32 = 0, indent: u32 = 0 };

    pub fn deinit(builder: *Builder) void {
        const gpa = builder.gpa;
        builder.objects.deinit(gpa);
        builder.runs.deinit(gpa);
        builder.children.deinit(gpa);
        builder.items.deinit(gpa);
        builder.work.deinit(gpa);
    }

    fn tree(builder: *const Builder) *const Ast {
        return &builder.parsed.tree;
    }

    /// Creates the story and expands every object from a work list.
    pub fn run(builder: *Builder) !void {
        assert(builder.objects.len == 0);
        const story = try builder.create(.story, 0, .none, builder.tree().root);
        try builder.work.append(builder.gpa, story);
        var steps: u32 = 0;
        while (builder.work.pop()) |object| : (steps += 1) {
            assert(steps <= builder.objects.len);
            try builder.expand(object);
        }
        assert(builder.children.items.len + 1 == builder.objects.len);
    }

    pub fn finish(builder: *Builder) !sema.Tree {
        assert(builder.work.items.len == 0);
        assert(builder.runs.items.len == builder.objects.len);
        const children = try builder.children.toOwnedSlice(builder.gpa);
        return .{ .objects = builder.objects.toOwnedSlice(), .children = children };
    }

    /// A new object without children yet.
    fn create(
        builder: *Builder,
        kind: Kind,
        flags: u16,
        parent: ObjectIndex,
        node: NodeIndex,
    ) !ObjectIndex {
        const gpa = builder.gpa;
        const object: ObjectIndex = .from_int(@intCast(builder.objects.len));
        try builder.objects.append(gpa, .{
            .kind = kind,
            .flags = flags,
            .parent = parent,
            .node = node,
        });
        try builder.runs.append(gpa, .{});
        return object;
    }

    /// Adds a child (to the run being written for its parent) and queues it.
    fn adopt(builder: *Builder, child: ObjectIndex) !void {
        assert(!builder.objects.items(.parent)[child.to_int()].is_none());
        try builder.children.append(builder.gpa, child);
        try builder.work.append(builder.gpa, child);
    }

    fn add_child(builder: *Builder, parent: ObjectIndex, node: NodeIndex) !void {
        assert(!node.is_none());
        try builder.adopt(try builder.create_from_node(parent, node));
    }

    /// Creates `object`'s children, as ink's constructor for its kind does.
    fn expand(builder: *Builder, object: ObjectIndex) !void {
        const first: u32 = @intCast(builder.children.items.len);
        const node = builder.objects.items(.node)[object.to_int()];
        switch (builder.objects.items(.kind)[object.to_int()]) {
            .story, .knot, .stitch => try builder.expand_flow(object, node),
            .weave => try builder.expand_weave(object),
            .choice => try builder.expand_choice(object, node),
            .conditional => try builder.expand_conditional(object, node),
            .conditional_branch => try builder.expand_branch(object, node),
            .sequence => try builder.expand_sequence(object, node),
            .list_definition => {
                const elements = builder.tree().list(node);
                for (0..elements.count) |position| {
                    const element: NodeIndex = at(elements, position);
                    try builder.adopt(try builder.create(.list_element, 0, object, element));
                }
            },
            else => if (!node.is_none()) try builder.expand_by_tag(object, node),
        }
        const end: u32 = @intCast(builder.children.items.len);
        builder.objects.items(.children_first)[object.to_int()] = first;
        builder.objects.items(.children_count)[object.to_int()] = end - first;
    }

    /// FlowBase.SplitWeaveAndSubFlowContent: the weave first, then the sub-flows.
    fn expand_flow(builder: *Builder, flow: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        const is_story = ast.tag(node) == .story;
        const statements = if (is_story) ast.item(node, 0) else ast.slot(node, .statements);
        assert(ast.tag(statements) == .statements);
        const items_first: u32 = @intCast(builder.items.items.len);
        if (is_story) {
            try builder.append_story_items(statements);
            try builder.items.append(builder.gpa, item_gather);
            try builder.items.append(builder.gpa, item_done);
        } else try builder.append_items(statements, .weave_content);
        const items_count = @as(u32, @intCast(builder.items.items.len)) - items_first;
        if (items_count > 0) {
            try builder.adopt(try builder.create_weave(flow, items_first, items_count, 0));
        }
        const listed = ast.list(statements);
        for (0..listed.count) |position| {
            const item: NodeIndex = at(listed, position);
            if (is_flow_tag(ast.tag(item))) try builder.add_child(flow, item);
        }
        if (!is_story) return;
        const space = builder.space orelse return;
        var hoisted: std.ArrayList(NodeIndex) = .empty;
        defer hoisted.deinit(builder.gpa);
        try includes.hoisted_flows(builder.gpa, space, node, &hoisted);
        for (hoisted.items) |included_flow| try builder.add_child(flow, included_flow);
    }

    /// A story's top-level items: its own non-flow statements, with each INCLUDE replaced by
    /// what ink's PreProcessTopLevelObjects inserts for it.
    fn append_story_items(builder: *Builder, statements: NodeIndex) !void {
        const ast = builder.tree();
        assert(ast.tag(statements) == .statements);
        for (0..ast.list(statements).count) |position| {
            const item = ast.item(statements, position);
            if (ast.tag(item) != .include) {
                if (is_flow_tag(ast.tag(item))) continue;
                try builder.items.append(builder.gpa, item.to_int());
                continue;
            }
            const space = builder.space orelse continue;
            assert(item.to_int() < item_included_weave);
            switch (includes.contribution(space, item)) {
                .nothing => {},
                .newline => try builder.items.append(builder.gpa, item_newline),
                .weave_and_newline => {
                    try builder.items.append(builder.gpa, item.to_int() | item_included_weave);
                    try builder.items.append(builder.gpa, item_newline);
                },
            }
        }
    }

    /// The included story's weave, from its own top-level items.
    fn create_included_weave(
        builder: *Builder,
        parent: ObjectIndex,
        include: NodeIndex,
    ) !ObjectIndex {
        const space = builder.space.?;
        const story = space.included_story(include).?;
        const first: u32 = @intCast(builder.items.items.len);
        try builder.append_story_items(includes.statements_of(builder.tree(), story));
        const count = @as(u32, @intCast(builder.items.items.len)) - first;
        return builder.create_weave(parent, first, count, 0);
    }

    const Filter = enum { weave_content, all };

    /// Appends a list's items to `items`, splicing `statements` and skipping sub-flows.
    fn append_items(builder: *Builder, list_node: NodeIndex, filter: Filter) !void {
        const ast = builder.tree();
        assert(ast_module.shape(ast.tag(list_node)) == .list);
        const listed = ast.list(list_node);
        for (0..listed.count) |position| {
            const item: NodeIndex = at(listed, position);
            const tag = ast.tag(item);
            if (filter == .weave_content and is_flow_tag(tag)) continue;
            if (tag == .statements) {
                const inner = ast.list(item);
                for (0..inner.count) |offset| {
                    const spliced = inner.first.to_int() + @as(u32, @intCast(offset));
                    try builder.items.append(builder.gpa, spliced);
                }
            } else try builder.items.append(builder.gpa, item.to_int());
        }
    }

    fn create_weave(
        builder: *Builder,
        parent: ObjectIndex,
        first: u32,
        count: u32,
        indent: u32,
    ) !ObjectIndex {
        assert(count > 0);
        assert(first + count <= builder.items.items.len);
        const weave = try builder.create(.weave, 0, parent, .none);
        builder.runs.items[weave.to_int()] = .{ .first = first, .count = count, .indent = indent };
        return weave;
    }

    /// A weave with ink's DetermineBaseIndentationFromContent: the first weave point's.
    fn create_weave_determined(builder: *Builder, parent: ObjectIndex, first: u32) !ObjectIndex {
        const count = @as(u32, @intCast(builder.items.items.len)) - first;
        assert(count > 0);
        var indent: u32 = 0;
        for (builder.items.items[first..]) |item| {
            if (builder.weave_point_depth(item)) |depth| {
                indent = depth - 1;
                break;
            }
        }
        return builder.create_weave(parent, first, count, indent);
    }

    /// The indentation depth of a choice or gather item, or null.
    fn weave_point_depth(builder: *const Builder, item: u32) ?u32 {
        if (item == item_gather) return 1;
        if (item == item_done or item == item_newline) return null;
        if (item & item_included_weave != 0) return null;
        const ast = builder.tree();
        const node: NodeIndex = .from_int(item);
        switch (ast.tag(node)) {
            .choice, .sticky_choice, .gather => {
                const header = ast.data[ast.slot(node, .header).to_int()];
                assert(header & 0xffff > 0);
                return header & 0xffff;
            },
            else => return null,
        }
    }

    /// Weave.ConstructWeaveHierarchyFromIndentation over the weave's item run.
    fn expand_weave(builder: *Builder, weave: ObjectIndex) !void {
        const weave_run = builder.runs.items[weave.to_int()];
        const base = weave_run.indent;
        const first = weave_run.first;
        const end = first + weave_run.count;
        var position = first;
        while (position < end) {
            const item = builder.items.items[position];
            const depth = builder.weave_point_depth(item);
            if (depth != null and depth.? - 1 > base) {
                const inner_first = position;
                while (position < end) : (position += 1) {
                    const inner = builder.weave_point_depth(builder.items.items[position]);
                    if (inner != null and inner.? - 1 <= base) break;
                }
                const nested = try builder.create_weave(
                    weave,
                    inner_first,
                    position - inner_first,
                    depth.? - 1,
                );
                try builder.adopt(nested);
                continue;
            }
            try builder.adopt(try builder.create_item(weave, item));
            position += 1;
        }
        assert(position == end);
    }

    fn create_item(builder: *Builder, parent: ObjectIndex, item: u32) !ObjectIndex {
        if (item == item_gather) return builder.create(.gather, 0, parent, .none);
        if (item == item_done) return builder.create(.divert, Flags.done, parent, .none);
        if (item == item_newline) return builder.create(.text, Flags.newline, parent, .none);
        if (item & item_included_weave != 0) {
            return builder.create_included_weave(parent, .from_int(item & ~item_included_weave));
        }
        return builder.create_from_node(parent, .from_int(item));
    }

    /// Choice: start, choice-only and inner content (as present), then the condition.
    fn expand_choice(builder: *Builder, choice: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        assert(ast.tag(node) == .choice or ast.tag(node) == .sticky_choice);
        const contents = [_]NodeIndex{
            ast.slot(node, .start),
            ast.slot(node, .choice_only),
            ast.slot(node, .inner),
        };
        for (contents) |content| {
            if (ast.tag(content) != .none) try builder.add_child(choice, content);
        }
        const condition = ast.slot(node, .condition);
        if (ast.tag(condition) != .none) try builder.add_child(choice, condition);
    }

    /// Conditional: the initial condition (if any), then the branches.
    fn expand_conditional(builder: *Builder, conditional: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        const initial = ast.slot(node, .initial);
        if (ast.tag(initial) != .none) try builder.add_child(conditional, initial);
        const branches = ast.list(ast.slot(node, .branches));
        for (0..branches.count) |position| {
            const branch: NodeIndex = at(branches, position);
            try builder.add_child(conditional, branch);
        }
    }

    /// ConditionalSingleBranch: a weave of its content (if any), then its own condition (ink
    /// sets ownExpression after construction, so it comes last).
    fn expand_branch(builder: *Builder, branch: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        const is_else = ast.tag(node) == .else_branch;
        const content = ast.slot(node, .content);
        if (ast.tag(content) != .none) {
            const first: u32 = @intCast(builder.items.items.len);
            try builder.append_items(content, .all);
            if (builder.items.items.len > first) {
                try builder.adopt(try builder.create_weave_determined(branch, first));
            }
        }
        if (!is_else) {
            const condition = ast.slot(node, .condition);
            if (ast.tag(condition) != .none) try builder.add_child(branch, condition);
        }
    }

    /// Sequence: a weave per element, or the empty content list itself.
    fn expand_sequence(builder: *Builder, sequence: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        const elements = ast.list(ast.slot(node, .elements));
        for (0..elements.count) |position| {
            const element: NodeIndex = at(elements, position);
            assert(ast.tag(element) == .content_list);
            const first: u32 = @intCast(builder.items.items.len);
            try builder.append_items(element, .all);
            if (builder.items.items.len == first) {
                try builder.adopt(try builder.create(.content_list, 0, sequence, element));
            } else try builder.adopt(try builder.create_weave_determined(sequence, first));
        }
    }

    /// The children of the other kinds, from their syntax node's shape.
    fn expand_by_tag(builder: *Builder, object: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        switch (ast.tag(node)) {
            .content_list, .string, .conditions => {
                const listed = ast.list(node);
                for (0..listed.count) |position| {
                    const item: NodeIndex = at(listed, position);
                    if (ast.tag(item) == .statements) {
                        const inner = ast.list(item);
                        for (0..inner.count) |offset| {
                            try builder.add_child(
                                object,
                                at(inner, offset),
                            );
                        }
                    } else try builder.add_child(object, item);
                }
            },
            else => try builder.expand_fixed(object, node),
        }
    }

    fn expand_fixed(builder: *Builder, object: ObjectIndex, node: NodeIndex) !void {
        const ast = builder.tree();
        const tag = ast.tag(node);
        switch (tag) {
            .divert, .tunnel, .thread, .function_call => {
                if (builder.objects.items(.kind)[object.to_int()] == .function_call) {
                    // ink's proxy divert carries the call's arguments.
                    const proxy = try builder.create(.divert, Flags.function_call, object, node);
                    return builder.adopt(proxy);
                }
                const arguments = ast.slot(node, .arguments);
                if (ast.tag(arguments) == .none) return;
                const listed = ast.list(arguments);
                for (0..listed.count) |position| {
                    try builder.add_child(
                        object,
                        at(listed, position),
                    );
                }
            },
            .tunnel_onwards, .@"return", .divert_target, .negate, .not => {
                const inner = ast.slot(node, .inner);
                if (ast.tag(inner) != .none) try builder.add_child(object, inner);
            },
            .temp_declaration, .assignment, .variable_declaration, .const_declaration => {
                const value = ast.slot(node, .value);
                const absent = ast.tag(value) == .none or ast.tag(value) == .missing;
                if (!absent) try builder.add_child(object, value);
            },
            .add_assignment, .subtract_assignment => {
                const value = ast.slot(node, .value);
                if (ast.tag(value) != .missing) try builder.add_child(object, value);
            },
            .list_declaration => {
                const items = ast.slot(node, .items);
                try builder.adopt(try builder.create(.list_definition, 0, object, items));
            },
            else => if (ast_module.shape(tag) == .fixed and is_binary(tag)) {
                try builder.add_child(object, ast.slot(node, .left));
                try builder.add_child(object, ast.slot(node, .right));
            },
        }
    }

    /// The object for a syntax node: its kind and flags (ink's class for it). `{x}` is the
    /// expression itself, output when complete; `~ f()` is the call, its value dropped.
    fn create_from_node(
        builder: *Builder,
        parent: ObjectIndex,
        node_initial: NodeIndex,
    ) !ObjectIndex {
        const ast = builder.tree();
        var node = node_initial;
        var extra: u16 = 0;
        while (true) {
            switch (ast.tag(node)) {
                .inline_value => extra |= Flags.output,
                .call_statement => extra |= Flags.pop_result,
                else => break,
            }
            node = ast.slot(node, .inner);
        }
        const mapped = map_tag(ast.tag(node));
        return builder.create(mapped.kind, mapped.flags | extra, parent, node);
    }
};

const Mapped = struct { kind: Kind, flags: u16 = 0 };

/// ink's class for each syntax tag that makes an object; the tags not listed are the binary
/// operators.
const tag_map = map: {
    var map: std.EnumArray(Tag, Mapped) = .initFill(.{ .kind = .binary });
    const entries = [_]struct { Tag, Kind, u16 }{
        .{ .knot, .knot, 0 },
        .{ .function, .knot, Flags.function },
        .{ .stitch, .stitch, 0 },
        .{ .function_stitch, .stitch, Flags.function },
        .{ .choice, .choice, 0 },
        .{ .sticky_choice, .choice, Flags.sticky },
        .{ .gather, .gather, 0 },
        .{ .content_list, .content_list, 0 },
        .{ .text, .text, 0 },
        .{ .text_space, .text, 0 },
        .{ .error_text, .text, 0 },
        .{ .newline, .text, Flags.newline },
        .{ .glue, .glue, 0 },
        .{ .tag_start, .tag, Flags.tag_start },
        .{ .tag_end, .tag, 0 },
        .{ .divert, .divert, 0 },
        .{ .tunnel, .divert, Flags.tunnel },
        .{ .thread, .divert, Flags.thread },
        .{ .empty_divert, .divert, Flags.empty },
        .{ .tunnel_onwards, .tunnel_onwards, 0 },
        .{ .conditional, .conditional, 0 },
        .{ .inline_conditional, .conditional, Flags.inline_conditional },
        .{ .conditional_branch, .conditional_branch, 0 },
        .{ .else_branch, .conditional_branch, Flags.@"else" },
        .{ .sequence, .sequence, 0 },
        .{ .temp_declaration, .variable_assignment, Flags.new_temporary },
        .{ .assignment, .variable_assignment, 0 },
        .{ .variable_declaration, .variable_assignment, Flags.global },
        .{ .list_declaration, .variable_assignment, Flags.global | Flags.list },
        .{ .const_declaration, .constant_declaration, 0 },
        .{ .external_declaration, .external_declaration, 0 },
        .{ .@"return", .@"return", 0 },
        .{ .author_warning, .author_warning, 0 },
        .{ .include, .included_file, 0 },
        .{ .integer, .number, 0 },
        .{ .float, .number, 0 },
        .{ .true, .number, 0 },
        .{ .false, .number, 0 },
        .{ .string, .string_expression, 0 },
        .{ .variable_reference, .variable_reference, 0 },
        .{ .function_call, .function_call, 0 },
        .{ .divert_target, .divert_target, 0 },
        .{ .negate, .unary, 0 },
        .{ .not, .unary, 0 },
        .{ .increment, .increment, 0 },
        .{ .decrement, .increment, Flags.decrement },
        .{ .add_assignment, .increment, Flags.by_expression },
        .{ .subtract_assignment, .increment, Flags.by_expression | Flags.decrement },
        .{ .list_literal, .list_literal, 0 },
        .{ .conditions, .multiple_condition, 0 },
    };
    for (entries) |entry| map.set(entry[0], .{ .kind = entry[1], .flags = entry[2] });
    break :map map;
};

fn map_tag(tag: Tag) Mapped {
    assert(tag != .inline_value and tag != .call_statement);
    const mapped = tag_map.get(tag);
    assert(mapped.kind != .binary or is_binary(tag));
    return mapped;
}

/// Item `position` of a listed range (`Ast.list`).
fn at(items: anytype, position: usize) NodeIndex {
    assert(position < items.count);
    return .from_int(items.first.to_int() + @as(u32, @intCast(position)));
}

fn is_flow_tag(tag: Tag) bool {
    return tag == .knot or tag == .function or tag == .stitch or tag == .function_stitch;
}

fn is_binary(tag: Tag) bool {
    return switch (tag) {
        .add, .subtract, .multiply, .divide, .modulo, .equal, .not_equal, .less, .greater => true,
        .less_equal, .greater_equal, .@"and", .@"or", .has, .hasnt, .intersect => true,
        else => false,
    };
}
