//! Builds a `Program` (plan §4.2, P2.3). The JSON loader and the compiler both drive it.
//!
//! Containers arrive nested, but each container's instructions must end up contiguous. Open
//! containers write to a scratch stack; when a container ends, its instructions move out, and
//! `finish` lays every container out back to back in container order (plan T10). Container
//! indices are given out when a container begins, so parents come before their children.
//!
//! Paths in operands are fixups: they are resolved in `finish`, once every container exists,
//! with ink's own rules (`path.zig`). A path that doesn't resolve is a diagnostic.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const index = @import("index.zig");
const path_module = @import("path.zig");
const string_pool = @import("string_pool.zig");
const extra_module = @import("extra.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const Program = @import("program.zig").Program;
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;
const ContainerInfo = container_module.ContainerInfo;
const ContainerFlags = container_module.ContainerFlags;
const NamedEntry = container_module.NamedEntry;

pub const path_components_max = 64;

fn OperandOf(comptime opcode: Opcode) type {
    comptime assert(@typeInfo(Opcode).@"enum".field_names.len > 0);
    return instruction_module.Operand(instruction_module.operand_kind(opcode));
}

const plain_divert: instruction_module.DivertFlags = .{
    .kind = .plain,
    .conditional = false,
    .variable = false,
};

pub const Diagnostic = struct {
    kind: enum { unresolved_path, divert_target_not_a_container },
    /// The path text: `diagnostic_bytes[path_first..][0..path_count]`.
    path_first: u32,
    path_count: u32,
    /// The container holding the instruction with the path.
    container: ContainerIndex,
};

const Fixup = struct {
    kind: enum { divert, choice_point, container_operand },
    path: StringId,
    container: ContainerIndex,
    /// The extra index of the record, or the content position for `container_operand`.
    at: u32,
};

const Frame = struct {
    container: ContainerIndex,
    scratch_first: u32,
    named_first: u32,
};

/// Where a finished container's instructions and named entries are before `finish`.
const Staged = struct {
    instructions_first: u32,
    instructions_count: u32,
    named_first: u32,
    named_count: u32,
};

pub const ContainerOptions = struct {
    name: ?[]const u8 = null,
    flags: ContainerFlags = .{},
    /// Reachable only by name (knots, stitches), not as a content item of the parent.
    named_only: bool = false,
};

pub const ProgramBuilder = struct {
    gpa: Allocator,
    strings: string_pool.StringPool,
    extra: extra_module.ExtraBuilder = .{},
    containers: std.MultiArrayList(ContainerInfo) = .empty,
    staged: std.ArrayList(Staged) = .empty,
    finished: std.MultiArrayList(Instruction) = .empty,
    scratch: std.MultiArrayList(Instruction) = .empty,
    named_finished: std.ArrayList(NamedEntry) = .empty,
    named_scratch: std.ArrayList(NamedEntry) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// The path texts of `diagnostics`, which outlive the strings of a failed `finish`.
    diagnostic_bytes: std.ArrayList(u8) = .empty,
    ink_version: u32 = 21,

    pub fn init(gpa: Allocator) Allocator.Error!ProgramBuilder {
        const strings = try string_pool.StringPool.init(gpa);
        const builder: ProgramBuilder = .{ .gpa = gpa, .strings = strings };
        assert(builder.containers.len == 0);
        assert(builder.frames.items.len == 0);
        return builder;
    }

    pub fn deinit(builder: *ProgramBuilder) void {
        assert(builder.frames.items.len < 1 << 16);
        const gpa = builder.gpa;
        // After `finish` the containers have moved into the program.
        assert(builder.diagnostics.items.len <= builder.fixups.items.len);
        builder.strings.deinit(gpa);
        builder.extra.deinit(gpa);
        builder.containers.deinit(gpa);
        builder.staged.deinit(gpa);
        builder.finished.deinit(gpa);
        builder.scratch.deinit(gpa);
        builder.named_finished.deinit(gpa);
        builder.named_scratch.deinit(gpa);
        builder.frames.deinit(gpa);
        builder.fixups.deinit(gpa);
        builder.diagnostics.deinit(gpa);
        builder.diagnostic_bytes.deinit(gpa);
        builder.* = undefined;
    }

    /// The container whose content is being built.
    pub fn current(builder: *const ProgramBuilder) ContainerIndex {
        assert(builder.frames.items.len > 0);
        const container = builder.frames.items[builder.frames.items.len - 1].container;
        assert(container.to_int() < builder.containers.len);
        return container;
    }

    /// Content items added so far to the current container.
    pub fn content_count(builder: *const ProgramBuilder) u32 {
        assert(builder.frames.items.len > 0);
        const frame = builder.frames.items[builder.frames.items.len - 1];
        const count: u32 = @intCast(builder.scratch.len - frame.scratch_first);
        assert(frame.scratch_first <= builder.scratch.len);
        return count;
    }

    /// Opens a container. Inside another container it is either the parent's next content
    /// item (an `enter_container` instruction) or, with `named_only`, reachable by name only.
    pub fn begin_container(builder: *ProgramBuilder, options: ContainerOptions) !ContainerIndex {
        const gpa = builder.gpa;
        const container: ContainerIndex = .from_int(@intCast(builder.containers.len));
        const is_root = builder.frames.items.len == 0;
        const parent: ContainerIndex = if (is_root) .none else builder.current();
        assert(!(parent.is_none() and options.named_only));
        var index_in_parent: u32 = container_module.named_only;
        if (!parent.is_none() and !options.named_only) {
            index_in_parent = builder.content_count();
            try builder.scratch.append(gpa, .init(.enter_container, container));
        }
        const name: StringId = if (options.name) |text| try builder.intern(text) else .none;
        if (!parent.is_none() and !name.is_none()) {
            try builder.named_scratch.append(gpa, .{ .name = name, .child = container });
        }
        const path = try builder.child_path(parent, name, index_in_parent);
        try builder.containers.append(gpa, .{
            .instruction_first = .from_int(0),
            .instruction_count = 0,
            .parent = parent,
            .index_in_parent = index_in_parent,
            .depth = if (is_root) 0 else builder.containers.items(.depth)[parent.to_int()] + 1,
            .flags = options.flags,
            .name = name,
            .path = path,
            .path_hash = path_module.shuffle_hash(builder.strings.get(path)),
            .named_first = 0,
            .named_count = 0,
            .count_slot = container_module.no_count_slot,
        });
        try builder.frames.append(gpa, .{
            .container = container,
            .scratch_first = @intCast(builder.scratch.len),
            .named_first = @intCast(builder.named_scratch.items.len),
        });
        assert(builder.current() == container);
        return container;
    }

    /// ink's path of a child: the parent's path plus the child's name, or its content index.
    fn child_path(
        builder: *ProgramBuilder,
        parent: ContainerIndex,
        name: StringId,
        position: u32,
    ) !StringId {
        assert(position == container_module.named_only or !name.is_none() or position < 1 << 24);
        if (parent.is_none()) return string_pool.empty_id;
        const parent_path = builder.strings.get(builder.containers.items(.path)[parent.to_int()]);
        var buffer: [1024]u8 = undefined;
        const separator: []const u8 = if (parent_path.len > 0) "." else "";
        const text = if (!name.is_none())
            try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{
                parent_path, separator, builder.strings.get(name),
            })
        else
            try std.fmt.bufPrint(&buffer, "{s}{s}{d}", .{ parent_path, separator, position });
        assert(text.len > 0);
        return builder.strings.intern(builder.gpa, text);
    }

    /// Closes the current container and moves its instructions and named entries out.
    pub fn end_container(builder: *ProgramBuilder) !void {
        const gpa = builder.gpa;
        const frame = builder.frames.pop().?;
        assert(frame.scratch_first <= builder.scratch.len);
        const instructions_first: u32 = @intCast(builder.finished.len);
        for (frame.scratch_first..builder.scratch.len) |at| {
            try builder.finished.append(gpa, builder.scratch.get(at));
        }
        const named_first: u32 = @intCast(builder.named_finished.items.len);
        const named_entries = builder.named_scratch.items[frame.named_first..];
        try builder.named_finished.appendSlice(gpa, named_entries);
        const position = frame.container.to_int();
        if (builder.staged.items.len <= position) {
            const missing = position + 1 - builder.staged.items.len;
            try builder.staged.appendNTimes(gpa, undefined, missing);
        }
        builder.staged.items[position] = .{
            .instructions_first = instructions_first,
            .instructions_count = @intCast(builder.scratch.len - frame.scratch_first),
            .named_first = named_first,
            .named_count = @intCast(builder.named_scratch.items.len - frame.named_first),
        };
        builder.scratch.shrinkRetainingCapacity(frame.scratch_first);
        builder.named_scratch.shrinkRetainingCapacity(frame.named_first);
        assert(builder.scratch.len == frame.scratch_first);
    }

    pub fn add(
        builder: *ProgramBuilder,
        comptime opcode: Opcode,
        operand: OperandOf(opcode),
    ) !void {
        assert(builder.frames.items.len > 0);
        const count_before = builder.scratch.len;
        try builder.scratch.append(builder.gpa, .init(opcode, operand));
        assert(builder.scratch.len == count_before + 1);
    }

    pub fn intern(builder: *ProgramBuilder, text: []const u8) !StringId {
        assert(text.len < std.math.maxInt(u32));
        const id = try builder.strings.intern(builder.gpa, text);
        assert(std.mem.eql(u8, builder.strings.get(id), text));
        return id;
    }

    /// A divert to `path`, resolved in `finish`.
    pub fn add_divert(
        builder: *ProgramBuilder,
        path: []const u8,
        flags: instruction_module.DivertFlags,
    ) !void {
        assert(path.len > 0);
        assert(!flags.variable);
        const at = try builder.extra.add(builder.gpa, instruction_module.Divert{
            .target_container = .none,
            .target_index = 0,
            .name = .none,
            .flags = flags,
        });
        try builder.add_fixup(.divert, path, at);
        try builder.add(.divert, @enumFromInt(at));
    }

    /// A divert to the divert target held in variable `name`.
    pub fn add_divert_variable(
        builder: *ProgramBuilder,
        name: []const u8,
        flags: instruction_module.DivertFlags,
    ) !void {
        assert(flags.variable);
        const at = try builder.extra.add(builder.gpa, instruction_module.Divert{
            .target_container = .none,
            .target_index = 0,
            .name = try builder.intern(name),
            .flags = flags,
        });
        try builder.add(.divert, @enumFromInt(at));
        assert(builder.scratch.len > 0);
    }

    pub fn add_choice_point(
        builder: *ProgramBuilder,
        path: []const u8,
        flags: instruction_module.ChoiceFlags,
    ) !void {
        assert(builder.frames.items.len > 0);
        assert(path.len > 0);
        const at = try builder.extra.add(builder.gpa, instruction_module.ChoicePoint{
            .target_container = .none,
            .target_index = 0,
            .flags = flags,
        });
        try builder.add_fixup(.choice_point, path, at);
        try builder.add(.choice_point, @enumFromInt(at));
    }

    /// An instruction whose operand is the container at `path`: `divert_target` or `read_count`.
    pub fn add_container_operand(
        builder: *ProgramBuilder,
        comptime opcode: Opcode,
        path: []const u8,
    ) !void {
        assert(path.len > 0);
        comptime assert(instruction_module.operand_kind(opcode) == .container);
        try builder.add_fixup(.container_operand, path, builder.content_count());
        try builder.add(opcode, .none);
    }

    fn add_fixup(
        builder: *ProgramBuilder,
        kind: @FieldType(Fixup, "kind"),
        path: []const u8,
        at: u32,
    ) !void {
        assert(builder.frames.items.len > 0);
        try builder.fixups.append(builder.gpa, .{
            .kind = kind,
            .path = try builder.intern(path),
            .container = builder.current(),
            .at = at,
        });
        assert(builder.fixups.items.len > 0);
    }

    /// Lays out every container, resolves the fixups and checks the result. On
    /// `error.UnresolvedPaths`, `diagnostics` says which paths failed.
    pub fn finish(builder: *ProgramBuilder) !Program {
        assert(builder.frames.items.len == 0);
        assert(builder.staged.items.len == builder.containers.len);
        var program = try builder.layout();
        errdefer program.deinit(builder.gpa);
        try builder.resolve_fixups(&program);
        if (builder.diagnostics.items.len > 0) return error.UnresolvedPaths;
        program.verify();
        return program;
    }

    /// Copies instructions and named entries into their final, container-ordered arrays.
    fn layout(builder: *ProgramBuilder) !Program {
        assert(builder.staged.items.len == builder.containers.len);
        const gpa = builder.gpa;
        var instructions: std.MultiArrayList(Instruction) = .empty;
        errdefer instructions.deinit(gpa);
        try instructions.ensureTotalCapacity(gpa, builder.finished.len);
        var named: std.ArrayList(NamedEntry) = .empty;
        errdefer named.deinit(gpa);
        var count_slots: u32 = 0;
        for (builder.staged.items, 0..) |staged, position| {
            const container = builder.containers.get(position);
            var info = container;
            info.instruction_first = .from_int(@intCast(instructions.len));
            info.instruction_count = staged.instructions_count;
            info.named_first = @intCast(named.items.len);
            info.named_count = staged.named_count;
            if (info.flags.visits_counted or info.flags.turns_counted) {
                info.count_slot = count_slots;
                count_slots += 1;
            }
            builder.containers.set(position, info);
            for (0..staged.instructions_count) |offset| {
                const item = builder.finished.get(staged.instructions_first + offset);
                instructions.appendAssumeCapacity(item);
            }
            const entries = builder.named_finished.items[staged.named_first..];
            try named.appendSlice(gpa, entries[0..staged.named_count]);
        }
        assert(instructions.len == builder.finished.len);
        return builder.freeze(&instructions, &named, count_slots);
    }

    fn freeze(
        builder: *ProgramBuilder,
        instructions: *std.MultiArrayList(Instruction),
        named: *std.ArrayList(NamedEntry),
        count_slots: u32,
    ) !Program {
        assert(instructions.len == builder.finished.len);
        const gpa = builder.gpa;
        const extra = try builder.extra.words.toOwnedSlice(gpa);
        errdefer gpa.free(extra);
        const named_owned = try named.toOwnedSlice(gpa);
        errdefer gpa.free(named_owned);
        var containers = builder.containers;
        builder.containers = .empty;
        const program: Program = .{
            .strings = try builder.strings.freeze(gpa),
            .instructions = instructions.toOwnedSlice(),
            .extra = extra,
            .containers = containers.toOwnedSlice(),
            .named = named_owned,
            .count_slots_count = count_slots,
            .ink_version = builder.ink_version,
        };
        builder.strings = try string_pool.StringPool.init(gpa);
        assert(program.containers.len == builder.staged.items.len);
        return program;
    }

    pub fn diagnostic_path(builder: *const ProgramBuilder, diagnostic: Diagnostic) []const u8 {
        const end = diagnostic.path_first + diagnostic.path_count;
        assert(end <= builder.diagnostic_bytes.items.len);
        assert(diagnostic.path_count > 0);
        return builder.diagnostic_bytes.items[diagnostic.path_first..end];
    }

    fn resolve_fixups(builder: *ProgramBuilder, program: *Program) !void {
        assert(program.containers.len == builder.staged.items.len);
        const extra: []u32 = @constCast(program.extra);
        for (builder.fixups.items) |fixup| {
            const text = program.strings.get(fixup.path);
            const parsed = path_module.Path.parse(text, path_components_max) catch {
                try builder.report(.unresolved_path, fixup, text);
                continue;
            };
            const target = path_module.resolve(program, .{
                .container = fixup.container,
                .from_content = true,
            }, parsed) catch {
                try builder.report(.unresolved_path, fixup, text);
                continue;
            };
            if (target.approximate) {
                try builder.report(.unresolved_path, fixup, text);
                continue;
            }
            try builder.apply(program, extra, fixup, target);
        }
        assert(builder.diagnostics.items.len <= builder.fixups.items.len);
    }

    fn apply(
        builder: *ProgramBuilder,
        program: *Program,
        extra: []u32,
        fixup: Fixup,
        target: path_module.Target,
    ) !void {
        assert(target.container.to_int() < program.containers.len);
        const position = target.content_index orelse 0;
        switch (fixup.kind) {
            // The first two record words of both records are the target container and index.
            .divert, .choice_point => {
                extra[fixup.at] = @intFromEnum(target.container);
                extra[fixup.at + 1] = position;
            },
            .container_operand => {
                if (target.content_index != null) {
                    const text = program.strings.get(fixup.path);
                    try builder.report(.divert_target_not_a_container, fixup, text);
                    return;
                }
                const info = program.table().get(fixup.container);
                const at = info.instruction_first.to_int() + fixup.at;
                program.instructions.items(.operand)[at] = @intFromEnum(target.container);
            },
        }
        assert(!target.container.is_none());
    }

    fn report(
        builder: *ProgramBuilder,
        kind: @FieldType(Diagnostic, "kind"),
        fixup: Fixup,
        text: []const u8,
    ) !void {
        assert(!fixup.path.is_none());
        const first: u32 = @intCast(builder.diagnostic_bytes.items.len);
        try builder.diagnostic_bytes.appendSlice(builder.gpa, text);
        try builder.diagnostics.append(builder.gpa, .{
            .kind = kind,
            .path_first = first,
            .path_count = @intCast(text.len),
            .container = fixup.container,
        });
        assert(builder.diagnostics.items.len > 0);
    }
};

comptime {
    // `apply` writes the target into the first two words of both records.
    const divert_fields = @typeInfo(instruction_module.Divert).@"struct".field_names;
    const choice_fields = @typeInfo(instruction_module.ChoicePoint).@"struct".field_names;
    assert(std.mem.eql(u8, divert_fields[0], "target_container"));
    assert(std.mem.eql(u8, choice_fields[1], "target_index"));
}

/// root: [text "A", nested c (1): [text "B", newline], text "C"], named knot (2) with named
/// stitch (3); the root diverts to knot.stitch and the stitch back to its knot.
fn build_sample(builder: *ProgramBuilder) !void {
    assert(builder.containers.len == 0);
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("A"));
    _ = try builder.begin_container(.{ .name = "c-0" });
    try builder.add(.text, try builder.intern("B"));
    try builder.add(.newline, {});
    try builder.end_container();
    try builder.add(.text, try builder.intern("C"));
    try builder.add_divert("knot.stitch", plain_divert);
    const counted: ContainerFlags = .{ .visits_counted = true };
    _ = try builder.begin_container(.{ .name = "knot", .named_only = true, .flags = counted });
    try builder.add_container_operand(.read_count, ".^.stitch");
    _ = try builder.begin_container(.{ .name = "stitch", .named_only = true });
    try builder.add_divert(".^.^", plain_divert);
    try builder.add_container_operand(.divert_target, "knot");
    try builder.end_container();
    try builder.end_container();
    try builder.end_container();
    assert(builder.containers.len == 4);
}

test "nested containers come out contiguous with ink paths" {
    // Goal: P2.3; each container's instructions are one range in container order, and paths
    // use names or content indices like ink. Method: build the sample and inspect it.
    var builder = try ProgramBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try build_sample(&builder);
    var program = try builder.finish();
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(Program.Fault.ok, program.check());
    const firsts = program.containers.items(.instruction_first);
    const counts = program.containers.items(.instruction_count);
    try std.testing.expectEqualSlices(u32, &.{ 4, 2, 1, 2 }, counts);
    try std.testing.expectEqual(@as(u32, 4), firsts[1].to_int());
    const entered = program.instruction_at(Program.root, 1);
    try std.testing.expectEqual(Opcode.enter_container, entered.opcode);
    const paths = program.containers.items(.path);
    try std.testing.expectEqualStrings("c-0", program.strings.get(paths[1]));
    try std.testing.expectEqualStrings("knot.stitch", program.strings.get(paths[3]));
    try std.testing.expectEqual(@as(u32, 1), program.count_slots_count);
}

test "path fixups resolve to containers and positions" {
    // Goal: forward and relative references resolve in finish. Method: check each operand of
    // the sample.
    var builder = try ProgramBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try build_sample(&builder);
    var program = try builder.finish();
    defer program.deinit(std.testing.allocator);
    const divert_at = @intFromEnum(program.instruction_at(Program.root, 3).get(.divert));
    const divert = extra_module.get(instruction_module.Divert, program.extra, divert_at).data;
    try std.testing.expectEqual(ContainerIndex.from_int(3), divert.target_container);
    const knot: ContainerIndex = .from_int(2);
    const stitch: ContainerIndex = .from_int(3);
    try std.testing.expectEqual(stitch, program.instruction_at(knot, 0).get(.read_count));
    const back_at = @intFromEnum(program.instruction_at(stitch, 0).get(.divert));
    const back = extra_module.get(instruction_module.Divert, program.extra, back_at).data;
    // From the stitch's content, `.^` leaves the content item and `.^` again goes to the knot.
    try std.testing.expectEqual(knot, back.target_container);
    try std.testing.expectEqual(knot, program.instruction_at(stitch, 1).get(.divert_target));
}

test "an unresolved path is a diagnostic" {
    // Goal: P2.3 negative space. Method: divert to a knot that doesn't exist.
    var builder = try ProgramBuilder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add_divert("nowhere.at_all", plain_divert);
    try builder.end_container();
    try std.testing.expectError(error.UnresolvedPaths, builder.finish());
    try std.testing.expectEqual(@as(usize, 1), builder.diagnostics.items.len);
    const diagnostic = builder.diagnostics.items[0];
    try std.testing.expectEqualStrings("nowhere.at_all", builder.diagnostic_path(diagnostic));
}

test "check catches a corrupted program" {
    // Goal: Program.check reports corruption by name (D20). Method: break the partition, an
    // enter_container operand, and a string operand, one at a time.
    var builder = try ProgramBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try build_sample(&builder);
    var program = try builder.finish();
    defer program.deinit(std.testing.allocator);
    const firsts = program.containers.items(.instruction_first);
    firsts[1] = .from_int(5);
    try std.testing.expectEqual(Program.Fault.instructions_not_partitioned, program.check());
    firsts[1] = .from_int(4);
    const operands = program.instructions.items(.operand);
    operands[1] = 3;
    try std.testing.expectEqual(Program.Fault.enter_container_child_mismatch, program.check());
    operands[1] = 1;
    operands[0] = 999;
    try std.testing.expectEqual(Program.Fault.string_out_of_range, program.check());
    operands[0] = 1;
    try std.testing.expectEqual(Program.Fault.ok, program.check());
}
