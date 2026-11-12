//! The lowering's runtime IR (plan P8.4): ink's Runtime.Container tree as the compiler builds
//! it, before ProgramBuilder. Items have stable ids, so a divert can target an item (ink's
//! rejoin `nop`s) and keep pointing at it through flattening; targets that are parsed objects
//! (knots, labels) are resolved to containers once generation is done, as ink resolves them
//! in ResolveReferences after FlattenContainersIn.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const index = @import("../core/index.zig");
const sema = @import("sema.zig");
const ObjectIndex = sema.ObjectIndex;

pub const ContainerId = index.Index("runtime container");
pub const ItemId = index.Index("runtime item");

/// ink's ControlCommand types (and glue), by their JSON words.
pub const Command = enum {
    eval_start,
    eval_end,
    eval_output,
    pop,
    pop_tunnel,
    pop_function,
    duplicate,
    no_op,
    begin_string,
    end_string,
    void,
    visit_index,
    sequence_shuffle_index,
    start_thread,
    choice_count,
    turns,
    turns_since,
    read_count,
    random,
    seed_random,
    list_from_int,
    list_range,
    list_random,
    begin_tag,
    end_tag,
    done,
    end,
    glue,

    pub fn word(command: Command) []const u8 {
        assert(@backingInt(command) < @typeInfo(Command).@"enum".field_names.len);
        const words = [_][]const u8{
            "ev",   "/ev",  "out",     "pop",   "->->",   "~ret",      "du",   "nop",   "str",
            "/str", "void", "visit",   "seq",   "thread", "choiceCnt", "turn", "turns", "readc",
            "rnd",  "srnd", "listInt", "range", "lrnd",   "#",         "/#",   "done",  "end",
            "<>",
        };
        comptime assert(words.len == @typeInfo(Command).@"enum".field_names.len);
        return words[@backingInt(command)];
    }
};

/// What a divert, divert target or read count points at.
pub const Target = union(enum) {
    none,
    container: ContainerId,
    /// An item's position (container and index, after flattening).
    item: ItemId,
    /// A parsed object's runtime path (ink's runtimePath): a flow's or gather's container, a
    /// choice's inner content container.
    object: ObjectIndex,
};

pub const DivertKind = enum { plain, function, tunnel };

pub const Divert = struct {
    target: Target = .none,
    /// ink's variableDivertName.
    variable: ?[]const u8 = null,
    /// An external function call (ink's isExternal): its name and arguments count.
    external: ?[]const u8 = null,
    external_arguments: u32 = 0,
    kind: DivertKind = .plain,
    conditional: bool = false,
};

pub const ListItem = struct { origin: []const u8, name: []const u8, value: i32 };

pub const Item = union(enum) {
    container: ContainerId,
    command: Command,
    /// A native function call (`+`, `MIN`, ...).
    native: []const u8,
    /// A StringValue: text, "\n", or a string in evaluation.
    text: []const u8,
    integer: i32,
    float: f32,
    boolean: bool,
    divert: Divert,
    divert_target: Target,
    variable_reference: []const u8,
    read_count: Target,
    assignment: struct { name: []const u8, global: bool, new: bool },
    variable_pointer: struct { name: []const u8, context: i32 },
    choice_point: struct { target: Target, flags: u8 },
    list: struct { items: []const ListItem, origins: []const []const u8 },
};

/// ink's container flags (Runtime.Container.CountFlags).
pub const count_visits: u8 = 1;
pub const count_turns: u8 = 2;
pub const count_start_only: u8 = 4;

pub const Container = struct {
    name: ?[]const u8 = null,
    flags: u8 = 0,
    content: std.ArrayList(ItemId) = .empty,
    /// Named children that aren't in `content` (ink's named-only content), in order.
    named: std.ArrayList(ContainerId) = .empty,
    /// After layout: the container holding it (as content or named), or none for the root.
    parent: ContainerId = .none,
};

pub const Ir = struct {
    gpa: Allocator,
    /// Names, texts and list literals.
    arena: std.heap.ArenaAllocator,
    containers: std.ArrayList(Container) = .empty,
    items: std.ArrayList(Item) = .empty,

    pub fn init(gpa: Allocator) Ir {
        assert(@sizeOf(Container) > 0);
        assert(@sizeOf(Item) > 0);
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ir: *Ir) void {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const gpa = ir.gpa;
        assert(ir.containers.items.len < std.math.maxInt(u32));
        for (ir.containers.items) |*entry| {
            entry.content.deinit(gpa);
            entry.named.deinit(gpa);
        }
        ir.containers.deinit(gpa);
        ir.items.deinit(gpa);
        ir.arena.deinit();
        ir.* = undefined;
    }

    pub fn container(ir: *Ir, id: ContainerId) *Container {
        assert(id.to_int() < ir.containers.items.len);
        assert(ir.containers.items.len > 0);
        return &ir.containers.items[id.to_int()];
    }

    pub fn item(ir: *const Ir, id: ItemId) Item {
        assert(id.to_int() < ir.items.items.len);
        assert(ir.items.items.len > 0);
        return ir.items.items[id.to_int()];
    }

    pub fn new_container(ir: *Ir) !ContainerId {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const id: ContainerId = .from_int(@intCast(ir.containers.items.len));
        try ir.containers.append(ir.gpa, .{});
        assert(ir.containers.items.len == id.to_int() + 1);
        return id;
    }

    pub fn new_item(ir: *Ir, value: Item) !ItemId {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const id: ItemId = .from_int(@intCast(ir.items.items.len));
        try ir.items.append(ir.gpa, value);
        assert(ir.items.items.len == id.to_int() + 1);
        return id;
    }

    /// Container.AddContent.
    pub fn add(ir: *Ir, to: ContainerId, value: Item) !ItemId {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const id = try ir.new_item(value);
        try ir.container(to).content.append(ir.gpa, id);
        assert(ir.container(to).content.items.len > 0);
        return id;
    }

    pub fn add_command(ir: *Ir, to: ContainerId, command: Command) !ItemId {
        assert(to.to_int() < ir.containers.items.len);
        assert(@backingInt(command) < @typeInfo(Command).@"enum".field_names.len);
        return ir.add(to, .{ .command = command });
    }

    /// Adds a container as content.
    pub fn add_container(ir: *Ir, to: ContainerId, child: ContainerId) !ItemId {
        assert(to != child);
        assert(child.to_int() < ir.containers.items.len);
        return ir.add(to, .{ .container = child });
    }

    /// Container.InsertContent at `position`.
    pub fn insert(ir: *Ir, to: ContainerId, position: usize, value: Item) !ItemId {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const id = try ir.new_item(value);
        try ir.container(to).content.insert(ir.gpa, position, id);
        assert(position < ir.container(to).content.items.len);
        return id;
    }

    /// Container.AddToNamedContentOnly.
    pub fn add_named(ir: *Ir, to: ContainerId, child: ContainerId) !void {
        assert(ir.container(child).name != null);
        assert(to != child);
        try ir.container(to).named.append(ir.gpa, child);
    }

    /// Container.AddContentsOfContainer: moves `from`'s content into `to`.
    pub fn add_contents_of(ir: *Ir, to: ContainerId, from: ContainerId) !void {
        assert(to != from);
        const moved = ir.container(from).content.items;
        try ir.container(to).content.appendSlice(ir.gpa, moved);
        ir.container(from).content.clearRetainingCapacity();
        assert(ir.container(from).content.items.len == 0);
    }

    pub fn text(ir: *Ir, value: []const u8) ![]const u8 {
        assert(ir.items.items.len < std.math.maxInt(u32));
        assert(value.len < std.math.maxInt(u32));
        return ir.arena.allocator().dupe(u8, value);
    }
};

test "commands have ink's words" {
    try std.testing.expectEqualStrings("ev", Command.eval_start.word());
    try std.testing.expectEqualStrings("choiceCnt", Command.choice_count.word());
    try std.testing.expectEqualStrings("<>", Command.glue.word());
}
