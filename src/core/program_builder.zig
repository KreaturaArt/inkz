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
const profile = @import("profile.zig");
const Allocator = std.mem.Allocator;
const index = @import("index.zig");
const path_module = @import("path.zig");
const string_pool = @import("string_pool.zig");
const extra_module = @import("extra.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const Program = @import("program.zig").Program;
const ContainerIndex = index.ContainerIndex;
const GlobalSlot = index.GlobalSlot;
const ListOriginIndex = index.ListOriginIndex;
const ExternalIndex = index.ExternalIndex;
const program_module = @import("program.zig");
const StringId = index.StringId;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;
const ContainerInfo = container_module.ContainerInfo;
const ContainerFlags = container_module.ContainerFlags;
const NamedEntry = container_module.NamedEntry;

pub const path_components_max = 64;

/// Everything building can fail with besides running out of memory.
pub const Error = error{
    StringPoolFull,
    ExtraFull,
    /// A container path longer than the path buffer.
    NoSpaceLeft,
    UnknownListItem,
    UnknownListOrigin,
    UnresolvedPaths,
} || Allocator.Error;

fn OperandOf(comptime opcode: Opcode) type {
    comptime assert(@sizeOf(Opcode) == 1);
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
    /// The target as a path: `path_bytes[path_first..][0..path_length]`, empty for a keyed
    /// target outside Debug. Kept out of the program's strings: nothing reads it once
    /// resolved (P12.4).
    path_first: u32,
    path_length: u32,
    container: ContainerIndex,
    /// The extra index of the record, or the content position for `container_operand`.
    at: u32,
    /// A keyed target (P12.4): the container begun with this key, and a content position in
    /// it (`no_index` for the container itself). `no_key` for a path target.
    key: u32 = no_key,
    index: u32 = no_index,
};

/// No key: a container without one, or a fixup with a path target.
pub const no_key = std.math.maxInt(u32);
const no_index = std.math.maxInt(u32);

/// A target named by the caller's own key for a container (`ContainerOptions.key`) and,
/// optionally, a content position in it, resolved in `finish` as a path to it would be. The
/// compiler knows its targets, so it skips writing paths and parsing them back (P12.4).
pub const KeyTarget = struct { key: u32, index: ?u32 = null };

/// A `VAR?` read, resolved in `finish` as ink resolves it: a global, else a list item (as a
/// one-item list), else a temp.
const VariableFixup = struct {
    container: ContainerIndex,
    position: u32,
    name: StringId,
    /// A `VAR?` read (a `temp_get` until resolved) or a re-assignment (a `temp_assign`).
    kind: enum { get, assign } = .get,
};

/// A list literal whose items and origins are names until the list definitions are known.
const ListFixup = struct {
    /// The extra index just after the `ListLiteral` record: items, then origins.
    words_at: u32,
    names_first: u32,
    items_count: u32,
    origins_count: u32,
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
    /// The caller's key for `KeyTarget`s to this container.
    key: u32 = no_key,
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
    /// The fixups' path texts.
    path_bytes: std.ArrayList(u8) = .empty,
    /// The container begun with each key (`.none` for keys not used).
    keys: std.ArrayList(ContainerIndex) = .empty,
    variable_fixups: std.ArrayList(VariableFixup) = .empty,
    list_fixups: std.ArrayList(ListFixup) = .empty,
    /// Item names, then origin names, of each list fixup.
    list_names: std.ArrayList(StringId) = .empty,
    globals: std.ArrayList(program_module.GlobalInfo) = .empty,
    list_origins: std.ArrayList(program_module.ListOrigin) = .empty,
    list_items: std.ArrayList(program_module.ListItem) = .empty,
    externals: std.ArrayList(program_module.ExternalInfo) = .empty,
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
        builder.path_bytes.deinit(gpa);
        builder.keys.deinit(gpa);
        builder.variable_fixups.deinit(gpa);
        builder.list_fixups.deinit(gpa);
        builder.list_names.deinit(gpa);
        builder.diagnostics.deinit(gpa);
        builder.diagnostic_bytes.deinit(gpa);
        builder.globals.deinit(gpa);
        builder.list_origins.deinit(gpa);
        builder.list_items.deinit(gpa);
        builder.externals.deinit(gpa);
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
        if (options.key != no_key) try builder.set_key(options.key, container);
        try builder.containers.append(gpa, .{
            .instruction_first = .from_int(0),
            .instruction_count = 0,
            .parent = parent,
            .index_in_parent = index_in_parent,
            .depth = if (is_root) 0 else builder.containers.items(.depth)[parent.to_int()] + 1,
            .flags = options.flags,
            .name = name,
            // Paths and hashes are computed in `finish`: a name may only arrive at the end.
            .path = .none,
            .path_hash = 0,
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

    fn set_key(builder: *ProgramBuilder, key: u32, container: ContainerIndex) !void {
        assert(key != no_key);
        if (key >= builder.keys.items.len) {
            try builder.keys.appendNTimes(builder.gpa, .none, key + 1 - builder.keys.items.len);
        }
        assert(builder.keys.items[key].is_none());
        builder.keys.items[key] = container;
    }

    /// Names the current container. ink's JSON gives a container's name (`#n`) at its end.
    pub fn set_name(builder: *ProgramBuilder, name: []const u8) !void {
        assert(name.len > 0);
        const container = builder.current();
        builder.containers.items(.name)[container.to_int()] = try builder.intern(name);
        assert(!builder.containers.items(.name)[container.to_int()].is_none());
    }

    /// Sets the current container's counting flags (`#f` in ink's JSON).
    pub fn set_flags(builder: *ProgramBuilder, flags: ContainerFlags) void {
        assert(builder.frames.items.len > 0);
        const container = builder.current();
        assert(flags.padding == 0);
        builder.containers.items(.flags)[container.to_int()] = flags;
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
        // The parent's named entry for this container goes in now, when the parent's named
        // entries are back on top of the scratch stack.
        const name = builder.containers.items(.name)[position];
        if (builder.frames.items.len > 0 and !name.is_none()) {
            try builder.named_scratch.append(gpa, .{ .name = name, .child = frame.container });
        }
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

    /// The slot of global `name`, declared once however often it is asked for.
    pub fn global(builder: *ProgramBuilder, name: []const u8) !GlobalSlot {
        assert(name.len > 0);
        const id = try builder.intern(name);
        for (builder.globals.items, 0..) |existing, slot| {
            if (existing.name == id) return .from_int(@intCast(slot));
        }
        try builder.globals.append(builder.gpa, .{ .name = id });
        assert(builder.globals.items.len > 0);
        return .from_int(@intCast(builder.globals.items.len - 1));
    }

    /// A `VAR?` read of `name`, resolved in `finish`.
    pub fn add_variable_get(builder: *ProgramBuilder, name: []const u8) !void {
        assert(builder.frames.items.len > 0);
        assert(name.len > 0);
        const id = try builder.intern(name);
        try builder.variable_fixups.append(builder.gpa, .{
            .container = builder.current(),
            .position = builder.content_count(),
            .name = id,
        });
        try builder.add(.temp_get, id);
    }

    /// A re-assignment of `name` (ink's `"VAR=": name, "re": true`), which ink writes for
    /// temps and globals alike: a global assignment if `name` is a declared global, resolved
    /// in `finish`, else a temp assignment.
    pub fn add_variable_assign(builder: *ProgramBuilder, name: []const u8) !void {
        assert(builder.frames.items.len > 0);
        assert(name.len > 0);
        const id = try builder.intern(name);
        try builder.variable_fixups.append(builder.gpa, .{
            .container = builder.current(),
            .position = builder.content_count(),
            .name = id,
            .kind = .assign,
        });
        try builder.add(.temp_assign, id);
    }

    /// A list literal of items named `origin.item`, with the origins it was declared with.
    pub fn add_list_literal(
        builder: *ProgramBuilder,
        items: []const []const u8,
        origins: []const []const u8,
    ) !void {
        // ink writes origins only for empty lists, which have no items to name them.
        assert(items.len + origins.len < std.math.maxInt(u32));
        const gpa = builder.gpa;
        const record = try builder.extra.add(gpa, instruction_module.ListLiteral{
            .items_count = @intCast(items.len),
            .origins_count = @intCast(origins.len),
        });
        const names_first: u32 = @intCast(builder.list_names.items.len);
        for (items) |item| try builder.list_names.append(gpa, try builder.intern(item));
        for (origins) |origin| try builder.list_names.append(gpa, try builder.intern(origin));
        const words_at = try builder.extra.reserve_words(gpa, @intCast(items.len + origins.len));
        try builder.list_fixups.append(gpa, .{
            .words_at = words_at,
            .names_first = names_first,
            .items_count = @intCast(items.len),
            .origins_count = @intCast(origins.len),
        });
        try builder.add(.list, @fromBackingInt(@intCast(record)));
        assert(words_at == record + 2);
    }

    pub const ListItemDeclaration = struct { name: []const u8, value: i32 };

    /// Declares list `name` with its items, in declaration order.
    pub fn list_origin(
        builder: *ProgramBuilder,
        name: []const u8,
        items: []const ListItemDeclaration,
    ) !ListOriginIndex {
        assert(name.len > 0);
        const gpa = builder.gpa;
        const origin: ListOriginIndex = .from_int(@intCast(builder.list_origins.items.len));
        const first: index.ListItemIndex = .from_int(@intCast(builder.list_items.items.len));
        for (items) |item| {
            var buffer: [1024]u8 = undefined;
            const full_name = try std.fmt.bufPrint(&buffer, "{s}.{s}", .{ name, item.name });
            try builder.list_items.append(gpa, .{
                .origin = origin,
                .name = try builder.intern(item.name),
                .full_name = try builder.intern(full_name),
                .value = item.value,
            });
        }
        try builder.list_origins.append(gpa, .{
            .name = try builder.intern(name),
            .items_first = first,
            .items_count = @intCast(items.len),
        });
        assert(builder.list_items.items.len == first.to_int() + items.len);
        return origin;
    }

    /// The index of external function `name`, declared once; its fallback is resolved in
    /// `finish`.
    pub fn external(builder: *ProgramBuilder, name: []const u8) !ExternalIndex {
        assert(name.len > 0);
        const id = try builder.intern(name);
        for (builder.externals.items, 0..) |existing, position| {
            if (existing.name == id) return .from_int(@intCast(position));
        }
        try builder.externals.append(builder.gpa, .{ .name = id, .fallback = .none });
        assert(builder.externals.items.len > 0);
        return .from_int(@intCast(builder.externals.items.len - 1));
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
        try builder.add(.divert, @fromBackingInt(@intCast(at)));
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
        try builder.add(.divert, @fromBackingInt(@intCast(at)));
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
        try builder.add(.choice_point, @fromBackingInt(@intCast(at)));
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

    /// `add_divert` to a keyed target. `check_path`, when given, is resolved too and must
    /// name the same target (the compiler passes it in Debug).
    pub fn add_divert_to(
        builder: *ProgramBuilder,
        target: KeyTarget,
        check_path: ?[]const u8,
        flags: instruction_module.DivertFlags,
    ) !void {
        assert(target.key != no_key);
        assert(!flags.variable);
        const at = try builder.extra.add(builder.gpa, instruction_module.Divert{
            .target_container = .none,
            .target_index = 0,
            .name = .none,
            .flags = flags,
        });
        try builder.add_keyed_fixup(.divert, target, check_path, at);
        try builder.add(.divert, @fromBackingInt(@intCast(at)));
    }

    /// `add_choice_point` to a keyed target.
    pub fn add_choice_point_to(
        builder: *ProgramBuilder,
        target: KeyTarget,
        check_path: ?[]const u8,
        flags: instruction_module.ChoiceFlags,
    ) !void {
        assert(builder.frames.items.len > 0);
        assert(target.key != no_key);
        const at = try builder.extra.add(builder.gpa, instruction_module.ChoicePoint{
            .target_container = .none,
            .target_index = 0,
            .flags = flags,
        });
        try builder.add_keyed_fixup(.choice_point, target, check_path, at);
        try builder.add(.choice_point, @fromBackingInt(@intCast(at)));
    }

    /// `add_container_operand` to a keyed target.
    pub fn add_container_operand_to(
        builder: *ProgramBuilder,
        comptime opcode: Opcode,
        target: KeyTarget,
        check_path: ?[]const u8,
    ) !void {
        assert(target.key != no_key);
        comptime assert(instruction_module.operand_kind(opcode) == .container);
        const position = builder.content_count();
        try builder.add_keyed_fixup(.container_operand, target, check_path, position);
        try builder.add(opcode, .none);
    }

    fn add_keyed_fixup(
        builder: *ProgramBuilder,
        kind: @FieldType(Fixup, "kind"),
        target: KeyTarget,
        check_path: ?[]const u8,
        at: u32,
    ) !void {
        assert(builder.frames.items.len > 0);
        assert(target.index != no_index);
        const first: u32 = @intCast(builder.path_bytes.items.len);
        if (check_path) |path| try builder.path_bytes.appendSlice(builder.gpa, path);
        try builder.fixups.append(builder.gpa, .{
            .kind = kind,
            .path_first = first,
            .path_length = if (check_path) |path| @intCast(path.len) else 0,
            .container = builder.current(),
            .at = at,
            .key = target.key,
            .index = target.index orelse no_index,
        });
        assert(builder.fixups.items.len > 0);
    }

    fn add_fixup(
        builder: *ProgramBuilder,
        kind: @FieldType(Fixup, "kind"),
        path: []const u8,
        at: u32,
    ) !void {
        assert(builder.frames.items.len > 0);
        const first: u32 = @intCast(builder.path_bytes.items.len);
        try builder.path_bytes.appendSlice(builder.gpa, path);
        try builder.fixups.append(builder.gpa, .{
            .kind = kind,
            .path_first = first,
            .path_length = @intCast(path.len),
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
        const variables_zone = profile.begin(.builder_resolve_variables);
        try builder.resolve_variables();
        variables_zone.end();
        const lists_zone = profile.begin(.builder_resolve_lists);
        try builder.resolve_lists();
        lists_zone.end();
        const layout_zone = profile.begin(.builder_layout);
        var program = try builder.layout();
        layout_zone.end();
        errdefer program.deinit(builder.gpa);
        const fixups_zone = profile.begin(.builder_fixups);
        try builder.resolve_fixups(&program);
        fixups_zone.end();
        if (builder.diagnostics.items.len > 0) return error.UnresolvedPaths;
        resolve_root_names(&program);
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
            // Parents come first, so their paths exist already.
            info.path = try builder.child_path(info.parent, info.name, info.index_in_parent);
            info.path_hash = path_module.shuffle_hash(builder.strings.get(info.path));
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
        const globals = try builder.globals.toOwnedSlice(gpa);
        errdefer gpa.free(globals);
        const list_origins = try builder.list_origins.toOwnedSlice(gpa);
        errdefer gpa.free(list_origins);
        const list_items = try builder.list_items.toOwnedSlice(gpa);
        errdefer gpa.free(list_items);
        const externals = try builder.externals.toOwnedSlice(gpa);
        errdefer gpa.free(externals);
        // The VM's newline output items point at this string (plan §4.2).
        const newline = try builder.intern("\n");
        var containers = builder.containers;
        builder.containers = .empty;
        const program: Program = .{
            .strings = try builder.strings.freeze(gpa),
            .instructions = instructions.toOwnedSlice(),
            .extra = extra,
            .containers = containers.toOwnedSlice(),
            .named = named_owned,
            .globals = globals,
            .list_origins = list_origins,
            .list_items = list_items,
            .externals = externals,
            .global_declaration = .none,
            .count_slots_count = count_slots,
            .ink_version = builder.ink_version,
            .newline = newline,
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

    fn find_global(builder: *const ProgramBuilder, name: StringId) ?GlobalSlot {
        assert(builder.globals.items.len < std.math.maxInt(u32));
        assert(!name.is_none());
        for (builder.globals.items, 0..) |global_info, slot| {
            if (global_info.name == name) return .from_int(@intCast(slot));
        }
        return null;
    }

    /// A list item by its full name (`origin.item`) or bare name.
    fn find_list_item(builder: *const ProgramBuilder, name: StringId) ?index.ListItemIndex {
        assert(builder.list_items.items.len < std.math.maxInt(u32));
        assert(!name.is_none());
        for (builder.list_items.items, 0..) |item, position| {
            if (item.full_name == name or item.name == name) return .from_int(@intCast(position));
        }
        return null;
    }

    fn find_list_origin(builder: *const ProgramBuilder, name: StringId) ?ListOriginIndex {
        assert(builder.list_origins.items.len < std.math.maxInt(u32));
        assert(!name.is_none());
        for (builder.list_origins.items, 0..) |origin, position| {
            if (origin.name == name) return .from_int(@intCast(position));
        }
        return null;
    }

    /// Rewrites each `VAR?` read now that every global and list item is known.
    fn resolve_variables(builder: *ProgramBuilder) !void {
        const opcodes = builder.finished.items(.opcode);
        const operands = builder.finished.items(.operand);
        for (builder.variable_fixups.items) |fixup| {
            const staged = builder.staged.items[fixup.container.to_int()];
            const at = staged.instructions_first + fixup.position;
            if (fixup.kind == .assign) {
                assert(opcodes[at] == .temp_assign);
                if (builder.find_global(fixup.name)) |slot| {
                    opcodes[at] = .global_assign;
                    operands[at] = @backingInt(slot);
                }
                continue;
            }
            assert(opcodes[at] == .temp_get);
            if (builder.find_global(fixup.name)) |slot| {
                opcodes[at] = .global_get;
                operands[at] = @backingInt(slot);
            } else if (builder.find_list_item(fixup.name)) |item| {
                const origin = builder.list_items.items[item.to_int()].origin;
                const record = try builder.extra.add(builder.gpa, instruction_module.ListLiteral{
                    .items_count = 1,
                    .origins_count = 1,
                });
                // The name it was written with follows (for ink_json.serialize).
                _ = try builder.extra.add_slice(builder.gpa, &.{
                    @backingInt(item),
                    @backingInt(origin),
                    @backingInt(fixup.name),
                });
                opcodes[at] = .list;
                operands[at] = record;
            }
        }
        assert(opcodes.len == builder.finished.len);
    }

    /// Writes the item and origin indices of every list literal.
    fn resolve_lists(builder: *ProgramBuilder) !void {
        assert(builder.frames.items.len == 0);
        const words = builder.extra.words.items;
        for (builder.list_fixups.items) |fixup| {
            const names = builder.list_names.items[fixup.names_first..];
            for (0..fixup.items_count) |offset| {
                const item = builder.find_list_item(names[offset]) orelse
                    return error.UnknownListItem;
                words[fixup.words_at + offset] = @backingInt(item);
            }
            for (0..fixup.origins_count) |offset| {
                const name = names[fixup.items_count + offset];
                const origin = builder.find_list_origin(name) orelse return error.UnknownListOrigin;
                words[fixup.words_at + fixup.items_count + offset] = @backingInt(origin);
            }
        }
        var names_count: u64 = 0;
        for (builder.list_fixups.items) |fixup| {
            names_count += fixup.items_count + fixup.origins_count;
        }
        assert(names_count == builder.list_names.items.len);
    }

    /// ink finds the global declaration and external fallbacks by name at the root.
    fn resolve_root_names(program: *Program) void {
        assert(program.containers.len > 0);
        program.global_declaration = program.named_child(Program.root, "global decl") orelse .none;
        const externals: []program_module.ExternalInfo = @constCast(program.externals);
        for (externals) |*info| {
            const name = program.strings.get(info.name);
            info.fallback = program.named_child(Program.root, name) orelse .none;
        }
        assert(program.global_declaration.is_none() or program.global_declaration.to_int() > 0);
    }

    fn resolve_fixups(builder: *ProgramBuilder, program: *Program) !void {
        assert(program.containers.len == builder.staged.items.len);
        const extra: []u32 = @constCast(program.extra);
        for (builder.fixups.items) |fixup| {
            if (fixup.key != no_key) {
                const target = builder.resolve_key(program, fixup) orelse {
                    try builder.report(.unresolved_path, fixup, builder.fixup_text(fixup));
                    continue;
                };
                if (fixup.path_length > 0) {
                    check_keyed(program, fixup, target, builder.path_of(fixup));
                }
                try builder.apply(program, extra, fixup, target);
                continue;
            }
            const text = builder.path_of(fixup);
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

    /// A keyed target, found as `path.resolve` finds the last component of a path to it.
    fn resolve_key(
        builder: *const ProgramBuilder,
        program: *const Program,
        fixup: Fixup,
    ) ?path_module.Target {
        assert(fixup.key != no_key);
        assert(program.containers.len == builder.staged.items.len);
        if (fixup.key >= builder.keys.items.len) return null;
        const container = builder.keys.items[fixup.key];
        if (container.is_none()) return null;
        var target: path_module.Target = .{
            .container = container,
            .content_index = null,
            .approximate = false,
        };
        if (fixup.index == no_index) return target;
        if (fixup.index >= program.content_count(container)) return null;
        if (program.container_at(container, fixup.index)) |child| {
            target.container = child;
        } else target.content_index = fixup.index;
        return target;
    }

    /// The keyed target equals the target of the path written for it (Debug's check).
    fn check_keyed(
        program: *const Program,
        fixup: Fixup,
        target: path_module.Target,
        text: []const u8,
    ) void {
        assert(text.len > 0);
        assert(fixup.key != no_key);
        const parsed = path_module.Path.parse(text, path_components_max) catch unreachable;
        const origin: path_module.Origin = .{ .container = fixup.container, .from_content = true };
        const by_path = path_module.resolve(program, origin, parsed) catch unreachable;
        assert(!by_path.approximate);
        assert(by_path.container == target.container);
        assert(std.meta.eql(by_path.content_index, target.content_index));
    }

    fn path_of(builder: *const ProgramBuilder, fixup: Fixup) []const u8 {
        assert(fixup.path_first + fixup.path_length <= builder.path_bytes.items.len);
        assert(builder.fixups.items.len > 0);
        return builder.path_bytes.items[fixup.path_first..][0..fixup.path_length];
    }

    /// A fixup's path, or a placeholder for a keyed one without (for diagnostics).
    fn fixup_text(builder: *const ProgramBuilder, fixup: Fixup) []const u8 {
        assert(fixup.key != no_key or fixup.path_length > 0);
        assert(builder.fixups.items.len > 0);
        return if (fixup.path_length == 0) "(keyed target)" else builder.path_of(fixup);
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
                extra[fixup.at] = @backingInt(target.container);
                extra[fixup.at + 1] = position;
            },
            .container_operand => {
                if (target.content_index != null) {
                    const text = builder.fixup_text(fixup);
                    try builder.report(.divert_target_not_a_container, fixup, text);
                    return;
                }
                const info = program.table().get(fixup.container);
                const at = info.instruction_first.to_int() + fixup.at;
                program.instructions.items(.operand)[at] = @backingInt(target.container);
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
        assert(text.len > 0);
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
    const divert_at = @backingInt(program.instruction_at(Program.root, 3).get(.divert));
    const divert = extra_module.get(instruction_module.Divert, program.extra, divert_at).data;
    try std.testing.expectEqual(ContainerIndex.from_int(3), divert.target_container);
    const knot: ContainerIndex = .from_int(2);
    const stitch: ContainerIndex = .from_int(3);
    try std.testing.expectEqual(stitch, program.instruction_at(knot, 0).get(.read_count));
    const back_at = @backingInt(program.instruction_at(stitch, 0).get(.divert));
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

test "globals, lists, externals and the global declaration" {
    // Goal: P2.5. Method: a story shaped like ink's JSON for
    //   VAR mood = 1  LIST colours = red, (green), blue = 5  EXTERNAL roll()  and a fallback
    //   function `roll`, then look everything up.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    const mood = try builder.global("mood");
    try builder.add(.global_get, mood);
    const roll = try builder.external("roll");
    const call = try builder.extra.add(gpa, instruction_module.ExternalCall{
        .external = roll,
        .arguments_count = 0,
        .conditional = false,
    });
    try builder.add(.call_external, @fromBackingInt(@intCast(call)));
    _ = try builder.list_origin("colours", &.{
        .{ .name = "red", .value = 1 },
        .{ .name = "green", .value = 2 },
        .{ .name = "blue", .value = 5 },
    });
    _ = try builder.begin_container(.{ .name = "global decl", .named_only = true });
    try builder.add(.integer, 1);
    try builder.add(.global_declare, mood);
    try builder.end_container();
    _ = try builder.begin_container(.{ .name = "roll", .named_only = true });
    try builder.add(.integer, 4);
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    try std.testing.expectEqual(mood, program.global_by_name("mood").?);
    try std.testing.expectEqual(@as(?GlobalSlot, null), program.global_by_name("missing"));
    const blue = program.list_item_by_name("colours.blue").?;
    try std.testing.expectEqual(@as(i32, 5), program.list_items[blue.to_int()].value);
    try std.testing.expectEqual(blue, program.list_item_by_name("blue").?);
    const declaration = program.named_child(Program.root, "global decl").?;
    try std.testing.expectEqual(declaration, program.global_declaration);
    const fallback = program.externals[program.external_by_name("roll").?.to_int()].fallback;
    try std.testing.expectEqual(program.named_child(Program.root, "roll").?, fallback);
}

test "check catches bad global and list tables" {
    // Goal: negative space for P2.5. Method: a global operand past the table, then list items
    // whose origin doesn't own them.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.global_get, try builder.global("x"));
    _ = try builder.list_origin("letters", &.{
        .{ .name = "a", .value = 1 },
        .{ .name = "b", .value = 2 },
    });
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    program.instructions.items(.operand)[0] = 1;
    try std.testing.expectEqual(Program.Fault.global_out_of_range, program.check());
    program.instructions.items(.operand)[0] = 0;
    const items: []program_module.ListItem = @constCast(program.list_items);
    items[1].origin = .from_int(1);
    try std.testing.expectEqual(Program.Fault.list_item_origin_mismatch, program.check());
}

test "VAR? reads resolve to globals, list items or temps" {
    // Goal: ink's lookup order, after everything is declared. Method: three reads made before
    // the global and the list exist.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add_variable_get("score");
    try builder.add_variable_get("blue");
    try builder.add_variable_get("local");
    try builder.add_list_literal(&.{ "colours.red", "colours.blue" }, &.{"colours"});
    _ = try builder.global("score");
    _ = try builder.list_origin(
        "colours",
        &.{ .{ .name = "red", .value = 1 }, .{ .name = "blue", .value = 2 } },
    );
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    const opcodes = program.instructions.items(.opcode);
    try std.testing.expectEqualSlices(Opcode, &.{ .global_get, .list, .temp_get, .list }, opcodes);
    const literal_at = program.instructions.items(.operand)[3];
    const literal = extra_module.get(instruction_module.ListLiteral, program.extra, literal_at);
    try std.testing.expectEqual(@as(u32, 2), literal.data.items_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, program.extra[literal.end..][0..3]);
}

test "names and flags can arrive at a container's end" {
    // Goal: ink's JSON gives #n and #f last. Method: name and flag a nested container after
    // its content, then check its path, named entry and count slot.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    _ = try builder.begin_container(.{});
    try builder.add(.done, {});
    try builder.set_name("g-0");
    builder.set_flags(.{ .visits_counted = true });
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    try std.testing.expectEqualStrings(
        "g-0",
        program.strings.get(program.containers.items(.path)[1]),
    );
    try std.testing.expectEqual(
        ContainerIndex.from_int(1),
        program.named_child(Program.root, "g-0").?,
    );
    try std.testing.expectEqual(@as(u32, 0), program.containers.items(.count_slot)[1]);
}
