//! The program: one immutable, pre-resolved story image (plan §4.2). The compiler and the JSON
//! loader both produce it through `ProgramBuilder`; many stories may share one.

const std = @import("std");
const assert = std.debug.assert;
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
const ContainerTable = container_module.ContainerTable;
const GlobalSlot = index.GlobalSlot;
const ListItemIndex = index.ListItemIndex;
const ListOriginIndex = index.ListOriginIndex;
const ExternalIndex = index.ExternalIndex;

pub const GlobalInfo = struct {
    name: StringId,
};

pub const ListOrigin = struct {
    name: StringId,
    /// The origin's items are `list_items[items_first..][0..items_count]`, in declaration order.
    items_first: ListItemIndex,
    items_count: u32,
};

pub const ListItem = struct {
    origin: ListOriginIndex,
    name: StringId,
    /// `origin.item`, as ink names items in saves and in `VAR?` lookups.
    full_name: StringId,
    value: i32,
};

pub const ExternalInfo = struct {
    name: StringId,
    /// The ink function with the same name, used when the host binds nothing and fallbacks
    /// are allowed; `.none` if the story has none.
    fallback: ContainerIndex,
};

pub const Program = struct {
    strings: string_pool.FrozenStringPool,
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

    pub const root: ContainerIndex = @enumFromInt(0);

    pub const Fault = enum {
        ok,
        containers,
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
        list_item_origin_mismatch,
        fallback_out_of_range,
    };

    pub fn deinit(program: *Program, gpa: std.mem.Allocator) void {
        assert(program.instructions.len < std.math.maxInt(u32));
        assert(program.containers.len > 0);
        program.strings.deinit(gpa);
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

    pub fn table(program: *const Program) ContainerTable {
        assert(program.containers.len > 0);
        const result: ContainerTable = .{
            .containers = program.containers,
            .named = program.named,
        };
        assert(result.named.len == program.named.len);
        return result;
    }

    pub fn instructions_count(program: *const Program) u32 {
        const count: u32 = @intCast(program.instructions.len);
        assert(count == program.instructions.len);
        assert(count < std.math.maxInt(u32));
        return count;
    }

    /// The instruction at content position `position` of `container`.
    pub fn instruction_at(
        program: *const Program,
        container: ContainerIndex,
        position: u32,
    ) Instruction {
        const info = program.table().get(container);
        assert(position < info.instruction_count);
        const at = info.instruction_first.to_int() + position;
        assert(at < program.instructions.len);
        return program.instructions.get(at);
    }

    // The container-table interface of `path.zig`.

    pub fn root_container(program: *const Program) ContainerIndex {
        assert(program.containers.len > 0);
        assert(program.table().parent(root).is_none());
        return root;
    }

    pub fn parent(program: *const Program, container: ContainerIndex) ContainerIndex {
        assert(container.to_int() < program.containers.len);
        const result = program.table().parent(container);
        assert(result.is_none() or result.to_int() < container.to_int());
        return result;
    }

    pub fn named_child(
        program: *const Program,
        container: ContainerIndex,
        name: []const u8,
    ) ?ContainerIndex {
        assert(container.to_int() < program.containers.len);
        const id = program.strings.find(name) orelse return null;
        const child = program.table().named_child(container, id) orelse return null;
        assert(program.table().parent(child) == container);
        return child;
    }

    pub fn content_count(program: *const Program, container: ContainerIndex) u32 {
        const info = program.table().get(container);
        assert(info.instruction_count <= program.instructions.len);
        assert(info.instruction_first.to_int() <= program.instructions.len);
        return info.instruction_count;
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
        assert(program.table().parent(child) == container);
        return child;
    }

    /// The pair assertion after building and after loading (plan §3.1).
    pub fn check(program: *const Program) Fault {
        assert(program.containers.len > 0);
        const instructions_total = program.instructions_count();
        if (program.table().check(instructions_total) != .ok) return .containers;
        const partition = program.check_partition();
        if (partition != .ok) return partition;
        const structure = program.check_children();
        if (structure != .ok) return structure;
        const operands = program.check_operands();
        if (operands != .ok) return operands;
        const tables = program.check_tables();
        assert(tables != .containers);
        return tables;
    }

    pub fn verify(program: *const Program) void {
        assert(program.containers.len > 0);
        fault.verify(program.check());
    }

    /// Containers' instructions are laid out back to back in container order, so every
    /// instruction belongs to exactly one container.
    fn check_partition(program: *const Program) Fault {
        assert(program.containers.len > 0);
        const firsts = program.containers.items(.instruction_first);
        const counts = program.containers.items(.instruction_count);
        var next: u64 = 0;
        for (firsts, counts) |first, count| {
            if (first.to_int() != next) return .instructions_not_partitioned;
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
                .variable_pointer, .list => program.check_extra(operand, 2),
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

    fn check_external_call(program: *const Program, at: u32) Fault {
        assert(program.externals.len < std.math.maxInt(u32));
        const words = @typeInfo(instruction_module.ExternalCall).@"struct".field_names.len;
        if (program.check_extra(at, words) != .ok) return .extra_out_of_range;
        const call = extra_module.get(instruction_module.ExternalCall, program.extra, at).data;
        if (call.external.is_none() or call.external.to_int() >= program.externals.len) {
            return .external_out_of_range;
        }
        assert(words == 3);
        return .ok;
    }

    /// Lists: each origin's items are one range, in origin order, and point back at it.
    /// Externals: fallbacks exist.
    fn check_tables(program: *const Program) Fault {
        assert(program.list_items.len < std.math.maxInt(u32));
        var next: u32 = 0;
        for (program.list_origins, 0..) |origin, origin_index| {
            if (origin.items_first.to_int() != next) return .list_items_not_partitioned;
            next += origin.items_count;
            if (next > program.list_items.len) return .list_items_not_partitioned;
            const items = program.list_items[origin.items_first.to_int()..][0..origin.items_count];
            for (items) |item| {
                if (item.origin.to_int() != origin_index) return .list_item_origin_mismatch;
            }
        }
        if (next != program.list_items.len) return .list_items_not_partitioned;
        for (program.externals) |external| {
            if (external.fallback.is_none()) continue;
            if (external.fallback.to_int() >= program.containers.len) return .fallback_out_of_range;
        }
        assert(next == program.list_items.len);
        return .ok;
    }

    pub fn global_by_name(program: *const Program, name: []const u8) ?GlobalSlot {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.globals, 0..) |global, slot| {
            if (global.name == id) return .from_int(@intCast(slot));
        }
        assert(program.globals.len < std.math.maxInt(u32));
        return null;
    }

    /// A list item by `origin.item` or, as ink's `VAR?` allows, by its bare name.
    pub fn list_item_by_name(program: *const Program, name: []const u8) ?ListItemIndex {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.list_items, 0..) |item, position| {
            if (item.full_name == id or item.name == id) return .from_int(@intCast(position));
        }
        assert(program.list_items.len < std.math.maxInt(u32));
        return null;
    }

    pub fn external_by_name(program: *const Program, name: []const u8) ?ExternalIndex {
        assert(name.len > 0);
        const id = program.strings.find(name) orelse return null;
        for (program.externals, 0..) |external, position| {
            if (external.name == id) return .from_int(@intCast(position));
        }
        assert(program.externals.len < std.math.maxInt(u32));
        return null;
    }

    fn check_extra(program: *const Program, at: u32, words: u32) Fault {
        assert(words > 0);
        if (at > program.extra.len or words > program.extra.len - at) return .extra_out_of_range;
        assert(at + words <= program.extra.len);
        return .ok;
    }

    fn check_target(program: *const Program, container: ContainerIndex, position: u32) Fault {
        assert(program.containers.len > 0);
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
        assert(at < std.math.maxInt(u32));
        const words = @typeInfo(instruction_module.Divert).@"struct".field_names.len;
        if (program.check_extra(at, words) != .ok) return .extra_out_of_range;
        const divert = extra_module.get(instruction_module.Divert, program.extra, at).data;
        if (divert.flags.variable) {
            if (divert.name.is_none() or divert.name.to_int() >= program.strings.count()) {
                return .string_out_of_range;
            }
            return .ok;
        }
        assert(!divert.flags.variable);
        return program.check_target(divert.target_container, divert.target_index);
    }

    fn check_choice_point(program: *const Program, at: u32) Fault {
        assert(at < std.math.maxInt(u32));
        const words = @typeInfo(instruction_module.ChoicePoint).@"struct".field_names.len;
        if (program.check_extra(at, words) != .ok) return .extra_out_of_range;
        const choice = extra_module.get(instruction_module.ChoicePoint, program.extra, at).data;
        assert(words == 3);
        return program.check_target(choice.target_container, choice.target_index);
    }
};
