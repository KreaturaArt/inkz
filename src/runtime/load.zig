//! Loading: ink's StoryState.LoadJson for save format versions 8 to 10.
//!
//! The save is parsed with std.json into the state's fixed load scratch
//! (`Limits.load_bytes_max`; std.json's parser keeps its nesting on an explicit stack there,
//! so the scratch bounds the depth too) and read once, into a reset state. A save that fails
//! to load leaves the story as `reset_state` leaves it (C# ink leaves it partly loaded).
//! Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const index = @import("../core/index.zig");
const path_module = @import("../core/path.zig");
const container_module = @import("../core/container.zig");
const value_module = @import("value.zig");
const output_module = @import("output.zig");
const call_stack_module = @import("call_stack.zig");
const state_module = @import("state.zig");
const flows = @import("flows.zig");
const lists_module = @import("lists.zig");
const lookahead = @import("lookahead.zig");
const story_module = @import("story.zig");
const Story = story_module.Story;
const Value = value_module.Value;
const Pointer = call_stack_module.Pointer;
const Item = output_module.Item;
const ContainerIndex = index.ContainerIndex;
const Json = std.json.Value;
const Object = std.json.ObjectMap;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Alignment = std.mem.Alignment;

pub const Error = error{
    /// Not a save ink can load: malformed JSON, a repeated or missing key, a value of the
    /// wrong type.
    InvalidSave,
    /// inkSaveVersion below 8, as ink refuses.
    SaveVersionTooOld,
    /// The save names content the story doesn't have (it changed since the save).
    SaveDoesNotMatchStory,
    /// The save doesn't fit the story's limits.
    SaveTooLarge,
    Reentrant,
};

pub const save_version_min = 8;

/// Loads `json` into the story; on any error but `Reentrant` the story is reset.
pub fn load_json(story: *Story, json: []const u8) Error!void {
    try story_module.begin_mutation(story);
    assert(!lookahead.active(&story.state));
    // reset_state ran at init under the same limits, so it runs again.
    errdefer story.reset_state() catch unreachable;
    const parse_zone = profile.begin(.load_parse);
    var scratch: Scratch = .{ .buffer = .init(story.state.load_scratch) };
    // Numbers stay text, so floats parse as f32 and integers as i32, as they were saved.
    const options: std.json.ParseOptions = .{ .parse_numbers = false };
    const parsed = std.json.parseFromSliceLeaky(Json, scratch.allocator(), json, options);
    parse_zone.end();
    assert(scratch.peak <= story.state.load_scratch.len);
    story.state.peaks.load_bytes = @max(story.state.peaks.load_bytes, scratch.peak);
    const document = parsed catch |err| return switch (err) {
        error.OutOfMemory => error.SaveTooLarge,
        else => error.InvalidSave,
    };
    const commit_zone = profile.begin(.load_commit);
    defer commit_zone.end();
    var loader: Loader = .{ .story = story };
    loader.prepare();
    try loader.document(try as(document, .object));
    story.failed = false;
    story.state.verify();
}

/// The parse's allocator: the scratch's bump allocator, which also keeps its high-water mark
/// (shrinking the last allocation lowers the bump). Frees keep their bytes.
const Scratch = struct {
    buffer: FixedBufferAllocator,
    peak: u32 = 0,

    fn allocator(scratch: *Scratch) std.mem.Allocator {
        assert(scratch.buffer.end_index == 0);
        return .{ .ptr = scratch, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = std.mem.Allocator.noFree,
        } };
    }

    fn alloc(context: *anyopaque, length: usize, alignment: Alignment, caller: usize) ?[*]u8 {
        const scratch: *Scratch = @ptrCast(@alignCast(context));
        defer scratch.peak = @max(scratch.peak, @as(u32, @intCast(scratch.buffer.end_index)));
        return FixedBufferAllocator.alloc(&scratch.buffer, length, alignment, caller);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        length: usize,
        caller: usize,
    ) bool {
        const scratch: *Scratch = @ptrCast(@alignCast(context));
        defer scratch.peak = @max(scratch.peak, @as(u32, @intCast(scratch.buffer.end_index)));
        return FixedBufferAllocator.resize(&scratch.buffer, memory, alignment, length, caller);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        length: usize,
        caller: usize,
    ) ?[*]u8 {
        return if (resize(context, memory, alignment, length, caller)) memory.ptr else null;
    }
};

/// `json`'s payload of kind `kind`; any other kind is not a save.
fn as(json: Json, comptime kind: std.meta.Tag(Json)) Error!@FieldType(Json, @tagName(kind)) {
    if (json != kind) return error.InvalidSave;
    return @field(json, @tagName(kind));
}

fn member(object: Object, key: []const u8) Error!Json {
    return object.get(key) orelse error.InvalidSave;
}

/// ink writes whole floats with `.0`; a number read where an int is expected must be an int.
fn integer(json: Json) Error!i32 {
    const text = try as(json, .number_string);
    return std.fmt.parseInt(i32, text, 10) catch error.InvalidSave;
}

const Loader = struct {
    story: *Story,

    fn state(loader: *Loader) *state_module.State {
        return &loader.story.state;
    }

    /// Resets the state for the load: the defaults, no flows, empty counts, and the heap
    /// compacted to what survives (the defaults).
    fn prepare(loader: *Loader) void {
        assert(!lookahead.active(&loader.story.state));
        assert(loader.story.callback_depth == 0);
        const s = loader.state();
        flows.reset(s);
        s.evaluation.clear();
        s.call_stack.fresh(.start_of(loader.story.program.root_container()));
        s.output.clear();
        s.choices.clear();
        @memcpy(s.globals, s.global_defaults);
        @memset(s.visit_counts, 0);
        @memset(s.turn_indices, state_module.never_visited);
        s.observer_events.clear();
        s.output_stashes_count = 0;
        s.did_safe_exit = false;
        loader.story.diverted_pointer = .null;
        s.compact();
    }

    fn document(loader: *Loader, top: Object) Error!void {
        const version = try integer(try member(top, "inkSaveVersion"));
        if (version < save_version_min) return error.SaveVersionTooOld;
        if (top.get("flows")) |all| {
            try loader.flows_of(top, try as(all, .object));
        } else {
            // Before multi-flow, the one flow's keys are at the top level.
            try loader.flow(top, flows.default_name);
        }
        try loader.variables(try as(try member(top, "variablesState"), .object));
        try loader.evaluation((try as(try member(top, "evalStack"), .array)).items);
        if (top.get("currentDivertTarget")) |target| {
            var pointer = try loader.pointer_at(target);
            if (pointer.index == Pointer.container_self) pointer.index = 0;
            loader.story.diverted_pointer = pointer;
        }
        try loader.counts(try as(try member(top, "visitCounts"), .object), .visits);
        try loader.counts(try as(try member(top, "turnIndices"), .object), .turns);
        const turn = try integer(try member(top, "turnIdx"));
        const seed = try integer(try member(top, "storySeed"));
        // Missing in inkjs saves; ink reads it as 0.
        const previous = if (top.get("previousRandom")) |number| try integer(number) else 0;
        const s = loader.state();
        s.turn_index = turn;
        s.story_seed = seed;
        s.previous_random = previous;
    }

    /// The flows: the current one last, so it ends up in the live buffers.
    ///
    /// The default flow must be there, as every save ink writes from a story has it: ink
    /// writes one flow only while it has no named flows, and that one is the default. A lone
    /// flow with another name (ink would load it as its current flow and treat it as the
    /// default on the next switch) is refused, since here the default flow is always record
    /// 0 by its own name. Each flow name appears once (the parser refuses a repeated key).
    fn flows_of(loader: *Loader, top: Object, all: Object) Error!void {
        const count = all.count();
        if (count == 0) return error.InvalidSave;
        if (count > loader.state().flows.len) return error.SaveTooLarge;
        const current_name = if (count > 1) try member(top, "currentFlowName") else null;
        const current = if (current_name) |name| try as(name, .string) else null;
        if (!all.contains(flows.default_name)) return error.InvalidSave;
        if (current != null and !all.contains(current.?)) return error.InvalidSave;
        for ([_]bool{ false, true }) |want_current| {
            for (all.keys(), all.values()) |name, flow_json| {
                const is_current = current == null or std.mem.eql(u8, name, current.?);
                if (is_current == want_current) {
                    try loader.flow(try as(flow_json, .object), name);
                }
            }
        }
    }

    /// One flow (ink's Flow constructor): loaded into its own buffers, selected as the live
    /// ones. The current flow comes last, so it stays selected.
    fn flow(loader: *Loader, object: Object, name: []const u8) Error!void {
        if (name.len == 0) return error.InvalidSave;
        if (name.len > state_module.flow_name_bytes_max) return error.SaveTooLarge;
        const s = loader.state();
        const record = flows.record_for(s, name) catch return error.SaveTooLarge;
        if (record != s.current_flow) flows.select(s, record);
        s.call_stack.frames.clear();
        s.call_stack.threads.clear();
        s.call_stack.temps.clear();
        s.output.clear();
        s.choices.clear();
        const callstack = object.get("callstack") orelse try member(object, "callstackThreads");
        try loader.call_stack(try as(callstack, .object));
        try loader.output_stream((try as(try member(object, "outputStream"), .array)).items);
        const threads = if (object.get("choiceThreads")) |saved| try as(saved, .object) else null;
        try loader.choices((try as(try member(object, "currentChoices"), .array)).items, threads);
        assert(s.current_flow == record);
    }

    fn call_stack(loader: *Loader, object: Object) Error!void {
        const threads = (try as(try member(object, "threads"), .array)).items;
        const counter = try integer(try member(object, "threadCounter"));
        if (counter < 0) return error.InvalidSave;
        const s = loader.state();
        for (threads) |thread_json| {
            const first = s.call_stack.frames.count;
            const thread = try loader.load_thread(try as(thread_json, .object), .live);
            s.call_stack.threads.push(.{
                .frame_first = first,
                .frame_count = s.call_stack.frames.count - first,
                .counter = thread.counter,
                .previous_pointer = thread.previous,
            }) catch return error.SaveTooLarge;
        }
        if (s.call_stack.threads.count == 0) return error.InvalidSave;
        s.call_stack.thread_counter = @intCast(counter);
    }

    const Destination = enum { live, snapshot };
    const LoadedThread = struct { counter: u32, previous: Pointer };

    /// ink's Thread constructor: frames, their temps, the thread index, the previous pointer.
    fn load_thread(loader: *Loader, object: Object, destination: Destination) Error!LoadedThread {
        const counter = try integer(try member(object, "threadIndex"));
        if (counter < 0) return error.InvalidSave;
        const frames = (try as(try member(object, "callstack"), .array)).items;
        if (frames.len == 0) return error.InvalidSave;
        for (frames) |frame_json| try loader.frame(try as(frame_json, .object), destination);
        var previous: Pointer = .null;
        if (object.get("previousContentObject")) |path| previous = try loader.pointer_at(path);
        return .{ .counter = @intCast(counter), .previous = previous };
    }

    fn frame(loader: *Loader, object: Object, destination: Destination) Error!void {
        const kind_number = try integer(try member(object, "type"));
        if (kind_number < 0 or kind_number > 2) return error.InvalidSave;
        var pointer: Pointer = .null;
        if (object.get("cPath")) |path| {
            const container = try loader.container_at(path);
            const position = try integer(try member(object, "idx"));
            if (position < 0) return error.InvalidSave;
            pointer = .{ .container = container, .index = @intCast(position) };
        }
        const in_expression = switch (try member(object, "exp")) {
            .bool => |flag| flag,
            else => return error.InvalidSave,
        };
        const s = loader.state();
        const frames = if (destination == .live) &s.call_stack.frames else &s.choices.frames;
        const temps = if (destination == .live) &s.call_stack.temps else &s.choices.temps;
        const temps_first = temps.count;
        if (object.get("temp")) |saved| {
            const named = try as(saved, .object);
            for (named.keys(), named.values()) |name_text, value_json| {
                // Temp names are program strings; a name the story doesn't have means it
                // changed.
                const name = loader.story.program.strings.find(name_text) orelse
                    return error.SaveDoesNotMatchStory;
                const value = try loader.load_value(value_json);
                temps.push(.{ .name = name, .value = value }) catch return error.SaveTooLarge;
            }
        }
        const temps_count = temps.count - temps_first;
        if (temps_count > s.limits.temps_per_frame_max) return error.SaveTooLarge;
        frames.push(.{
            .pointer = pointer,
            .temps_first = temps_first,
            .evaluation_height = 0,
            .function_start_in_output = 0,
            .temps_count = @intCast(temps_count),
            .kind = @fromBackingInt(@intCast(@as(u8, @intCast(kind_number)))),
            .in_expression_evaluation = in_expression,
        }) catch return error.SaveTooLarge;
    }

    fn output_stream(loader: *Loader, items: []const Json) Error!void {
        const output = &loader.state().output;
        for (items) |item_json| {
            const item = try loader.output_item(item_json);
            if (item.kind == .begin_string) output.string_marks.push(output.items.count) catch
                return error.SaveTooLarge;
            output.items.push(item) catch return error.SaveTooLarge;
        }
    }

    fn output_item(loader: *Loader, json: Json) Error!Item {
        if (json == .object) {
            const text = try as(try member(json.object, "#"), .string);
            return text_item(try loader.string(text), text, .tag, .non_whitespace);
        }
        const text = try as(json, .string);
        const command: ?output_module.Kind = if (std.mem.eql(u8, text, "<>"))
            .glue
        else if (std.mem.eql(u8, text, "str"))
            .begin_string
        else if (std.mem.eql(u8, text, "#"))
            .begin_tag
        else if (std.mem.eql(u8, text, "/#"))
            .end_tag
        else
            null;
        if (command) |kind| return Item.command(kind);
        if (std.mem.eql(u8, text, "\n")) {
            return text_item(story_module.program_newline(loader.story), text, .text, .newline);
        }
        if (text.len == 0 or text[0] != '^') return error.InvalidSave;
        const reference = try loader.string(text[1..]);
        return text_item(reference, text[1..], .text, .of(text[1..]));
    }

    fn text_item(
        reference: value_module.StringReference,
        text: []const u8,
        kind: output_module.Kind,
        class: output_module.Class,
    ) Item {
        assert(kind == .text or kind == .tag);
        // `string` refused longer text.
        assert(text.len <= std.math.maxInt(u16));
        return .{
            .string = reference,
            .start = 0,
            .kind = kind,
            .class = class,
            .length = @intCast(text.len),
        };
    }

    /// `text` as a new heap string.
    fn string(loader: *Loader, text: []const u8) Error!value_module.StringReference {
        if (text.len > std.math.maxInt(u16)) return error.SaveTooLarge;
        const s = loader.state();
        const reference = s.strings.try_allocate(@intCast(text.len)) orelse
            return error.SaveTooLarge;
        @memcpy(s.strings.get(reference), text);
        return reference;
    }

    fn choices(loader: *Loader, saved: []const Json, threads: ?Object) Error!void {
        // ink keeps each choice's saved index; this runtime keeps whether the choices had
        // been indexed (some index isn't 0) and recomputes the indices.
        var indexed = false;
        for (saved) |choice_json| {
            const object = try as(choice_json, .object);
            try loader.choice(object, threads);
            if (try integer(try member(object, "index")) != 0) indexed = true;
        }
        const records = &loader.state().choices;
        assert(records.count() == saved.len);
        records.indexed_count = if (indexed) records.count() else 0;
    }

    /// ink's JObjectToChoice and LoadFlowChoiceThreads.
    fn choice(loader: *Loader, object: Object, threads: ?Object) Error!void {
        const text = try loader.string(try as(try member(object, "text"), .string));
        const source = try loader.pointer_at(try member(object, "originalChoicePath"));
        const counter = try integer(try member(object, "originalThreadIndex"));
        if (counter < 0) return error.InvalidSave;
        var target = try loader.pointer_at(try member(object, "targetPath"));
        if (target.index == Pointer.container_self) target.index = 0;
        const records = &loader.state().choices;
        const tags_first = records.tags.count;
        if (object.get("tags")) |tags| {
            for ((try as(tags, .array)).items) |tag| {
                const reference = try loader.string(try as(tag, .string));
                records.tags.push(reference) catch return error.SaveTooLarge;
            }
        }
        const snapshot = try loader.choice_thread(@intCast(counter), threads);
        records.records.push(.{
            .text = text,
            .target = target,
            .source = source,
            .original_thread = @intCast(counter),
            .thread_counter = @intCast(counter),
            .tags_first = tags_first,
            .snapshot = snapshot,
            .tags_count = @intCast(records.tags.count - tags_first),
            .invisible_default = false,
        }) catch return error.SaveTooLarge;
    }

    /// The choice's stored thread: a copy of the live thread with its index, or the saved
    /// one in choiceThreads.
    fn choice_thread(loader: *Loader, counter: u32, threads: ?Object) Error!u32 {
        const s = loader.state();
        const snapshot_index = s.choices.snapshots.count;
        const frames_first = s.choices.frames.count;
        const temps_first = s.choices.temps.count;
        var previous: Pointer = .null;
        if (live_thread(s, counter)) |thread| {
            previous = thread.previous_pointer;
            const frames = s.call_stack.frames.slice()[thread.frame_first..][0..thread.frame_count];
            for (frames) |live| {
                var copy = live;
                copy.temps_first = s.choices.temps.count;
                const temps = s.call_stack.temps.slice()[live.temps_first..][0..live.temps_count];
                s.choices.temps.push_slice(temps) catch return error.SaveTooLarge;
                s.choices.frames.push(copy) catch return error.SaveTooLarge;
            }
        } else {
            var name_buffer: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&name_buffer, "{d}", .{counter}) catch unreachable;
            const object = threads orelse return error.InvalidSave;
            const saved = object.get(key) orelse return error.InvalidSave;
            previous = (try loader.load_thread(try as(saved, .object), .snapshot)).previous;
        }
        s.choices.snapshots.push(.{
            .frames_first = frames_first,
            .frames_count = s.choices.frames.count - frames_first,
            .temps_first = temps_first,
            .temps_count = s.choices.temps.count - temps_first,
            .previous_pointer = previous,
        }) catch return error.SaveTooLarge;
        return snapshot_index;
    }

    fn variables(loader: *Loader, saved: Object) Error!void {
        const program = loader.story.program;
        for (program.globals, 0..) |global, slot| {
            const value = saved.get(program.strings.get(global.name)) orelse continue;
            loader.state().globals[slot] = try loader.load_value(value);
        }
    }

    fn evaluation(loader: *Loader, saved: []const Json) Error!void {
        assert(loader.state().evaluation.count == 0);
        for (saved) |value_json| {
            const value = try loader.load_value(value_json);
            loader.state().evaluation.push(value) catch return error.SaveTooLarge;
        }
    }

    const Counts = enum { visits, turns };

    fn counts(loader: *Loader, saved: Object, which: Counts) Error!void {
        for (saved.keys(), saved.values()) |path, number_json| {
            const number = try integer(number_json);
            // ink keeps counts by path; a path the story doesn't count is kept but unused.
            const container = loader.container_at(.{ .string = path }) catch continue;
            const slot = loader.story.program.container_info(container).count_slot;
            if (slot == container_module.no_count_slot) continue;
            const s = loader.state();
            switch (which) {
                .visits => s.visit_counts[slot] = @bitCast(number),
                .turns => s.turn_indices[slot] = number,
            }
        }
    }

    /// ink's JTokenToRuntimeObject for a value.
    fn load_value(loader: *Loader, json: Json) Error!Value {
        switch (json) {
            .number_string => |text| {
                if (std.mem.indexOfAny(u8, text, ".eE") == null) {
                    return .{ .integer = try integer(json) };
                }
                return .{ .float = std.fmt.parseFloat(f32, text) catch return error.InvalidSave };
            },
            .bool => |flag| return .{ .bool = flag },
            .string => |text| {
                if (std.mem.eql(u8, text, "void")) return .null;
                const newline = story_module.program_newline(loader.story);
                if (std.mem.eql(u8, text, "\n")) return .{ .string = newline };
                if (text.len == 0 or text[0] != '^') return error.InvalidSave;
                return .{ .string = try loader.string(text[1..]) };
            },
            .object => |object| return loader.object_value(object),
            .array, .null, .integer, .float => return error.InvalidSave,
        }
    }

    fn object_value(loader: *Loader, object: Object) Error!Value {
        if (object.get("^->")) |path| return .{ .divert_target = try loader.container_at(path) };
        if (object.get("^var")) |name_json| {
            const name = loader.story.program.strings.find(try as(name_json, .string)) orelse
                return error.SaveDoesNotMatchStory;
            const context = try integer(try member(object, "ci"));
            // -1 unknown, 0 global, n > 0 a call-stack frame; a frame deeper than the stack
            // is checked where the pointer is followed.
            if (context < -1) return error.InvalidSave;
            return .{ .variable_pointer = .{ .name = name, .context = context } };
        }
        if (object.get("#")) |text| return .{ .tag = try loader.string(try as(text, .string)) };
        const items = object.get("list") orelse return error.InvalidSave;
        return loader.list(try as(items, .object), object.get("origins"));
    }

    fn list(loader: *Loader, named: Object, origins_json: ?Json) Error!Value {
        var items: [lists_module.list_items_max]index.ListItemIndex = undefined;
        var origins: [64]index.ListOriginIndex = undefined;
        const names = named.keys();
        if (names.len > items.len) return error.SaveTooLarge;
        assert(names.len <= lists_module.list_items_max);
        for (names, items[0..names.len]) |name, *item| item.* = try loader.list_item(name);
        const saved_origins = if (origins_json) |json| (try as(json, .array)).items else &.{};
        if (saved_origins.len > origins.len) return error.SaveTooLarge;
        for (saved_origins, origins[0..saved_origins.len]) |name, *origin| {
            origin.* = try loader.list_origin(try as(name, .string));
        }
        const slab = &loader.state().lists;
        const reference = slab.store(items[0..names.len], origins[0..saved_origins.len]) catch
            return error.SaveTooLarge;
        return .{ .list = reference };
    }

    fn list_item(loader: *Loader, name: []const u8) Error!index.ListItemIndex {
        const program = loader.story.program;
        const id = program.strings.find(name) orelse return error.SaveDoesNotMatchStory;
        for (program.list_items, 0..) |item, position| {
            if (item.full_name == id) return .from_int(@intCast(position));
        }
        return error.SaveDoesNotMatchStory;
    }

    fn list_origin(loader: *Loader, name: []const u8) Error!index.ListOriginIndex {
        const program = loader.story.program;
        const id = program.strings.find(name) orelse return error.SaveDoesNotMatchStory;
        for (program.list_origins, 0..) |origin, position| {
            if (origin.name == id) return .from_int(@intCast(position));
        }
        return error.SaveDoesNotMatchStory;
    }

    /// The container at path `json` (ink's ContentAtPath(...).container).
    fn container_at(loader: *Loader, json: Json) Error!ContainerIndex {
        const target = try loader.resolve(json);
        if (target.content_index != null) return error.SaveDoesNotMatchStory;
        return target.container;
    }

    /// ink's PointerAtPath: an index at the end points at that item; a container path points
    /// at the container itself.
    fn pointer_at(loader: *Loader, json: Json) Error!Pointer {
        const target = try loader.resolve(json);
        const position = target.content_index orelse Pointer.container_self;
        return .{ .container = target.container, .index = position };
    }

    fn resolve(loader: *Loader, json: Json) Error!path_module.Target {
        const text = try as(json, .string);
        const program = loader.story.program;
        // The root's path is empty (ink's Path("") is the root).
        if (text.len == 0) {
            const root = program.root_container();
            return .{ .container = root, .content_index = null, .approximate = false };
        }
        const path = path_module.Path.parse(text, loader.state().limits.path_components_max) catch
            return error.InvalidSave;
        const origin: path_module.Origin = .{ .container = program.root_container() };
        const target = path_module.resolve(program, origin, path) catch
            return error.SaveDoesNotMatchStory;
        if (target.approximate) return error.SaveDoesNotMatchStory;
        return target;
    }
};

fn live_thread(s: *state_module.State, counter: u32) ?call_stack_module.Thread {
    for (s.call_stack.threads.slice()) |thread| {
        if (thread.counter == counter) return thread;
    }
    return null;
}
