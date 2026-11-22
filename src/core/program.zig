//! The program: one immutable, pre-resolved story image. The compiler and the JSON
//! loader both produce it through `ProgramBuilder`; many stories may share one.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("profile.zig");
const index = @import("index.zig");
const fault = @import("fault.zig");
const string_pool = @import("string_pool.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const extra_module = @import("extra.zig");
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;
const ContainerInfo = container_module.ContainerInfo;
const NamedEntry = container_module.NamedEntry;
const GlobalSlot = index.GlobalSlot;
const ListItemIndex = index.ListItemIndex;
const ListOriginIndex = index.ListOriginIndex;
const ExternalIndex = index.ExternalIndex;

// The records below are `extern`: program images write them as raw bytes, so their field
// order and offsets are fixed, whatever the compiler or backend (pinned in program_image.zig).

pub const GlobalInfo = extern struct {
    name: StringId,
};

pub const ListOrigin = extern struct {
    name: StringId,
    /// The origin's items are `list_items[items_first..][0..items_count]`, in declaration order.
    items_first: ListItemIndex,
    items_count: u32,
};

pub const ListItem = extern struct {
    origin: ListOriginIndex,
    name: StringId,
    /// `origin.item`, as ink names items in saves and in `VAR?` lookups.
    full_name: StringId,
    value: i32,
};

pub const ExternalInfo = extern struct {
    name: StringId,
    /// The ink function with the same name, used when the host binds nothing and fallbacks
    /// are allowed; `.none` if the story has none.
    fallback: ContainerIndex,
};

/// What a string names when a story reads a variable by it (ink's GetRawVariableWithName
/// looks for a global, then a list item, then a temp): one entry per `StringId`.
pub const NameClass = packed struct(u32) {
    kind: Kind,
    /// The global's slot or the list item's index; 0 for `none`.
    index: u30,

    pub const Kind = enum(u2) { none, global, list_item, _ };

    pub const none: NameClass = .{ .kind = .none, .index = 0 };
};

comptime {
    assert(@sizeOf(NameClass) == 4);
}

/// The name classes of a program's strings: a global wins over a list item, and among list
/// items (by full name `origin.item` or bare name) the first one does, as ink's lookups go.
/// Derived from the tables, so images don't store it: the builder and the image loader
/// build it.
pub fn build_name_classes(
    gpa: std.mem.Allocator,
    strings_count: u32,
    globals: []const GlobalInfo,
    list_items: []const ListItem,
) std.mem.Allocator.Error![]NameClass {
    assert(strings_count > 0);
    const classes = try gpa.alloc(NameClass, strings_count);
    @memset(classes, .none);
    for (list_items, 0..) |item, position| {
        for ([_]StringId{ item.full_name, item.name }) |name| {
            if (name.is_none() or name.to_int() >= strings_count) continue;
            const class = &classes[name.to_int()];
            if (class.kind == .none) class.* = .{ .kind = .list_item, .index = @intCast(position) };
        }
    }
    for (globals, 0..) |global, slot| {
        if (global.name.is_none() or global.name.to_int() >= strings_count) continue;
        classes[global.name.to_int()] = .{ .kind = .global, .index = @intCast(slot) };
    }
    return classes;
}

pub const Program = struct {
    strings: string_pool.StringPool,
    /// What each string names as a variable (`build_name_classes`), so the VM resolves a
    /// name with one read instead of scanning the globals and hashing for list items.
    name_classes: []const NameClass,
    instructions: std.MultiArrayList(Instruction).Slice,
    extra: []const u32,
    containers: std.MultiArrayList(ContainerInfo).Slice,
    named: []const NamedEntry,
    globals: []const GlobalInfo,
    list_origins: []const ListOrigin,
    list_items: []const ListItem,
    externals: []const ExternalInfo,
    /// ink's `global decl` container, which declares the globals; `.none` if there is none.
    global_declaration: ContainerIndex,
    /// How many containers count visits or turns: the length of the count arrays.
    count_slots_count: u32,
    ink_version: u32,
    /// The string "\n", always interned: newline output items are slices of it.
    newline: StringId,

    pub const root: ContainerIndex = @fromBackingInt(@intCast(0));

    pub const Fault = enum {
        ok,
        no_containers,
        root_has_parent,
        root_depth_not_zero,
        parent_out_of_range,
        parent_after_child,
        depth_not_parent_plus_one,
        named_range_out_of_bounds,
        named_child_out_of_range,
        named_child_has_other_parent,
        instructions_not_partitioned,
        enter_container_child_mismatch,
        index_in_parent_mismatch,
        string_out_of_range,
        container_out_of_range,
        extra_out_of_range,
        target_out_of_range,
        count_slot_out_of_range,
        global_out_of_range,
        external_out_of_range,
        list_items_not_partitioned,
        name_classes_mismatch,
        list_item_origin_mismatch,
        fallback_out_of_range,
        newline_not_newline,
        list_item_out_of_range,
        list_origin_out_of_range,
        variable_pointer_context_out_of_range,
    };

    pub fn deinit(program: *Program, gpa: std.mem.Allocator) void {
        program.strings.deinit(gpa);
        gpa.free(program.name_classes);
        program.instructions.deinit(gpa);
        gpa.free(program.extra);
        program.containers.deinit(gpa);
        gpa.free(program.named);
        gpa.free(program.globals);
        gpa.free(program.list_origins);
        gpa.free(program.list_items);
        gpa.free(program.externals);
        program.* = undefined;
    }

    pub fn container_info(program: *const Program, container: ContainerIndex) ContainerInfo {
        assert(container.to_int() < program.containers.len);
        const info = program.containers.get(container.to_int());
        assert(info.named_first + info.named_count <= program.named.len);
        return info;
    }

    pub fn instructions_count(program: *const Program) u32 {
        const count: u32 = @intCast(program.instructions.len);
        assert(count == program.instructions.len);
        return count;
    }

    /// The instruction at content position `position` of `container`.
    pub fn instruction_at(
        program: *const Program,
        container: ContainerIndex,
        position: u32,
    ) Instruction {
        // Single-field reads: the VM calls this every step.
        const slot = container.to_int();
        assert(position < program.containers.items(.instruction_count)[slot]);
        const at = program.containers.items(.instruction_first)[slot].to_int() + position;
        assert(at < program.instructions.len);
        return .{
            .opcode = program.instructions.items(.opcode)[at],
            .operand = program.instructions.items(.operand)[at],
        };
    }

    // The container-table interface of `path.zig`.

    pub fn root_container(program: *const Program) ContainerIndex {
        assert(program.containers.items(.parent)[0].is_none());
        return root;
    }

    pub fn parent(program: *const Program, container: ContainerIndex) ContainerIndex {
        assert(container.to_int() < program.containers.len);
        const result = program.containers.items(.parent)[container.to_int()];
        assert(result.is_none() == (container == root));
        assert(result.is_none() or result.to_int() < container.to_int());
        return result;
    }

    /// The named child `name` of `container`: one string lookup, then id compares only.
    pub fn named_child(
        program: *const Program,
        container: ContainerIndex,
        name: []const u8,
    ) ?ContainerIndex {
        const info = program.container_info(container);
        const id = program.strings.find(name) orelse return null;
        for (program.named[info.named_first..][0..info.named_count]) |entry| {
            if (entry.name != id) continue;
            assert(program.parent(entry.child) == container);
            return entry.child;
        }
        return null;
    }

    pub fn content_count(program: *const Program, container: ContainerIndex) u32 {
        const count = program.containers.items(.instruction_count)[container.to_int()];
        assert(count <= program.instructions.len);
        assert(container.to_int() < program.containers.len);
        return count;
    }

    /// One field of a container's record, without reading the others (for the VM).
    pub fn container_field(
        program: *const Program,
        container: ContainerIndex,
        comptime field: std.meta.FieldEnum(ContainerInfo),
    ) @FieldType(ContainerInfo, @tagName(field)) {
        assert(container.to_int() < program.containers.len);
        return program.containers.items(field)[container.to_int()];
    }

    pub fn container_at(
        program: *const Program,
        container: ContainerIndex,
        position: u32,
    ) ?ContainerIndex {
        assert(position < program.content_count(container));
        const item = program.instruction_at(container, position);
        if (item.opcode != .enter_container) return null;
        const child = item.get(.enter_container);
        assert(program.parent(child) == container);
        return child;
    }

    /// The pair assertion after building and after loading.
    pub fn check(program: *const Program) Fault {
        const profile_zone = profile.begin(.program_check);
        defer profile_zone.end();
        const tree = program.check_containers();
        if (tree != .ok) return tree;
        const names = program.check_names();
        if (names != .ok) return names;
        const partition = program.check_partition();
        if (partition != .ok) return partition;
        const structure = program.check_children();
        if (structure != .ok) return structure;
        const operands = program.check_operands();
        if (operands != .ok) return operands;
        return program.check_tables();
    }

    pub fn verify(program: *const Program) void {
        fault.verify(program.check());
    }

    /// The tree: the root first, parents before children, depths one more than the parent's,
    /// and each named range in bounds and naming children of its container.
    fn check_containers(program: *const Program) Fault {
        const containers = program.containers;
        if (containers.len == 0) return .no_containers;
        const parents = containers.items(.parent);
        const depths = containers.items(.depth);
        if (!parents[0].is_none()) return .root_has_parent;
        if (depths[0] != 0) return .root_depth_not_zero;
        for (parents[1..], depths[1..], 1..) |container_parent, depth, position| {
            if (container_parent.is_none()) return .parent_out_of_range;
            // Parents come first, so one forward pass can check depths.
            if (container_parent.to_int() >= position) return .parent_after_child;
            // Widened: a parent at the u16 maximum must be a fault, not an overflow.
            if (depth != @as(u32, depths[container_parent.to_int()]) + 1) {
                return .depth_not_parent_plus_one;
            }
        }
        for (0..containers.len) |position| {
            const named_first = containers.items(.named_first)[position];
            const named_count = containers.items(.named_count)[position];
            if (@as(u64, named_first) + named_count > program.named.len) {
                return .named_range_out_of_bounds;
            }
            for (program.named[named_first..][0..named_count]) |entry| {
                if (entry.child.is_none() or entry.child.to_int() >= containers.len) {
                    return .named_child_out_of_range;
                }
                if (parents[entry.child.to_int()] != ContainerIndex.from_int(@intCast(position))) {
                    return .named_child_has_other_parent;
                }
            }
        }
        assert(containers.len > 0);
        return .ok;
    }

    /// Every string id in the tables names a string, and the newline string is "\n".
    fn check_names(program: *const Program) Fault {
        const containers = program.containers;
        for (containers.items(.name), containers.items(.path)) |name, path| {
            if (!name.is_none() and !program.is_string(name)) return .string_out_of_range;
            if (!program.is_string(path)) return .string_out_of_range;
        }
        for (program.named) |entry| if (!program.is_string(entry.name)) return .string_out_of_range;
        for (program.globals) |global| {
            if (!program.is_string(global.name)) return .string_out_of_range;
        }
        for (program.externals) |external| {
            if (!program.is_string(external.name)) return .string_out_of_range;
        }
        for (program.list_origins) |origin| {
            if (!program.is_string(origin.name)) return .string_out_of_range;
        }
        for (program.list_items) |item| {
            if (!program.is_string(item.name) or !program.is_string(item.full_name)) {
                return .string_out_of_range;
            }
        }
        if (!program.global_declaration.is_none() and
            program.global_declaration.to_int() >= containers.len) return .container_out_of_range;
        // Newline output items are one-byte slices of this string.
        if (!program.is_string(program.newline)) return .string_out_of_range;
        if (!std.mem.eql(u8, program.strings.get(program.newline), "\n")) {
            return .newline_not_newline;
        }
        return .ok;
    }

    /// Containers' instructions are laid out back to back in container order, so every
    /// instruction belongs to exactly one container.
    fn check_partition(program: *const Program) Fault {
        const firsts = program.containers.items(.instruction_first);
        const counts = program.containers.items(.instruction_count);
        var next: u64 = 0;
        for (firsts, counts) |first, count| {
            if (@backingInt(first) != next) return .instructions_not_partitioned;
            next += count;
        }
        if (next != program.instructions.len) return .instructions_not_partitioned;
        assert(firsts.len == counts.len);
        return .ok;
    }

    /// `enter_container` instructions and `index_in_parent` agree.
    fn check_children(program: *const Program) Fault {
        assert(program.check_partition() == .ok);
        const containers = program.containers;
        for (0..containers.len) |position| {
            const container: ContainerIndex = .from_int(@intCast(position));
            const first = containers.items(.instruction_first)[position].to_int();
            for (0..containers.items(.instruction_count)[position]) |offset| {
                const item = program.instructions.get(first + offset);
                if (item.opcode != .enter_container) continue;
                const child = item.operand;
                if (child >= containers.len) return .container_out_of_range;
                if (containers.items(.parent)[child] != container) {
                    return .enter_container_child_mismatch;
                }
                if (containers.items(.index_in_parent)[child] != offset) {
                    return .index_in_parent_mismatch;
                }
            }
            const in_parent = containers.items(.index_in_parent)[position];
            if (position > 0 and in_parent != container_module.named_only) {
                const parent_index = containers.items(.parent)[position];
                const parent_count = containers.items(.instruction_count)[parent_index.to_int()];
                if (in_parent >= parent_count) return .index_in_parent_mismatch;
                const item = program.instruction_at(parent_index, in_parent);
                if (item.opcode != .enter_container or item.operand != position) {
                    return .index_in_parent_mismatch;
                }
            }
        }
        assert(containers.len > 0);
        return .ok;
    }

    /// Every operand points at something that exists.
    fn check_operands(program: *const Program) Fault {
        assert(program.instructions.len == program.instructions_count());
        const strings_count = program.strings.count();
        const containers_count: u32 = @intCast(program.containers.len);
        const opcodes = program.instructions.items(.opcode);
        for (opcodes, program.instructions.items(.operand)) |opcode, operand| {
            const kind = instruction_module.operand_kind(opcode);
            const result: Fault = switch (kind) {
                .string => if (operand >= strings_count) .string_out_of_range else .ok,
                .container => if (operand >= containers_count) .container_out_of_range else .ok,
                .divert => program.check_divert(operand),
                .choice_point => program.check_choice_point(operand),
                .external_call => program.check_external_call(operand),
                .variable_pointer => program.check_variable_pointer(operand),
                .list => program.check_list_literal(operand),
                .global => if (operand >= program.globals.len) .global_out_of_range else .ok,
                .none, .integer, .float, .boolean => .ok,
            };
            if (result != .ok) return result;
        }
        for (program.containers.items(.count_slot)) |slot| {
            if (slot != container_module.no_count_slot and slot >= program.count_slots_count) {
                return .count_slot_out_of_range;
            }
        }
        assert(strings_count > 0);
        return .ok;
    }

    /// The `Data` record at `at` in `extra`, or null if it runs past the end or a word
    /// doesn't decode (images are untrusted; `extra.get` asserts both).
    fn record(
        program: *const Program,
        comptime Data: type,
        at: u32,
    ) ?Data {
        if (!extra_module.decodable(Data, program.extra, at)) return null;
        return extra_module.get(Data, program.extra, at);
    }

    fn check_variable_pointer(program: *const Program, at: u32) Fault {
        const Data = instruction_module.VariablePointer;
        const pointer = program.record(Data, at) orelse return .extra_out_of_range;
        if (!program.is_string(pointer.name)) return .string_out_of_range;
        // ink's context index: -1 unknown, 0 global, n > 0 a call-stack frame.
        if (pointer.context < -1) return .variable_pointer_context_out_of_range;
        return .ok;
    }

    /// A list literal's header and its tail of item and then origin indices, each of which
    /// the VM slices and stores without further checks.
    fn check_list_literal(program: *const Program, at: u32) Fault {
        const Data = instruction_module.ListLiteral;
        const literal = program.record(Data, at) orelse return .extra_out_of_range;
        const tail_at = at + extra_module.words(Data);
        const tail_words = @as(u64, literal.items_count) + literal.origins_count;
        if (tail_words > program.extra.len - tail_at) return .extra_out_of_range;
        const tail = program.extra[tail_at..][0..@intCast(tail_words)];
        for (tail[0..literal.items_count]) |item| {
            if (item >= program.list_items.len) return .list_item_out_of_range;
        }
        for (tail[literal.items_count..]) |origin| {
            if (origin >= program.list_origins.len) return .list_origin_out_of_range;
        }
        assert(tail_at <= program.extra.len);
        return .ok;
    }

    fn check_external_call(program: *const Program, at: u32) Fault {
        const Data = instruction_module.ExternalCall;
        const call = program.record(Data, at) orelse return .extra_out_of_range;
        if (@backingInt(call.external) >= program.externals.len) return .external_out_of_range;
        return .ok;
    }

    /// Lists: each origin's items are one range, in origin order, and point back at it.
    /// Externals: fallbacks exist.
    fn check_tables(program: *const Program) Fault {
        // 64 bits: untrusted counts may sum past u32.
        var next: u64 = 0;
        for (program.list_origins, 0..) |origin, origin_index| {
            if (@backingInt(origin.items_first) != next) return .list_items_not_partitioned;
            next += origin.items_count;
            if (next > program.list_items.len) return .list_items_not_partitioned;
            const items = program.list_items[origin.items_first.to_int()..][0..origin.items_count];
            for (items) |item| {
                if (@backingInt(item.origin) != origin_index) return .list_item_origin_mismatch;
            }
        }
        if (next != program.list_items.len) return .list_items_not_partitioned;
        if (!program.name_classes_consistent()) return .name_classes_mismatch;
        for (program.externals) |external| {
            if (external.fallback.is_none()) continue;
            if (external.fallback.to_int() >= program.containers.len) return .fallback_out_of_range;
        }
        assert(next == program.list_items.len);
        return .ok;
    }

    /// Every string has a class, and each class names a global or list item of that name
    /// that ink's lookup order picks.
    fn name_classes_consistent(program: *const Program) bool {
        if (program.name_classes.len != program.strings.count()) return false;
        for (program.name_classes, 0..) |class, position| {
            const name: StringId = .from_int(@intCast(position));
            switch (class.kind) {
                .none => if (class.index != 0) return false,
                .global => {
                    if (class.index >= program.globals.len) return false;
                    if (program.globals[class.index].name != name) return false;
                },
                .list_item => {
                    if (class.index >= program.list_items.len) return false;
                    const item = program.list_items[class.index];
                    if (item.full_name != name and item.name != name) return false;
                },
                _ => return false,
            }
        }
        return true;
    }

    /// What `name` names as a variable.
    pub fn name_class(program: *const Program, name: StringId) NameClass {
        assert(!name.is_none());
        assert(name.to_int() < program.name_classes.len);
        return program.name_classes[name.to_int()];
    }

    pub fn global_by_name(program: *const Program, name: []const u8) ?GlobalSlot {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.globals, 0..) |global, slot| {
            if (global.name == id) return .from_int(@intCast(slot));
        }
        return null;
    }

    /// A list item by `origin.item` or, as ink's `VAR?` allows, by its bare name.
    pub fn list_item_by_name(program: *const Program, name: []const u8) ?ListItemIndex {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.list_items, 0..) |item, position| {
            if (item.full_name == id or item.name == id) return .from_int(@intCast(position));
        }
        return null;
    }

    pub fn external_by_name(program: *const Program, name: []const u8) ?ExternalIndex {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.externals, 0..) |external, position| {
            if (external.name == id) return .from_int(@intCast(position));
        }
        return null;
    }

    fn is_string(program: *const Program, id: StringId) bool {
        assert(program.strings.count() > 0);
        return @backingInt(id) < program.strings.count();
    }

    fn check_target(program: *const Program, container: ContainerIndex, position: u32) Fault {
        if (container.is_none() or container.to_int() >= program.containers.len) {
            return .target_out_of_range;
        }
        // A target may point one past the last instruction: the end of the container.
        const count = program.containers.items(.instruction_count)[container.to_int()];
        if (position > count) return .target_out_of_range;
        assert(position <= count);
        return .ok;
    }

    fn check_divert(program: *const Program, at: u32) Fault {
        const Data = instruction_module.Divert;
        const divert = program.record(Data, at) orelse return .extra_out_of_range;
        if (!divert.flags.variable) {
            return program.check_target(divert.target_container, divert.target_index);
        }
        if (!program.is_string(divert.name)) return .string_out_of_range;
        return .ok;
    }

    fn check_choice_point(program: *const Program, at: u32) Fault {
        const Data = instruction_module.ChoicePoint;
        const choice = program.record(Data, at) orelse return .extra_out_of_range;
        return program.check_target(choice.target_container, choice.target_index);
    }
};
