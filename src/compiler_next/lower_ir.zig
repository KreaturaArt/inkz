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
    assignment: Assignment,
    variable_pointer: VariablePointer,
    choice_point: ChoicePoint,
    list: List,
};

pub const ChoicePoint = struct { target: Target, flags: u8 };
pub const Assignment = struct { name: []const u8, global: bool, new: bool };
pub const VariablePointer = struct { name: []const u8, context: i32 };
pub const List = struct { items: []const ListItem, origins: []const []const u8 };

/// How an item is stored: 24 bytes, the larger payloads in side arrays (plan P8.6).
const Stored = union(enum) {
    container: ContainerId,
    command: Command,
    native: []const u8,
    text: []const u8,
    integer: i32,
    float: f32,
    boolean: bool,
    divert: u32,
    divert_target: Target,
    variable_reference: []const u8,
    read_count: Target,
    assignment: u32,
    variable_pointer: u32,
    choice_point: ChoicePoint,
    list: u32,
};

comptime {
    assert(@sizeOf(Stored) <= 24);
}

/// ink's container flags (Runtime.Container.CountFlags).
pub const count_visits: u8 = 1;
pub const count_turns: u8 = 2;
pub const count_start_only: u8 = 4;

pub const Container = struct {
    name: ?[]const u8 = null,
    flags: u8 = 0,
    /// While generating, the content is a list linked through `Ir.next` (no buffer per
    /// container); after flattening it is `Ir.flat[flat_first..][0..flat_count]`.
    first: ItemId = .none,
    last: ItemId = .none,
    flat_first: u32 = 0,
    flat_count: u32 = 0,
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
    items: std.ArrayList(Stored) = .empty,
    /// The next item in the same container (none at the end).
    next: std.ArrayList(ItemId) = .empty,
    /// Whether an item is in a container (an item is in at most one).
    placed: std.ArrayList(bool) = .empty,
    /// Every kept container's content after flattening, one run per container.
    flat: std.ArrayList(ItemId) = .empty,
    diverts: std.ArrayList(Divert) = .empty,
    assignments: std.ArrayList(Assignment) = .empty,
    pointers: std.ArrayList(VariablePointer) = .empty,
    lists: std.ArrayList(List) = .empty,

    pub fn init(gpa: Allocator) Ir {
        assert(@sizeOf(Container) > 0);
        assert(@sizeOf(Item) > 0);
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ir: *Ir) void {
        assert(ir.items.items.len < std.math.maxInt(u32));
        const gpa = ir.gpa;
        assert(ir.containers.items.len < std.math.maxInt(u32));
        for (ir.containers.items) |*entry| entry.named.deinit(gpa);
        ir.next.deinit(gpa);
        ir.placed.deinit(gpa);
        ir.flat.deinit(gpa);
        ir.containers.deinit(gpa);
        ir.items.deinit(gpa);
        ir.diverts.deinit(gpa);
        ir.assignments.deinit(gpa);
        ir.pointers.deinit(gpa);
        ir.lists.deinit(gpa);
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
        return switch (ir.items.items[id.to_int()]) {
            .divert => |at| .{ .divert = ir.diverts.items[at] },
            .assignment => |at| .{ .assignment = ir.assignments.items[at] },
            .variable_pointer => |at| .{ .variable_pointer = ir.pointers.items[at] },
            .list => |at| .{ .list = ir.lists.items[at] },
            inline else => |payload, tag| @unionInit(Item, @tagName(tag), payload),
        };
    }

    /// A divert item's divert, to set its target later.
    pub fn divert_of(ir: *Ir, id: ItemId) *Divert {
        assert(id.to_int() < ir.items.items.len);
        const at = ir.items.items[id.to_int()].divert;
        assert(at < ir.diverts.items.len);
        return &ir.diverts.items[at];
    }

    fn store(ir: *Ir, value: Item) !Stored {
        const gpa = ir.gpa;
        assert(ir.diverts.items.len < std.math.maxInt(u32));
        assert(ir.lists.items.len < std.math.maxInt(u32));
        switch (value) {
            .divert => |divert| {
                try ir.diverts.append(gpa, divert);
                return .{ .divert = @intCast(ir.diverts.items.len - 1) };
            },
            .assignment => |assignment| {
                try ir.assignments.append(gpa, assignment);
                return .{ .assignment = @intCast(ir.assignments.items.len - 1) };
            },
            .variable_pointer => |pointer| {
                try ir.pointers.append(gpa, pointer);
                return .{ .variable_pointer = @intCast(ir.pointers.items.len - 1) };
            },
            .list => |list| {
                try ir.lists.append(gpa, list);
                return .{ .list = @intCast(ir.lists.items.len - 1) };
            },
            inline else => |payload, tag| return @unionInit(Stored, @tagName(tag), payload),
        }
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
        try ir.items.append(ir.gpa, try ir.store(value));
        try ir.next.append(ir.gpa, .none);
        try ir.placed.append(ir.gpa, false);
        assert(ir.items.items.len == id.to_int() + 1);
        return id;
    }

    /// Container.AddContent.
    pub fn add(ir: *Ir, to: ContainerId, value: Item) !ItemId {
        assert(ir.items.items.len < std.math.maxInt(u32));
        assert(to.to_int() < ir.containers.items.len);
        const id = try ir.new_item(value);
        try ir.attach(to, id);
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

    /// Container.InsertContent at the start (the only position ink inserts at).
    pub fn insert(ir: *Ir, to: ContainerId, position: usize, value: Item) !ItemId {
        assert(position == 0);
        assert(to.to_int() < ir.containers.items.len);
        const id = try ir.new_item(value);
        ir.placed.items[id.to_int()] = true;
        const container_entry = ir.container(to);
        ir.next.items[id.to_int()] = container_entry.first;
        container_entry.first = id;
        if (container_entry.last.is_none()) container_entry.last = id;
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
        const source = ir.container(from);
        if (source.first.is_none()) return;
        const first = source.first;
        const last = source.last;
        source.first = .none;
        source.last = .none;
        const target = ir.container(to);
        if (target.last.is_none()) {
            target.first = first;
        } else ir.next.items[target.last.to_int()] = first;
        target.last = last;
        assert(!ir.container(to).first.is_none());
    }

    /// Adds an item made earlier; one already in a container is copied (as ink copies a
    /// constant's runtime objects each time it is used).
    pub fn attach_or_copy(ir: *Ir, to: ContainerId, id: ItemId) !void {
        assert(id.to_int() < ir.items.items.len);
        assert(to.to_int() < ir.containers.items.len);
        if (!ir.placed.items[id.to_int()]) return ir.attach(to, id);
        _ = try ir.add(to, ir.item(id));
    }

    /// The content of a container after flattening.
    pub fn content_of(ir: *const Ir, id: ContainerId) []const ItemId {
        assert(id.to_int() < ir.containers.items.len);
        const entry = ir.containers.items[id.to_int()];
        assert(entry.flat_first + entry.flat_count <= ir.flat.items.len);
        return ir.flat.items[entry.flat_first..][0..entry.flat_count];
    }

    /// A name or text for an item: names are slices of the source, which outlives the IR,
    /// so nothing is copied.
    pub fn text(ir: *Ir, value: []const u8) ![]const u8 {
        assert(ir.items.items.len < std.math.maxInt(u32));
        assert(value.len < std.math.maxInt(u32));
        return value;
    }

    /// Adds an existing (unplaced) item to the end of a container's content.
    pub fn attach(ir: *Ir, to: ContainerId, id: ItemId) !void {
        assert(id.to_int() < ir.items.items.len);
        assert(!ir.placed.items[id.to_int()]);
        ir.placed.items[id.to_int()] = true;
        ir.next.items[id.to_int()] = .none;
        const entry = ir.container(to);
        if (entry.last.is_none()) entry.first = id else ir.next.items[entry.last.to_int()] = id;
        entry.last = id;
    }

    /// Each target that is a parsed object becomes that object's runtime container (from
    /// `containers`, by object), so emission needs nothing from the object tree.
    pub fn resolve_objects(ir: *Ir, containers: []const ContainerId) void {
        assert(ir.items.items.len < std.math.maxInt(u32));
        assert(ir.diverts.items.len <= ir.items.items.len);
        for (ir.diverts.items) |*divert| divert.target = resolved(divert.target, containers);
        for (ir.items.items) |*stored| switch (stored.*) {
            .divert_target, .read_count => |*target| target.* = resolved(target.*, containers),
            .choice_point => |*choice| choice.target = resolved(choice.target, containers),
            else => {},
        };
    }

    /// Frees the generation links (unused once the content is flattened) and shrinks the
    /// other arrays to their sizes.
    pub fn release_links(ir: *Ir) void {
        assert(ir.next.items.len == ir.items.items.len);
        assert(ir.flat.items.len <= ir.items.items.len);
        const gpa = ir.gpa;
        ir.next.clearAndFree(gpa);
        ir.placed.clearAndFree(gpa);
        ir.items.shrinkAndFree(gpa, ir.items.items.len);
        ir.flat.shrinkAndFree(gpa, ir.flat.items.len);
        ir.containers.shrinkAndFree(gpa, ir.containers.items.len);
        ir.diverts.shrinkAndFree(gpa, ir.diverts.items.len);
        for (ir.containers.items) |*entry| {
            entry.first = .none;
            entry.last = .none;
        }
    }
};

fn resolved(target: Target, containers: []const ContainerId) Target {
    assert(containers.len < std.math.maxInt(u32));
    if (target != .object) return target;
    assert(target.object.to_int() < containers.len);
    const container = containers[target.object.to_int()];
    return if (container.is_none()) .none else .{ .container = container };
}

test "commands have ink's words" {
    try std.testing.expectEqualStrings("ev", Command.eval_start.word());
    try std.testing.expectEqualStrings("choiceCnt", Command.choice_count.word());
    try std.testing.expectEqualStrings("<>", Command.glue.word());
}
