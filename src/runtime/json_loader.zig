const std = @import("std");
const value = @import("value.zig");

pub const Container = value.Container;
pub const RuntimeObject = value.RuntimeObject;
pub const ControlCommand = value.ControlCommand;
pub const NativeFunction = value.NativeFunction;
pub const ContainerFlags = value.ContainerFlags;
pub const Divert = value.Divert;
pub const PushPopType = value.PushPopType;

pub const LoadedStory = struct {
    root: *Container,
    ink_version: u32,
    list_defs_json: std.json.Value,
};

/// Load an ink.json story from text. `arena` owns all allocations for the container tree.
pub fn loadStory(arena: std.mem.Allocator, json_text: []const u8) !LoadedStory {
    // Strip UTF-8 BOM if present (some older Inklecate versions emit it)
    const text = if (std.mem.startsWith(u8, json_text, "\xEF\xBB\xBF")) json_text[3..] else json_text;
    // parseFromSliceLeaky is ideal with an ArenaAllocator — no separate Parsed wrapper needed
    const root_val = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});

    if (root_val != .object) return error.InvalidInkJson;
    const obj = root_val.object;

    const version_val = obj.get("inkVersion") orelse return error.MissingInkVersion;
    const ink_version: u32 = @intCast(version_val.integer);

    const root_json = obj.get("root") orelse return error.MissingRoot;
    if (root_json != .array) return error.InvalidRoot;

    const list_defs = obj.get("listDefs") orelse std.json.Value{ .object = std.json.ObjectMap.init(arena) };

    const root_container = try parseContainer(arena, root_json, null, null, "");

    return LoadedStory{
        .root = root_container,
        .ink_version = ink_version,
        .list_defs_json = list_defs,
    };
}

const ParseError = std.mem.Allocator.Error || error{
    ExpectedContainerArray,
    UnparseableNumber,
    UnknownObjectFormat,
};

fn parseContainer(
    arena: std.mem.Allocator,
    json_val: std.json.Value,
    parent: ?*Container,
    name: ?[]const u8,
    path: []const u8,
) ParseError!*Container {
    if (json_val != .array) return error.ExpectedContainerArray;
    const arr = json_val.array.items;

    var flags = ContainerFlags{};
    var container_name: ?[]const u8 = name;
    var named_content: std.StringHashMapUnmanaged(*Container) = .{};
    var content_end = arr.len;

    // Last element is metadata if it is null or object
    if (arr.len > 0) {
        const last = arr[arr.len - 1];
        if (last == .null) {
            content_end = arr.len - 1;
        } else if (last == .object) {
            content_end = arr.len - 1;
            if (last.object.get("#f")) |fv| {
                flags = @bitCast(@as(u8, @intCast(fv.integer)));
            }
            if (last.object.get("#n")) |nv| {
                container_name = try arena.dupe(u8, nv.string);
            }
            // Other keys are named sub-containers
            var it = last.object.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (std.mem.eql(u8, k, "#f") or std.mem.eql(u8, k, "#n")) continue;
                const child_path = if (path.len > 0)
                    try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, k })
                else
                    try arena.dupe(u8, k);
                const child = try parseContainer(arena, entry.value_ptr.*, null, k, child_path);
                try named_content.put(arena, try arena.dupe(u8, k), child);
            }
        }
    }

    // Parse content items
    var content = try std.ArrayList(RuntimeObject).initCapacity(arena, content_end);
    errdefer content.deinit(arena);

    for (arr[0..content_end], 0..) |item, idx| {
        var obj = try parseRuntimeObject(arena, item, path, idx);
        // Named inline containers (with #n) also go into named_content
        if (obj == .container) {
            if (obj.container.name) |cname| {
                // Named containers get path based on name, not index
                obj.container.path = if (path.len > 0)
                    try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, cname })
                else
                    try arena.dupe(u8, cname);
                try named_content.put(arena, cname, obj.container);
            }
            obj.container.index_in_parent = @intCast(idx);
        }
        try content.append(arena, obj);
    }

    const c = try arena.create(Container);
    c.* = .{
        .name = container_name,
        .content = try content.toOwnedSlice(arena),
        .named_content = named_content,
        .flags = flags,
        .path = path,
        .parent = parent,
        .index_in_parent = -1,
    };

    // Set parent pointers for content containers
    for (c.content) |*item| {
        if (item.* == .container) item.container.parent = c;
    }
    // Set parent pointers for named containers
    var nit = c.named_content.iterator();
    while (nit.next()) |entry| {
        entry.value_ptr.*.parent = c;
    }

    return c;
}

fn parseRuntimeObject(
    arena: std.mem.Allocator,
    val: std.json.Value,
    parent_path: []const u8,
    idx: usize,
) ParseError!RuntimeObject {
    switch (val) {
        .null => return .void,
        .bool => |b| return .{ .bool = b },
        .integer => |n| return .{ .int = n },
        .float => |f| return .{ .float = f },
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .int = n } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
            return error.UnparseableNumber;
        },
        .string => |s| return parseStringObject(s),
        .array => {
            const child_path = if (parent_path.len > 0)
                try std.fmt.allocPrint(arena, "{s}.{}", .{ parent_path, idx })
            else
                try std.fmt.allocPrint(arena, "{}", .{idx});
            const c = try parseContainer(arena, val, null, null, child_path);
            return .{ .container = c };
        },
        .object => |obj| return try parseObjectRuntimeObject(arena, obj),
    }
}

fn parseStringObject(s: []const u8) RuntimeObject {
    if (s.len > 0 and s[0] == '^') return .{ .string = s[1..] };
    if (std.mem.eql(u8, s, "\n")) return .{ .string = "\n" };
    if (std.mem.eql(u8, s, "<>")) return .glue;
    if (std.mem.eql(u8, s, "void")) return .void;
    if (ControlCommand.fromString(s)) |cmd| return .{ .control_command = cmd };
    if (NativeFunction.fromString(s)) |func| return .{ .native_function = func };
    return .{ .string = s };
}

fn parseObjectRuntimeObject(arena: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!RuntimeObject {
    if (obj.get("->")) |t| {
        return .{ .divert = .{
            .target = try arena.dupe(u8, t.string),
            .is_conditional = obj.get("c") != null,
            .is_variable = obj.get("var") != null,
            .push_pop_type = null,
            .external_args = 0,
        } };
    }
    if (obj.get("->t->")) |t| {
        return .{ .divert = .{
            .target = try arena.dupe(u8, t.string),
            .is_conditional = obj.get("c") != null,
            .is_variable = obj.get("var") != null,
            .push_pop_type = .tunnel,
            .external_args = 0,
        } };
    }
    if (obj.get("f()")) |t| {
        return .{ .divert = .{
            .target = try arena.dupe(u8, t.string),
            .is_conditional = obj.get("c") != null,
            .is_variable = obj.get("var") != null,
            .push_pop_type = .function,
            .external_args = 0,
        } };
    }
    if (obj.get("x()")) |t| {
        const args: u32 = if (obj.get("exArgs")) |a| @intCast(a.integer) else 0;
        return .{ .divert = .{
            .target = try arena.dupe(u8, t.string),
            .is_conditional = false,
            .is_variable = false,
            .push_pop_type = .function,
            .external_args = args,
        } };
    }
    if (obj.get("*")) |p| {
        const flags: u8 = if (obj.get("flg")) |f| @intCast(f.integer) else 0;
        return .{ .choice_point = .{
            .path = try arena.dupe(u8, p.string),
            .flags = flags,
        } };
    }
    if (obj.get("VAR=")) |n| {
        return .{ .variable_assignment = .{
            .name = try arena.dupe(u8, n.string),
            .is_new_decl = obj.get("re") == null,
            .is_global = true,
        } };
    }
    if (obj.get("temp=")) |n| {
        return .{ .variable_assignment = .{
            .name = try arena.dupe(u8, n.string),
            .is_new_decl = obj.get("re") == null,
            .is_global = false,
        } };
    }
    if (obj.get("VAR?")) |n| {
        return .{ .variable_reference = .{
            .name = try arena.dupe(u8, n.string),
            .path_for_count = null,
        } };
    }
    if (obj.get("CNT?")) |p| {
        return .{ .variable_reference = .{
            .name = "",
            .path_for_count = try arena.dupe(u8, p.string),
        } };
    }
    if (obj.get("^->")) |p| {
        return .{ .divert_target = try arena.dupe(u8, p.string) };
    }
    if (obj.get("^var")) |n| {
        const ctx: i32 = if (obj.get("ci")) |ci| @intCast(ci.integer) else 0;
        return .{ .variable_pointer = .{
            .name = try arena.dupe(u8, n.string),
            .context_index = ctx,
        } };
    }
    // inkVersion 20: inline tag objects {"#":"tag_text"} — stored as void (tags not captured)
    if (obj.get("#")) |_| {
        return .void;
    }
    if (obj.get("list")) |list_val| {
        const ink_list = try arena.create(value.InkList);
        ink_list.* = .{};
        if (list_val == .object) {
            var it = list_val.object.iterator();
            while (it.next()) |entry| {
                const key = try arena.dupe(u8, entry.key_ptr.*);
                const v: i32 = switch (entry.value_ptr.*) {
                    .integer => |n| @intCast(n),
                    .float => |f| @intFromFloat(f),
                    else => 0,
                };
                try ink_list.items.put(arena, key, v);
            }
        }
        if (obj.get("origins")) |origins_val| {
            if (origins_val == .array) {
                const origins = try arena.alloc([]const u8, origins_val.array.items.len);
                for (origins_val.array.items, 0..) |o, i| {
                    origins[i] = if (o == .string) try arena.dupe(u8, o.string) else "";
                }
                ink_list.origins = origins;
            }
        }
        return .{ .list = ink_list };
    }
    return error.UnknownObjectFormat;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn readFixture(alloc: std.mem.Allocator, comptime rel_path: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/compiled/" ++ rel_path, alloc, .limited(1024 * 1024));
}

test "loadStory hello_world" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/misc/hello_world.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);
    try std.testing.expectEqual(@as(u32, 21), loaded.ink_version);

    // Root has 2 content items: inner container + done
    try std.testing.expectEqual(@as(usize, 2), loaded.root.content.len);
    try std.testing.expect(loaded.root.content[0] == .container);
    try std.testing.expectEqual(ControlCommand.done, loaded.root.content[1].control_command);

    // Inner container has at least "Hello world" and "\n"
    const inner = loaded.root.content[0].container;
    try std.testing.expectEqualStrings("Hello world", inner.content[0].string);
    try std.testing.expectEqualStrings("\n", inner.content[1].string);
}

test "loadStory arithmetic" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/evaluation/arithmetic.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);
    const inner = loaded.root.content[0].container;
    try std.testing.expectEqual(ControlCommand.eval_start, inner.content[0].control_command);
    try std.testing.expectEqual(@as(i64, 2), inner.content[1].int);
    try std.testing.expectEqual(@as(i64, 3), inner.content[2].int);
    try std.testing.expectEqual(NativeFunction.multiply, inner.content[3].native_function);
}

test "loadStory basic_tunnel named content" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/diverts/basic_tunnel.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);
    try std.testing.expect(loaded.root.named_content.get("f") != null);
}

test "loadStory list_basic_operations listDefs" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/lists/list_basic_operations.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);

    // listDefs raw JSON has key "list" with 5 entries (a=1, b=2, c=3, d=4, e=5)
    try std.testing.expect(loaded.list_defs_json == .object);
    const list_def = loaded.list_defs_json.object.get("list") orelse {
        return error.MissingListDef;
    };
    try std.testing.expect(list_def == .object);
    try std.testing.expectEqual(@as(usize, 5), list_def.object.count());
    try std.testing.expectEqual(@as(i64, 1), list_def.object.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 5), list_def.object.get("e").?.integer);
}

// ── TASK-21: Container path assignment tests ──────────────────────────────────

test "Container paths hello_world" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/misc/hello_world.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);

    // Root has path ""
    try std.testing.expectEqualStrings("", loaded.root.path);
    try std.testing.expect(loaded.root.parent == null);

    // Inner container at index 0 has path "0"
    const inner = loaded.root.content[0].container;
    try std.testing.expectEqualStrings("0", inner.path);
    try std.testing.expect(inner.parent == loaded.root);

    // Named container "g-0" inside inner has path "0.g-0"
    const g0 = inner.named_content.get("g-0") orelse return error.MissingContainer;
    try std.testing.expectEqualStrings("0.g-0", g0.path);
    try std.testing.expect(g0.parent == inner);
}

test "Container paths basic_tunnel" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/diverts/basic_tunnel.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);

    // Named container "f" at root level has path "f"
    const f = loaded.root.named_content.get("f") orelse return error.MissingContainer;
    try std.testing.expectEqualStrings("f", f.path);
    try std.testing.expect(f.parent == loaded.root);
}

test "Container paths global decl" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "runtime/variables/const.ink.json");
    defer alloc.free(json);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const loaded = try loadStory(arena.allocator(), json);

    // "global decl" container has path "global decl"
    const gd = loaded.root.named_content.get("global decl") orelse return error.MissingContainer;
    try std.testing.expectEqualStrings("global decl", gd.path);
    try std.testing.expect(gd.parent == loaded.root);
}
