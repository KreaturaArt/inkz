//! Generation of diverts, tunnels onwards, conditionals, sequences, assignments and returns
//! (ink's GenerateRuntimeObject for Divert, TunnelOnwards, Conditional,
//! ConditionalSingleBranch, Sequence, VariableAssignment and Return).

const std = @import("std");
const assert = std.debug.assert;
const lower = @import("lower.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const ast_module = @import("ast.zig");
const ir_module = @import("lower_ir.zig");
const expressions = @import("lower_expressions.zig");
const Lowering = lower.Lowering;
const Result = lower.Result;
const ObjectIndex = sema.ObjectIndex;
const Flags = sema.Flags;
const ContainerId = ir_module.ContainerId;
const ItemId = ir_module.ItemId;
const Item = ir_module.Item;

/// A divert's target path text, if it is END or DONE.
fn end_or_done(lowering: *const Lowering, divert: ObjectIndex) ?ir_module.Command {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const node = lowering.tree.node(divert);
    if (node.is_none()) return if (lowering.tree.has(divert, Flags.done)) .done else null;
    const ast = lowering.ast();
    if (ast.tag(node) == .function_call or ast.tag(node) == .empty_divert) return null;
    const path = ast.child(node, 0);
    if (ast.tag(path) != .path or ast.list(path).count != 1) return null;
    const name = lowering.parsed.leaf_text(ast.item(path, 0));
    if (std.mem.eql(u8, name, "END")) return .end;
    if (std.mem.eql(u8, name, "DONE")) return .done;
    return null;
}

/// The runtime divert of a divert object (its target and kind).
pub fn divert_item(lowering: *const Lowering, divert: ObjectIndex) ir_module.Divert {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const tree = lowering.tree;
    var result: ir_module.Divert = .{};
    if (tree.has(divert, Flags.function_call)) result.kind = .function;
    if (tree.has(divert, Flags.tunnel)) result.kind = .tunnel;
    const name = first_component(lowering, divert);
    if (lowering.resolution.variable_diverts.isSet(divert.to_int())) {
        result.variable = name;
        return result;
    }
    if (lowering.is_external(name)) {
        result.external = name;
        result.external_arguments = @intCast(tree.children_of(divert).len);
        return result;
    }
    const target = lowering.resolution.targets[divert.to_int()];
    if (!target.is_none()) result.target = .{ .object = target };
    return result;
}

fn first_component(lowering: *const Lowering, divert: ObjectIndex) []const u8 {
    assert(lowering.results.len == lowering.tree.count());
    const ast = lowering.ast();
    const node = lowering.tree.node(divert);
    assert(!node.is_none());
    if (ast.tag(node) == .function_call) return lowering.parsed.child_text(node, 0);
    const path = ast.child(node, 0);
    if (ast.tag(path) != .path) return "";
    return lowering.parsed.leaf_text(ast.item(path, 0));
}

/// Divert.GenerateRuntimeObject.
pub fn generate_divert(lowering: *Lowering, divert: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const tree = lowering.tree;
    if (tree.has(divert, Flags.empty)) return .none;
    if (lowering.resolution_skipped(divert)) return .none;
    if (end_or_done(lowering, divert)) |command| {
        return .{ .item = try lowering.ir.new_item(.{ .command = command }) };
    }
    const arguments = tree.children_of(divert);
    const is_call = tree.has(divert, Flags.function_call);
    const is_thread = tree.has(divert, Flags.thread);
    const runtime = divert_item(lowering, divert);
    if (arguments.len == 0 and !is_call and !tree.has(divert, Flags.tunnel) and !is_thread) {
        return .{ .item = try lowering.ir.new_item(.{ .divert = runtime }) };
    }
    const ir = &lowering.ir;
    const container = try ir.new_container();
    if (arguments.len > 0) {
        if (!is_call) _ = try ir.add_command(container, .eval_start);
        try add_arguments(lowering, container, divert);
        if (!is_call) _ = try ir.add_command(container, .eval_end);
    }
    if (is_thread) _ = try ir.add_command(container, .start_thread);
    _ = try ir.add(container, .{ .divert = runtime });
    return .{ .container = container };
}

/// A divert's arguments: a `ref` parameter gets a variable pointer, the rest their values.
pub fn add_arguments(lowering: *Lowering, container: ContainerId, divert: ObjectIndex) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const target = lowering.resolution.targets[divert.to_int()];
    for (lowering.tree.children_of(divert), 0..) |argument, position| {
        const to_flow = !target.is_none() and lowering.tree.is_flow(target);
        if (to_flow and is_reference_parameter(lowering, target, position)) {
            if (lowering.tree.kind(argument) == .variable_reference) {
                const name = try lowering.ir.text(expressions.reference_name(lowering, argument));
                _ = try lowering.ir.add(
                    container,
                    .{ .variable_pointer = .{ .name = name, .context = -1 } },
                );
                continue;
            }
        }
        try expressions.emit(lowering, container, argument);
    }
}

fn is_reference_parameter(lowering: *const Lowering, flow: ObjectIndex, position: usize) bool {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ast = lowering.ast();
    const parameters = ast.child(lowering.tree.node(flow), 1);
    if (ast.tag(parameters) == .none or position >= ast.list(parameters).count) return false;
    return ast.tag(ast.item(parameters, position)) == .reference_parameter;
}

/// TunnelOnwards.GenerateRuntimeObject: `->->`, maybe with a divert to take instead.
pub fn generate_tunnel_onwards(lowering: *Lowering, onwards: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const container = try ir.new_container();
    _ = try ir.add_command(container, .eval_start);
    const children = lowering.tree.children_of(onwards);
    if (children.len == 0) {
        _ = try ir.add_command(container, .void);
    } else {
        const after = children[0];
        try add_arguments(lowering, container, after);
        const runtime = divert_item(lowering, after);
        if (runtime.variable) |name| {
            _ = try ir.add(container, .{ .variable_reference = name });
        } else _ = try ir.add(container, .{ .divert_target = runtime.target });
    }
    _ = try ir.add_command(container, .eval_end);
    _ = try ir.add_command(container, .pop_tunnel);
    return .{ .container = container };
}

/// The flags ink's parser gives a branch (InnerConditionalContent).
const BranchFlags = struct {
    true_branch: bool = false,
    is_else: bool = false,
    matching: bool = false,
    is_inline: bool = false,
};

fn own_expression(lowering: *const Lowering, branch: ObjectIndex) ?ObjectIndex {
    assert(lowering.results.len == lowering.tree.count());
    for (lowering.tree.children_of(branch)) |child| {
        if (lower.is_expression(lowering.tree.kind(child))) return child;
    }
    assert(lowering.tree.kind(branch) == .conditional_branch);
    return null;
}

fn branch_flags(lowering: *const Lowering, branch: ObjectIndex) BranchFlags {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const tree = lowering.tree;
    const conditional = tree.parent(branch);
    const siblings = tree.children_of(conditional);
    const has_initial = lower.is_expression(tree.kind(siblings[0]));
    const branches = siblings[@intFromBool(has_initial)..];
    var flags: BranchFlags = .{ .is_inline = tree.has(conditional, Flags.inline_conditional) };
    if (flags.is_inline) {
        flags.true_branch = branches[0] == branch;
        flags.is_else = branches.len > 1 and branches[1] == branch;
        return flags;
    }
    var earlier_own = false;
    for (branches, 0..) |current, position| {
        const is_last = position == branches.len - 1;
        var current_flags: BranchFlags = .{ .is_else = tree.has(current, Flags.@"else") };
        if (has_initial) {
            if (own_expression(lowering, current) != null) {
                current_flags.matching = true;
                earlier_own = true;
            } else if (earlier_own and is_last) {
                current_flags.matching = true;
                current_flags.is_else = true;
            } else if (is_last or branches.len <= 2) {
                if (position == 0) {
                    current_flags.true_branch = true;
                } else current_flags.is_else = true;
            }
        } else if (own_expression(lowering, current) == null and is_last) {
            current_flags.is_else = true;
        }
        if (current == branch) return current_flags;
    }
    unreachable;
}

/// ConditionalSingleBranch.GenerateRuntimeObject: the test and divert, and the content `b`.
pub fn generate_branch(lowering: *Lowering, branch: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const flags = branch_flags(lowering, branch);
    const ir = &lowering.ir;
    const container = try ir.new_container();
    const duplicates = flags.matching and !flags.is_else;
    if (duplicates) _ = try ir.add_command(container, .duplicate);
    const own = own_expression(lowering, branch);
    if (!flags.true_branch and !flags.is_else) {
        if (own != null) _ = try ir.add_command(container, .eval_start);
        if (own) |expression| try expressions.emit(lowering, container, expression);
        if (flags.matching) _ = try ir.add(container, .{ .native = "==" });
        if (own != null) _ = try ir.add_command(container, .eval_end);
    }
    const content = branch_content(lowering, branch) orelse try ir.new_container();
    _ = try ir.add(
        container,
        .{ .divert = .{ .target = .{ .container = content }, .conditional = !flags.is_else } },
    );
    ir.container(content).name = "b";
    if (!flags.is_inline) _ = try ir.insert(content, 0, .{ .text = "\n" });
    if (duplicates or (flags.is_else and flags.matching)) _ = try ir.insert(content, 0, .{
        .command = .pop,
    });
    try ir.add_named(container, content);
    // Its target, the conditional's rejoin point, is set by the conditional.
    _ = try ir.add(content, .{ .divert = .{} });
    return .{ .container = container };
}

fn branch_content(lowering: *const Lowering, branch: ObjectIndex) ?ContainerId {
    assert(lowering.results.len == lowering.tree.count());
    for (lowering.tree.children_of(branch)) |child| {
        if (lowering.tree.kind(child) == .weave) return lowering.result(child).container;
    }
    assert(lowering.tree.kind(branch) == .conditional_branch);
    return null;
}

/// Conditional.GenerateRuntimeObject, with ResolveReferences' rejoin targets.
pub fn generate_conditional(lowering: *Lowering, conditional: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const tree = lowering.tree;
    const ir = &lowering.ir;
    const container = try ir.new_container();
    const children = tree.children_of(conditional);
    const has_initial = lower.is_expression(tree.kind(children[0]));
    if (has_initial) try lowering.add_content(container, children[0]);
    const branches = children[@intFromBool(has_initial)..];
    for (branches) |branch| try lowering.add_result(container, branch);
    const last_is_else = branch_flags(lowering, branches[branches.len - 1]).is_else;
    if (has_initial and own_expression(lowering, branches[0]) != null and !last_is_else) {
        _ = try ir.add_command(container, .pop);
    }
    const rejoin = try ir.add_command(container, .no_op);
    for (branches) |branch| {
        const content = ir.container(lowering.result(branch).container).named.items[0];
        ir.divert_of(ir.container(content).last).target = .{ .item = rejoin };
    }
    return .{ .container = container };
}

/// ink's SequenceType flags.
const stopping: u32 = 1;
const cycle: u32 = 2;
const shuffle: u32 = 4;
const once: u32 = 8;

/// Sequence.GenerateRuntimeObject.
pub fn generate_sequence(lowering: *Lowering, sequence: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const kind_leaf = lowering.ast().child(lowering.tree.node(sequence), 0);
    const kind = lowering.ast().data[kind_leaf.to_int()];
    const elements = lowering.tree.children_of(sequence);
    const container = try ir.new_container();
    ir.container(container).flags |= ir_module.count_visits | ir_module.count_start_only;
    _ = try ir.add_command(container, .eval_start);
    _ = try ir.add_command(container, .visit_index);
    const count: i32 = @intCast(elements.len);
    const branch_count = count + @intFromBool(kind & once != 0);
    if (kind & (stopping | once) != 0) {
        _ = try ir.add(container, .{ .integer = branch_count - 1 });
        _ = try ir.add(container, .{ .native = "MIN" });
    } else if (kind & cycle != 0) {
        _ = try ir.add(container, .{ .integer = count });
        _ = try ir.add(container, .{ .native = "%" });
    }
    if (kind & shuffle != 0) try add_shuffle(lowering, container, kind, count);
    _ = try ir.add_command(container, .eval_end);
    const after = try ir.new_item(.{ .command = .no_op });
    for (0..@intCast(branch_count)) |position| {
        try add_sequence_branch(lowering, container, elements, position, after);
    }
    try ir.attach(container, after);
    return .{ .container = container };
}

fn add_shuffle(lowering: *Lowering, container: ContainerId, kind: u32, count: i32) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const after_shuffle = try ir.new_item(.{ .command = .no_op });
    const skips = kind & (once | stopping) != 0;
    if (skips) {
        const last = if (kind & stopping != 0) count - 1 else count;
        _ = try ir.add_command(container, .duplicate);
        _ = try ir.add(container, .{ .integer = last });
        _ = try ir.add(container, .{ .native = "==" });
        _ = try ir.add(
            container,
            .{ .divert = .{ .target = .{ .item = after_shuffle }, .conditional = true } },
        );
    }
    const shuffled = if (kind & stopping != 0) count - 1 else count;
    _ = try ir.add(container, .{ .integer = shuffled });
    _ = try ir.add_command(container, .sequence_shuffle_index);
    if (skips) try ir.attach(container, after_shuffle);
}

fn add_sequence_branch(
    lowering: *Lowering,
    container: ContainerId,
    elements: []const ObjectIndex,
    position: usize,
    after: ItemId,
) !void {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    _ = try ir.add_command(container, .eval_start);
    _ = try ir.add_command(container, .duplicate);
    _ = try ir.add(container, .{ .integer = @intCast(position) });
    _ = try ir.add(container, .{ .native = "==" });
    _ = try ir.add_command(container, .eval_end);
    const branch = if (position < elements.len)
        lowering.result(elements[position]).container
    else
        try ir.new_container();
    _ = try ir.add(
        container,
        .{ .divert = .{ .target = .{ .container = branch }, .conditional = true } },
    );
    ir.container(branch).name = try std.fmt.allocPrint(ir.arena.allocator(), "s{d}", .{position});
    _ = try ir.insert(branch, 0, .{ .command = .pop });
    _ = try ir.add(branch, .{ .divert = .{ .target = .{ .item = after } } });
    try ir.add_named(container, branch);
}

/// VariableAssignment.GenerateRuntimeObject (a global declaration generates nothing here).
pub fn generate_assignment(lowering: *Lowering, assignment: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const tree = lowering.tree;
    if (tree.has(assignment, Flags.global)) return .none;
    const ir = &lowering.ir;
    const container = try ir.new_container();
    const children = tree.children_of(assignment);
    if (children.len > 0) try lowering.add_content(container, children[0]);
    const is_new = tree.has(assignment, Flags.new_temporary);
    const global = !is_new and lowering.resolution.references[assignment.to_int()] == .global;
    const name = try ir.text(lowering.child_name(assignment, 0));
    _ = try ir.add(
        container,
        .{ .assignment = .{ .name = name, .global = global, .new = is_new } },
    );
    return .{ .container = container };
}

/// Return.GenerateRuntimeObject.
pub fn generate_return(lowering: *Lowering, object: ObjectIndex) !Result {
    assert(lowering.results.len == lowering.tree.count());
    assert(lowering.runtime_containers.len == lowering.tree.count());
    const ir = &lowering.ir;
    const container = try ir.new_container();
    const children = lowering.tree.children_of(object);
    if (children.len > 0) {
        try lowering.add_content(container, children[0]);
    } else {
        _ = try ir.add_command(container, .eval_start);
        _ = try ir.add_command(container, .void);
        _ = try ir.add_command(container, .eval_end);
    }
    _ = try ir.add_command(container, .pop_function);
    return .{ .container = container };
}

comptime {
    assert(@sizeOf(Item) > 0);
    assert(@sizeOf(resolve.Reference) == 1);
}
