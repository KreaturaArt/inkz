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
const Ast = ast_module.Ast;
const NodeIndex = ast_module.NodeIndex;
const Tag = ast_module.Tag;
const ObjectIndex = sema.ObjectIndex;
const Kind = sema.Kind;
const Flags = sema.Flags;

/// The story's closing `- ` gather and `-> DONE`, which have no syntax node.
const item_gather: u32 = std.math.maxInt(u32) - 1;
const item_done: u32 = std.math.maxInt(u32) - 2;

pub const Builder = struct {
    gpa: Allocator,
    parsed: *const grammar.Parsed,
    kinds: std.ArrayList(Kind) = .empty,
    flags: std.ArrayList(u16) = .empty,
    parents: std.ArrayList(ObjectIndex) = .empty,
    nodes: std.ArrayList(NodeIndex) = .empty,
    children_first: std.ArrayList(u32) = .empty,
    children_count: std.ArrayList(u32) = .empty,
    indents: std.ArrayList(u32) = .empty,
    /// A weave's run of `items` (other objects: 0, 0).
    items_first: std.ArrayList(u32) = .empty,
    items_count: std.ArrayList(u32) = .empty,
    children: std.ArrayList(ObjectIndex) = .empty,
    items: std.ArrayList(u32) = .empty,
    /// Objects whose children are still to be created.
    work: std.ArrayList(ObjectIndex) = .empty,

    pub fn deinit(builder: *Builder) void {
        assert(builder.children.items.len <= builder.kinds.items.len);
        const gpa = builder.gpa;
        assert(builder.kinds.items.len == builder.parents.items.len);
        builder.kinds.deinit(gpa);
        builder.flags.deinit(gpa);
        builder.parents.deinit(gpa);
        builder.nodes.deinit(gpa);
        builder.children_first.deinit(gpa);
        builder.children_count.deinit(gpa);
        builder.indents.deinit(gpa);
        builder.items_first.deinit(gpa);
        builder.items_count.deinit(gpa);
        builder.children.deinit(gpa);
        builder.items.deinit(gpa);
        builder.work.deinit(gpa);
    }

    fn tree(builder: *const Builder) *const Ast {
        assert(builder.parsed.tree.tags.len > 0);
        assert(builder.parsed.tree.tags.len == builder.parsed.tree.data.len);
        return &builder.parsed.tree;
    }

    /// Creates the story and expands every object, breadth-first.
    pub fn run(builder: *Builder) !void {
        assert(builder.kinds.items.len == 0);
        const story = try builder.create(.story, 0, .none, builder.tree().root);
        try builder.work.append(builder.gpa, story);
        var steps: u32 = 0;
        while (builder.work.pop()) |object| : (steps += 1) {
            assert(steps <= builder.kinds.items.len);
            try builder.expand(object);
        }
        assert(builder.children.items.len + 1 == builder.kinds.items.len);
    }

    pub fn finish(builder: *Builder) !sema.Tree {
        const gpa = builder.gpa;
        assert(builder.work.items.len == 0);
        assert(builder.kinds.items.len > 0);
        return .{
            .kinds = try builder.kinds.toOwnedSlice(gpa),
            .flags = try builder.flags.toOwnedSlice(gpa),
            .parents = try builder.parents.toOwnedSlice(gpa),
            .nodes = try builder.nodes.toOwnedSlice(gpa),
            .children_first = try builder.children_first.toOwnedSlice(gpa),
            .children_count = try builder.children_count.toOwnedSlice(gpa),
            .children = try builder.children.toOwnedSlice(gpa),
            .indents = try builder.indents.toOwnedSlice(gpa),
        };
    }

    /// A new object without children yet.
    fn create(
        builder: *Builder,
        kind: Kind,
        flags: u16,
        parent: ObjectIndex,
        node: NodeIndex,
    ) !ObjectIndex {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const gpa = builder.gpa;
        const object: ObjectIndex = .from_int(@intCast(builder.kinds.items.len));
        try builder.kinds.append(gpa, kind);
        try builder.flags.append(gpa, flags);
        try builder.parents.append(gpa, parent);
        try builder.nodes.append(gpa, node);
        try builder.children_first.append(gpa, 0);
        try builder.children_count.append(gpa, 0);
        try builder.indents.append(gpa, 0);
        try builder.items_first.append(gpa, 0);
        try builder.items_count.append(gpa, 0);
        assert(builder.kinds.items.len == builder.items_count.items.len);
        return object;
    }

    /// Adds a child (to the run being written for its parent) and queues it.
    fn adopt(builder: *Builder, child: ObjectIndex) !void {
        assert(!builder.parents.items[child.to_int()].is_none());
        try builder.children.append(builder.gpa, child);
        try builder.work.append(builder.gpa, child);
        assert(builder.children.items.len > 0);
    }

    fn add_child(builder: *Builder, parent: ObjectIndex, node: NodeIndex) !void {
        assert(!node.is_none());
        assert(parent.to_int() < builder.kinds.items.len);
        try builder.adopt(try builder.create_from_node(parent, node));
    }

    /// Creates `object`'s children, as ink's constructor for its kind does.
    fn expand(builder: *Builder, object: ObjectIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        assert(builder.children.items.len <= builder.kinds.items.len);
        const first: u32 = @intCast(builder.children.items.len);
        const node = builder.nodes.items[object.to_int()];
        switch (builder.kinds.items[object.to_int()]) {
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
        builder.children_first.items[object.to_int()] = first;
        const end: u32 = @intCast(builder.children.items.len);
        builder.children_count.items[object.to_int()] = end - first;
    }

    /// FlowBase.SplitWeaveAndSubFlowContent: the weave first, then the sub-flows.
    fn expand_flow(builder: *Builder, flow: ObjectIndex, node: NodeIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const ast = builder.tree();
        const statements = if (ast.tag(node) == .story)
            ast.list(node).first
        else
            ast.child(node, 2);
        assert(ast.tag(statements) == .statements);
        const items_first: u32 = @intCast(builder.items.items.len);
        try builder.append_items(statements, .weave_content);
        if (builder.kinds.items[flow.to_int()] == .story) {
            try builder.items.append(builder.gpa, item_gather);
            try builder.items.append(builder.gpa, item_done);
        }
        const items_count = @as(u32, @intCast(builder.items.items.len)) - items_first;
        if (items_count > 0) {
            try builder.adopt(try builder.create_weave(flow, items_first, items_count, 0));
        }
        const listed = ast.list(statements);
        for (0..listed.count) |position| {
            const item: NodeIndex = at(listed, position);
            if (is_flow_tag(ast.tag(item))) try builder.add_child(flow, item);
        }
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
        assert(builder.items.items.len < std.math.maxInt(u32));
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
        builder.indents.items[weave.to_int()] = indent;
        builder.items_first.items[weave.to_int()] = first;
        builder.items_count.items[weave.to_int()] = count;
        return weave;
    }

    /// A weave with ink's DetermineBaseIndentationFromContent: the first weave point's.
    fn create_weave_determined(builder: *Builder, parent: ObjectIndex, first: u32) !ObjectIndex {
        assert(builder.kinds.items.len == builder.parents.items.len);
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
        assert(builder.kinds.items.len == builder.parents.items.len);
        if (item == item_gather) return 1;
        if (item == item_done) return null;
        const ast = builder.tree();
        const node: NodeIndex = .from_int(item);
        switch (ast.tag(node)) {
            .choice, .sticky_choice, .gather => {
                const header = ast.data[ast.child(node, 0).to_int()];
                assert(header & 0xffff > 0);
                return header & 0xffff;
            },
            else => return null,
        }
    }

    /// Weave.ConstructWeaveHierarchyFromIndentation over the weave's item run.
    fn expand_weave(builder: *Builder, weave: ObjectIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const base = builder.indents.items[weave.to_int()];
        const first = builder.items_first.items[weave.to_int()];
        const end = first + builder.items_count.items[weave.to_int()];
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
        assert(builder.kinds.items.len == builder.parents.items.len);
        assert(parent.to_int() < builder.kinds.items.len);
        if (item == item_gather) return builder.create(.gather, 0, parent, .none);
        if (item == item_done) return builder.create(.divert, Flags.done, parent, .none);
        return builder.create_from_node(parent, .from_int(item));
    }

    /// Choice: start, choice-only and inner content (as present), then the condition.
    fn expand_choice(builder: *Builder, choice: ObjectIndex, node: NodeIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const ast = builder.tree();
        assert(ast.tag(node) == .choice or ast.tag(node) == .sticky_choice);
        for ([_]u32{ 3, 4, 5 }) |position| {
            const content = ast.child(node, position);
            if (ast.tag(content) != .none) try builder.add_child(choice, content);
        }
        const condition = ast.child(node, 2);
        if (ast.tag(condition) != .none) try builder.add_child(choice, condition);
    }

    /// Conditional: the initial condition (if any), then the branches.
    fn expand_conditional(builder: *Builder, conditional: ObjectIndex, node: NodeIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const ast = builder.tree();
        const initial = ast.child(node, 0);
        if (ast.tag(initial) != .none) try builder.add_child(conditional, initial);
        const branches = ast.list(ast.child(node, 1));
        for (0..branches.count) |position| {
            const branch: NodeIndex = at(branches, position);
            try builder.add_child(conditional, branch);
        }
        assert(ast.tag(ast.child(node, 1)) == .branches);
    }

    /// ConditionalSingleBranch: a weave of its content (if any), then its own condition (ink
    /// sets ownExpression after construction, so it comes last).
    fn expand_branch(builder: *Builder, branch: ObjectIndex, node: NodeIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        assert(builder.children.items.len <= builder.kinds.items.len);
        const ast = builder.tree();
        const is_else = ast.tag(node) == .else_branch;
        const content = ast.child(node, if (is_else) 0 else 1);
        if (ast.tag(content) != .none) {
            const first: u32 = @intCast(builder.items.items.len);
            try builder.append_items(content, .all);
            if (builder.items.items.len > first) {
                try builder.adopt(try builder.create_weave_determined(branch, first));
            }
        }
        if (!is_else) {
            const condition = ast.child(node, 0);
            if (ast.tag(condition) != .none) try builder.add_child(branch, condition);
        }
    }

    /// Sequence: a weave per element, or the empty content list itself.
    fn expand_sequence(builder: *Builder, sequence: ObjectIndex, node: NodeIndex) !void {
        assert(builder.kinds.items.len == builder.parents.items.len);
        const ast = builder.tree();
        const elements = ast.list(ast.child(node, 1));
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
        assert(builder.kinds.items.len == builder.parents.items.len);
        assert(builder.children.items.len <= builder.kinds.items.len);
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
        assert(builder.kinds.items.len == builder.parents.items.len);
        assert(builder.children.items.len <= builder.kinds.items.len);
        const ast = builder.tree();
        const tag = ast.tag(node);
        switch (tag) {
            .divert, .tunnel, .thread, .function_call => {
                if (builder.kinds.items[object.to_int()] == .function_call) {
                    // ink's proxy divert carries the call's arguments.
                    const proxy = try builder.create(.divert, Flags.function_call, object, node);
                    return builder.adopt(proxy);
                }
                const arguments = ast.child(node, 1);
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
                const inner = ast.child(node, 0);
                if (ast.tag(inner) != .none) try builder.add_child(object, inner);
            },
            .temp_declaration, .assignment, .variable_declaration, .const_declaration => {
                const value = ast.child(node, 1);
                const absent = ast.tag(value) == .none or ast.tag(value) == .missing;
                if (!absent) try builder.add_child(object, value);
            },
            .add_assignment, .subtract_assignment => {
                const value = ast.child(node, 1);
                if (ast.tag(value) != .missing) try builder.add_child(object, value);
            },
            .list_declaration => {
                const items = ast.child(node, 1);
                try builder.adopt(try builder.create(.list_definition, 0, object, items));
            },
            else => if (ast_module.shape(tag) == .fixed and is_binary(tag)) {
                try builder.add_child(object, ast.child(node, 0));
                try builder.add_child(object, ast.child(node, 1));
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
        assert(builder.kinds.items.len == builder.parents.items.len);
        const ast = builder.tree();
        var node = node_initial;
        var extra: u16 = 0;
        while (true) {
            switch (ast.tag(node)) {
                .inline_value => extra |= Flags.output,
                .call_statement => extra |= Flags.pop_result,
                else => break,
            }
            node = ast.child(node, 0);
        }
        const mapped = map_tag(ast.tag(node));
        assert(ast.tag(node) != .inline_value);
        return builder.create(mapped.kind, mapped.flags | extra, parent, node);
    }
};

const Mapped = struct { kind: Kind, flags: u16 = 0 };

fn map_tag(tag: Tag) Mapped {
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    assert(tag != .inline_value and tag != .call_statement);
    return switch (tag) {
        .knot => .{ .kind = .knot },
        .function => .{ .kind = .knot, .flags = Flags.function },
        .stitch => .{ .kind = .stitch },
        .function_stitch => .{ .kind = .stitch, .flags = Flags.function },
        .choice => .{ .kind = .choice },
        .sticky_choice => .{ .kind = .choice, .flags = Flags.sticky },
        .gather => .{ .kind = .gather },
        .content_list => .{ .kind = .content_list },
        .text, .text_space, .error_text => .{ .kind = .text },
        .newline => .{ .kind = .text, .flags = Flags.newline },
        .glue => .{ .kind = .glue },
        .tag_start => .{ .kind = .tag, .flags = Flags.tag_start },
        .tag_end => .{ .kind = .tag },
        .divert => .{ .kind = .divert },
        .tunnel => .{ .kind = .divert, .flags = Flags.tunnel },
        .thread => .{ .kind = .divert, .flags = Flags.thread },
        .empty_divert => .{ .kind = .divert, .flags = Flags.empty },
        .tunnel_onwards => .{ .kind = .tunnel_onwards },
        .conditional => .{ .kind = .conditional },
        .inline_conditional => .{ .kind = .conditional, .flags = Flags.inline_conditional },
        .conditional_branch => .{ .kind = .conditional_branch },
        .else_branch => .{ .kind = .conditional_branch, .flags = Flags.@"else" },
        .sequence => .{ .kind = .sequence },
        else => map_tag_other(tag),
    };
}

fn map_tag_other(tag: Tag) Mapped {
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    return switch (tag) {
        .temp_declaration => .{ .kind = .variable_assignment, .flags = Flags.new_temporary },
        .assignment => .{ .kind = .variable_assignment },
        .variable_declaration => .{ .kind = .variable_assignment, .flags = Flags.global },
        .list_declaration => .{ .kind = .variable_assignment, .flags = Flags.global | Flags.list },
        .const_declaration => .{ .kind = .constant_declaration },
        .external_declaration => .{ .kind = .external_declaration },
        .@"return" => .{ .kind = .@"return" },
        .author_warning => .{ .kind = .author_warning },
        .include => .{ .kind = .included_file },
        .integer, .float, .true, .false => .{ .kind = .number },
        .string => .{ .kind = .string_expression },
        .variable_reference => .{ .kind = .variable_reference },
        .function_call => .{ .kind = .function_call },
        .divert_target => .{ .kind = .divert_target },
        .negate, .not => .{ .kind = .unary },
        .increment => .{ .kind = .increment },
        .decrement => .{ .kind = .increment, .flags = Flags.decrement },
        .add_assignment => .{ .kind = .increment, .flags = Flags.by_expression },
        .subtract_assignment => .{
            .kind = .increment,
            .flags = Flags.by_expression | Flags.decrement,
        },
        .list_literal => .{ .kind = .list_literal },
        .conditions => .{ .kind = .multiple_condition },
        else => {
            assert(is_binary(tag));
            return .{ .kind = .binary };
        },
    };
}

/// Item `position` of a listed range (`Ast.list`).
fn at(items: anytype, position: usize) NodeIndex {
    assert(position < items.count);
    assert(items.count < std.math.maxInt(u32));
    return .from_int(items.first.to_int() + @as(u32, @intCast(position)));
}

fn is_flow_tag(tag: Tag) bool {
    assert(@sizeOf(Tag) == 1);
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    return tag == .knot or tag == .function or tag == .stitch or tag == .function_stitch;
}

fn is_binary(tag: Tag) bool {
    assert(@sizeOf(Tag) == 1);
    assert(@backingInt(tag) < @typeInfo(Tag).@"enum".field_names.len);
    return switch (tag) {
        .add, .subtract, .multiply, .divide, .modulo, .equal, .not_equal, .less, .greater => true,
        .less_equal, .greater_equal, .@"and", .@"or", .has, .hasnt, .intersect => true,
        else => false,
    };
}
