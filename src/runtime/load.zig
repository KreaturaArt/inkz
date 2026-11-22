//! Loading: ink's StoryState.LoadJson for save format versions 8 to 10.
//!
//! The save is tokenized into the state's fixed scratch (`json_tree.zig`) and read once,
//! into a reset state. A save that fails to load part way leaves the story as `reset_state`
//! leaves it (C# ink leaves it partly loaded). Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const index = @import("../core/index.zig");
const path_module = @import("../core/path.zig");
const container_module = @import("../core/container.zig");
const json_tree = @import("json_tree.zig");
const value_module = @import("value.zig");
const output_module = @import("output.zig");
const call_stack_module = @import("call_stack.zig");
const choices_module = @import("choices.zig");
const state_module = @import("state.zig");
const flows = @import("flows.zig");
const lists_module = @import("lists.zig");
const lookahead = @import("lookahead.zig");
const story_module = @import("story.zig");
const Story = story_module.Story;
const Tree = json_tree.Tree;
const Value = value_module.Value;
const Pointer = call_stack_module.Pointer;
const Frame = call_stack_module.Frame;
const Temp = call_stack_module.Temp;
const Item = output_module.Item;
const ContainerIndex = index.ContainerIndex;

pub const Error = error{
    /// Not a save ink can load: malformed JSON, a missing key, a value of the wrong type.
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
    const tree = Tree.parse(json, story.state.load_nodes) catch |err| {
        parse_zone.end();
        return switch (err) {
            error.JsonTooLarge, error.JsonTooDeep => error.SaveTooLarge,
            error.InvalidJson => error.InvalidSave,
        };
    };
    parse_zone.end();
    const nodes: u32 = @intCast(tree.nodes.len);
    story.state.peaks.load_nodes = @max(story.state.peaks.load_nodes, nodes);
    if (tree.nodes[0].kind != .object) return error.InvalidSave;
    const commit_zone = profile.begin(.load_commit);
    defer commit_zone.end();
    var loader: Loader = .{ .story = story, .tree = tree };
    loader.prepare();
    try loader.document();
    story.failed = false;
    story.state.verify();
}

const Loader = struct {
    story: *Story,
    tree: Tree,

    fn state(loader: *Loader) *state_module.State {
        assert(loader.story.state.memory.len > 0);
        return &loader.story.state;
    }

    fn member(loader: *Loader, object: u32, key: []const u8) Error!u32 {
        assert(object < loader.tree.nodes.len);
        assert(key.len > 0);
        if (loader.tree.nodes[object].kind != .object) return error.InvalidSave;
        return loader.tree.get(object, key) orelse error.InvalidSave;
    }

    fn integer(loader: *Loader, node: u32) Error!i32 {
        return loader.tree.integer(node) catch error.InvalidSave;
    }

    fn kind_is(loader: *Loader, node: u32, kind: json_tree.Kind) Error!void {
        assert(@backingInt(kind) <= @backingInt(json_tree.Kind.null));
        if (loader.tree.nodes[node].kind != kind) return error.InvalidSave;
    }

    /// Resets the state for the commit: the defaults, no flows, empty counts, and the heap
    /// compacted to what survives (the defaults).
    fn prepare(loader: *Loader) void {
        assert(!lookahead.active(&loader.story.state));
        assert(loader.story.callback_depth == 0);
        const s = loader.state();
        s.evaluation.clear();
        s.call_stack.fresh(.start_of(loader.story.program.root_container()));
        s.output.clear();
        s.choices.clear();
        flows.reset(s);
        @memcpy(s.globals, s.global_defaults);
        @memset(s.visit_counts, 0);
        @memset(s.turn_indices, state_module.never_visited);
        s.observer_events.clear();
        s.output_stashes_count = 0;
        s.did_safe_exit = false;
        loader.story.diverted_pointer = .null;
        s.compact();
    }

    fn document(loader: *Loader) Error!void {
        assert(loader.tree.nodes[0].kind == .object);
        const tree = loader.tree;
        const version = try loader.integer(try loader.member(0, "inkSaveVersion"));
        if (version < save_version_min) return error.SaveVersionTooOld;
        if (tree.get(0, "flows")) |all| {
            try loader.flows_of(all);
        } else {
            // Before multi-flow, the one flow's keys are at the top level.
            try loader.flow(0, flows.default_name, true);
        }
        try loader.variables(try loader.member(0, "variablesState"));
        try loader.evaluation(try loader.member(0, "evalStack"));
        if (tree.get(0, "currentDivertTarget")) |target| {
            var pointer = try loader.pointer_at(target);
            if (pointer.index == Pointer.container_self) pointer.index = 0;
            loader.story.diverted_pointer = pointer;
        }
        try loader.counts(try loader.member(0, "visitCounts"), .visits);
        try loader.counts(try loader.member(0, "turnIndices"), .turns);
        const turn = try loader.integer(try loader.member(0, "turnIdx"));
        const seed = try loader.integer(try loader.member(0, "storySeed"));
        // Missing in inkjs saves; ink reads it as 0.
        const previous = if (tree.get(0, "previousRandom")) |node| try loader.integer(node) else 0;
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
    /// 0 by its own name. Each flow name appears once.
    fn flows_of(loader: *Loader, all: u32) Error!void {
        assert(all < loader.tree.nodes.len);
        assert(loader.state().flows.len > 0);
        try loader.kind_is(all, .object);
        const tree = loader.tree;
        const count = tree.count(all);
        if (count == 0) return error.InvalidSave;
        if (count > loader.state().flows.len) return error.SaveTooLarge;
        var current_node: ?u32 = null;
        if (count > 1) current_node = try loader.member(0, "currentFlowName");
        var name_buffer: [state_module.flow_name_bytes_max]u8 = undefined;
        const current = if (current_node) |node| try loader.flow_name(node, &name_buffer) else null;
        var found_current = current == null;
        var has_default = false;
        for ([_]bool{ false, true }) |want_current| {
            var members = tree.children(all);
            while (members.next()) |name_node| {
                var buffer: [state_module.flow_name_bytes_max]u8 = undefined;
                const name = try loader.flow_name(name_node, &buffer);
                if (!want_current and try loader.flow_name_repeated(all, name_node, name)) {
                    return error.InvalidSave;
                }
                const is_current = current == null or std.mem.eql(u8, name, current.?);
                if (std.mem.eql(u8, name, flows.default_name)) has_default = true;
                if (is_current == want_current) {
                    if (is_current) found_current = true;
                    try loader.flow(name_node + 1, name, is_current);
                }
                members.skip_value(name_node + 1);
            }
        }
        if (!found_current or !has_default) return error.InvalidSave;
    }

    /// Whether a flow before `name_node` in the flows object `all` is also named `name`.
    fn flow_name_repeated(loader: *Loader, all: u32, name_node: u32, name: []const u8) Error!bool {
        assert(name.len > 0);
        assert(name_node > all);
        var members = loader.tree.children(all);
        while (members.next()) |earlier| {
            if (earlier == name_node) return false;
            var buffer: [state_module.flow_name_bytes_max]u8 = undefined;
            if (std.mem.eql(u8, try loader.flow_name(earlier, &buffer), name)) return true;
            members.skip_value(earlier + 1);
        }
        unreachable; // `name_node` is a member of `all`.
    }

    fn flow_name(
        loader: *Loader,
        node: u32,
        buffer: *[state_module.flow_name_bytes_max]u8,
    ) Error![]const u8 {
        assert(buffer.len == state_module.flow_name_bytes_max);
        try loader.kind_is(node, .string);
        var writer: std.Io.Writer = .fixed(buffer);
        loader.tree.decode(node, &writer) catch return error.SaveTooLarge;
        if (writer.end == 0) return error.InvalidSave;
        return writer.buffered();
    }

    /// One flow (ink's Flow constructor): loaded into the live buffers, then parked unless
    /// it is the current flow.
    fn flow(loader: *Loader, node: u32, name: []const u8, is_current: bool) Error!void {
        assert(name.len > 0);
        try loader.kind_is(node, .object);
        const s = loader.state();
        s.call_stack.frames.clear();
        s.call_stack.threads.clear();
        s.call_stack.temps.clear();
        s.output.clear();
        s.choices.clear();
        const callstack = loader.tree.get(node, "callstack") orelse
            try loader.member(node, "callstackThreads");
        try loader.call_stack(callstack);
        try loader.output_stream(try loader.member(node, "outputStream"));
        const threads = loader.tree.get(node, "choiceThreads");
        try loader.choices(try loader.member(node, "currentChoices"), threads);
        assert(s.call_stack.threads.count > 0);
        assert(s.choices.snapshots.count == s.choices.count());
        const record = flows.record_for(s, name) catch return error.SaveTooLarge;
        if (is_current) {
            s.current_flow = record;
        } else {
            flows.park_live_into(s, record) catch return error.SaveTooLarge;
        }
    }

    fn call_stack(loader: *Loader, node: u32) Error!void {
        const threads = try loader.member(node, "threads");
        try loader.kind_is(threads, .array);
        const counter = try loader.integer(try loader.member(node, "threadCounter"));
        if (counter < 0) return error.InvalidSave;
        const s = loader.state();
        var walker = loader.tree.children(threads);
        while (walker.next()) |thread_node| {
            const first = s.call_stack.frames.count;
            const thread = try loader.load_thread(thread_node, .live);
            s.call_stack.threads.push(.{
                .frame_first = first,
                .frame_count = s.call_stack.frames.count - first,
                .counter = thread.counter,
                .previous_pointer = thread.previous,
            }) catch return error.SaveTooLarge;
        }
        if (s.call_stack.threads.count == 0) return error.InvalidSave;
        assert(s.call_stack.frames.count >= s.call_stack.threads.count);
        s.call_stack.thread_counter = @intCast(counter);
    }

    const Destination = enum { live, snapshot };
    const LoadedThread = struct { counter: u32, previous: Pointer };

    /// ink's Thread constructor: frames, their temps, the thread index, the previous pointer.
    fn load_thread(loader: *Loader, node: u32, destination: Destination) Error!LoadedThread {
        assert(@backingInt(destination) <= 1);
        try loader.kind_is(node, .object);
        const counter = try loader.integer(try loader.member(node, "threadIndex"));
        if (counter < 0) return error.InvalidSave;
        const frames = try loader.member(node, "callstack");
        try loader.kind_is(frames, .array);
        var walker = loader.tree.children(frames);
        var count: u32 = 0;
        while (walker.next()) |frame_node| : (count += 1) {
            try loader.frame(frame_node, destination);
        }
        if (count == 0) return error.InvalidSave;
        var previous: Pointer = .null;
        if (loader.tree.get(node, "previousContentObject")) |path| previous = try loader.pointer_at(
            path,
        );
        return .{ .counter = @intCast(counter), .previous = previous };
    }

    fn frame(loader: *Loader, node: u32, destination: Destination) Error!void {
        try loader.kind_is(node, .object);
        const kind_number = try loader.integer(try loader.member(node, "type"));
        if (kind_number < 0 or kind_number > 2) return error.InvalidSave;
        var pointer: Pointer = .null;
        if (loader.tree.get(node, "cPath")) |path| {
            const container = try loader.container_at(path);
            const position = try loader.integer(try loader.member(node, "idx"));
            if (position < 0) return error.InvalidSave;
            pointer = .{ .container = container, .index = @intCast(position) };
        }
        const in_expression = loader.tree.boolean(try loader.member(node, "exp")) catch
            return error.InvalidSave;
        const s = loader.state();
        const frames = if (destination == .live) &s.call_stack.frames else &s.choices.frames;
        const temps = if (destination == .live) &s.call_stack.temps else &s.choices.temps;
        const temps_first = temps.count;
        if (loader.tree.get(node, "temp")) |object| {
            try loader.kind_is(object, .object);
            var members = loader.tree.children(object);
            while (members.next()) |name_node| {
                try loader.temp(name_node, temps);
                members.skip_value(name_node + 1);
            }
        }
        const temps_count = temps.count - temps_first;
        if (temps_count > s.limits.temps_per_frame_max) return error.SaveTooLarge;
        assert(temps_first + temps_count == temps.count);
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

    fn temp(loader: *Loader, name_node: u32, temps: anytype) Error!void {
        assert(name_node + 1 < loader.tree.nodes.len);
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        loader.tree.decode(name_node, &writer) catch return error.InvalidSave;
        // Temp names are program strings; a name the story doesn't have means it changed.
        const name = loader.story.program.strings.find(writer.buffered()) orelse
            return error.SaveDoesNotMatchStory;
        const value = try loader.load_value(name_node + 1);
        temps.push(.{ .name = name, .value = value }) catch return error.SaveTooLarge;
    }

    fn output_stream(loader: *Loader, node: u32) Error!void {
        try loader.kind_is(node, .array);
        const output = &loader.state().output;
        var walker = loader.tree.children(node);
        while (walker.next()) |item_node| {
            const item = try loader.output_item(item_node);
            if (item.kind == .begin_string) output.string_marks.push(output.items.count) catch
                return error.SaveTooLarge;
            output.items.push(item) catch return error.SaveTooLarge;
        }
        assert(output.string_marks.count <= output.items.count);
    }

    fn output_item(loader: *Loader, node: u32) Error!Item {
        const tree = loader.tree;
        if (tree.nodes[node].kind == .object) {
            const text = try loader.member(node, "#");
            const reference = try loader.string(text, 0);
            const length = try loader.decoded_length(text);
            return text_item(reference, length, .tag, .non_whitespace);
        }
        try loader.kind_is(node, .string);
        const raw = tree.raw(node);
        const command: ?output_module.Kind = if (std.mem.eql(u8, raw, "<>"))
            .glue
        else if (std.mem.eql(u8, raw, "str"))
            .begin_string
        else if (std.mem.eql(u8, raw, "#"))
            .begin_tag
        else if (std.mem.eql(u8, raw, "/#"))
            .end_tag
        else
            null;
        if (command) |kind| return Item.command(kind);
        if (std.mem.eql(u8, raw, "\\n")) {
            return text_item(story_module.program_newline(loader.story), 1, .text, .newline);
        }
        if (raw.len == 0 or raw[0] != '^') return error.InvalidSave;
        const reference = try loader.string(node, 1);
        const length = try loader.decoded_length(node) - 1;
        const class: output_module.Class = .of(story_module.text_of(loader.story, reference));
        return text_item(reference, length, .text, class);
    }

    fn text_item(
        reference: value_module.StringReference,
        length: u16,
        kind: output_module.Kind,
        class: output_module.Class,
    ) Item {
        assert(kind == .text or kind == .tag);
        const item: Item = .{
            .string = reference,
            .start = 0,
            .kind = kind,
            .class = class,
            .length = length,
        };
        assert(item.length == length);
        return item;
    }

    fn decoded_length(loader: *Loader, node: u32) Error!u16 {
        const length = loader.tree.string_length(node) catch return error.InvalidSave;
        if (length > std.math.maxInt(u16)) return error.SaveTooLarge;
        return @intCast(length);
    }

    /// The decoded text of string `node` from byte `skip` on, as a new heap string.
    fn string(loader: *Loader, node: u32, skip: u32) Error!value_module.StringReference {
        try loader.kind_is(node, .string);
        const length = loader.tree.string_length(node) catch return error.InvalidSave;
        if (length < skip) return error.InvalidSave;
        const size = length - skip;
        const s = loader.state();
        const reference = s.strings.try_allocate(size) orelse return error.SaveTooLarge;
        var writer: std.Io.Writer = .fixed(s.strings.get(reference));
        loader.tree.decode_from(node, skip, &writer) catch unreachable;
        assert(writer.end == size);
        return reference;
    }

    fn choices(loader: *Loader, node: u32, threads: ?u32) Error!void {
        try loader.kind_is(node, .array);
        if (threads) |object| try loader.kind_is(object, .object);
        var walker = loader.tree.children(node);
        // ink keeps each choice's saved index; this runtime keeps whether the choices had
        // been indexed (some index isn't 0) and recomputes the indices.
        var indexed = false;
        while (walker.next()) |choice_node| {
            try loader.choice(choice_node, threads);
            const saved_index = try loader.integer(try loader.member(choice_node, "index"));
            if (saved_index != 0) indexed = true;
        }
        const records = &loader.state().choices;
        records.indexed_count = if (indexed) records.count() else 0;
    }

    /// ink's JObjectToChoice and LoadFlowChoiceThreads.
    fn choice(loader: *Loader, node: u32, threads: ?u32) Error!void {
        assert(threads == null or threads.? < loader.tree.nodes.len);
        try loader.kind_is(node, .object);
        const text = try loader.string(try loader.member(node, "text"), 0);
        const source = try loader.pointer_at(try loader.member(node, "originalChoicePath"));
        const counter = try loader.integer(try loader.member(node, "originalThreadIndex"));
        if (counter < 0) return error.InvalidSave;
        var target = try loader.pointer_at(try loader.member(node, "targetPath"));
        if (target.index == Pointer.container_self) target.index = 0;
        const records = &loader.state().choices;
        const tags_first = records.tags.count;
        if (loader.tree.get(node, "tags")) |tags| {
            try loader.kind_is(tags, .array);
            var walker = loader.tree.children(tags);
            while (walker.next()) |tag| {
                const reference = try loader.string(tag, 0);
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
    fn choice_thread(loader: *Loader, counter: u32, threads: ?u32) Error!u32 {
        assert(threads == null or threads.? < loader.tree.nodes.len);
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
            const saved = loader.tree.get(object, key) orelse return error.InvalidSave;
            previous = (try loader.load_thread(saved, .snapshot)).previous;
        }
        s.choices.snapshots.push(.{
            .frames_first = frames_first,
            .frames_count = s.choices.frames.count - frames_first,
            .temps_first = temps_first,
            .temps_count = s.choices.temps.count - temps_first,
            .previous_pointer = previous,
        }) catch return error.SaveTooLarge;
        assert(s.choices.snapshots.count == snapshot_index + 1);
        return snapshot_index;
    }

    fn variables(loader: *Loader, node: u32) Error!void {
        assert(loader.state().globals.len == loader.story.program.globals.len);
        try loader.kind_is(node, .object);
        const program = loader.story.program;
        for (program.globals, 0..) |global, slot| {
            const saved = loader.tree.get(node, program.strings.get(global.name)) orelse continue;
            loader.state().globals[slot] = try loader.load_value(saved);
        }
    }

    fn evaluation(loader: *Loader, node: u32) Error!void {
        assert(loader.state().evaluation.count == 0);
        try loader.kind_is(node, .array);
        var walker = loader.tree.children(node);
        while (walker.next()) |value_node| {
            const value = try loader.load_value(value_node);
            loader.state().evaluation.push(value) catch return error.SaveTooLarge;
        }
    }

    const Counts = enum { visits, turns };

    fn counts(loader: *Loader, node: u32, which: Counts) Error!void {
        assert(@backingInt(which) <= 1);
        try loader.kind_is(node, .object);
        var members = loader.tree.children(node);
        while (members.next()) |name| {
            const number = try loader.integer(name + 1);
            members.skip_value(name + 1);
            // ink keeps counts by path; a path the story doesn't count is kept but unused.
            const container = loader.container_at(name) catch continue;
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
    fn load_value(loader: *Loader, node: u32) Error!Value {
        const tree = loader.tree;
        switch (tree.nodes[node].kind) {
            .number => {
                if (tree.is_float(node)) {
                    return .{ .float = tree.float(node) catch return error.InvalidSave };
                }
                return .{ .integer = try loader.integer(node) };
            },
            .true, .false => return .{ .bool = tree.nodes[node].kind == .true },
            .string => {
                const raw = tree.raw(node);
                if (std.mem.eql(u8, raw, "void")) return .null;
                const newline = story_module.program_newline(loader.story);
                if (std.mem.eql(u8, raw, "\\n")) return .{ .string = newline };
                if (raw.len == 0 or raw[0] != '^') return error.InvalidSave;
                return .{ .string = try loader.string(node, 1) };
            },
            .object => return loader.object_value(node),
            .array, .null => return error.InvalidSave,
        }
    }

    fn object_value(loader: *Loader, node: u32) Error!Value {
        assert(loader.tree.nodes[node].kind == .object);
        const tree = loader.tree;
        if (tree.get(node, "^->")) |path| {
            return .{ .divert_target = try loader.container_at(path) };
        }
        if (tree.get(node, "^var")) |name_node| {
            var buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            tree.decode(name_node, &writer) catch return error.InvalidSave;
            const name = loader.story.program.strings.find(writer.buffered()) orelse
                return error.SaveDoesNotMatchStory;
            const context = try loader.integer(try loader.member(node, "ci"));
            // -1 unknown, 0 global, n > 0 a call-stack frame; a frame deeper than the stack
            // is checked where the pointer is followed.
            if (context < -1) return error.InvalidSave;
            return .{ .variable_pointer = .{ .name = name, .context = context } };
        }
        if (tree.get(node, "#")) |text| return .{ .tag = try loader.string(text, 0) };
        if (tree.get(node, "list")) |items| return loader.list(items, tree.get(node, "origins"));
        return error.InvalidSave;
    }

    fn list(loader: *Loader, items_node: u32, origins_node: ?u32) Error!Value {
        assert(items_node < loader.tree.nodes.len);
        assert(origins_node == null or origins_node.? < loader.tree.nodes.len);
        try loader.kind_is(items_node, .object);
        var items: [lists_module.list_items_max]index.ListItemIndex = undefined;
        var origins: [64]index.ListOriginIndex = undefined;
        var items_count: u32 = 0;
        var origins_count: u32 = 0;
        var members = loader.tree.children(items_node);
        while (members.next()) |name| {
            members.skip_value(name + 1);
            if (items_count == items.len) return error.SaveTooLarge;
            items[items_count] = try loader.list_item(name);
            items_count += 1;
        }
        if (origins_node) |node| {
            try loader.kind_is(node, .array);
            var walker = loader.tree.children(node);
            while (walker.next()) |origin| {
                if (origins_count == origins.len) return error.SaveTooLarge;
                origins[origins_count] = try loader.list_origin(origin);
                origins_count += 1;
            }
        }
        const slab = &loader.state().lists;
        const reference = slab.store(items[0..items_count], origins[0..origins_count]) catch
            return error.SaveTooLarge;
        return .{ .list = reference };
    }

    fn list_item(loader: *Loader, name: u32) Error!index.ListItemIndex {
        assert(name < loader.tree.nodes.len);
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        loader.tree.decode(name, &writer) catch return error.InvalidSave;
        const program = loader.story.program;
        const id = program.strings.find(writer.buffered()) orelse
            return error.SaveDoesNotMatchStory;
        for (program.list_items, 0..) |item, position| {
            if (item.full_name == id) return .from_int(@intCast(position));
        }
        return error.SaveDoesNotMatchStory;
    }

    fn list_origin(loader: *Loader, name: u32) Error!index.ListOriginIndex {
        assert(name < loader.tree.nodes.len);
        try loader.kind_is(name, .string);
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        loader.tree.decode(name, &writer) catch return error.InvalidSave;
        const program = loader.story.program;
        const id = program.strings.find(writer.buffered()) orelse
            return error.SaveDoesNotMatchStory;
        for (program.list_origins, 0..) |origin, position| {
            if (origin.name == id) return .from_int(@intCast(position));
        }
        return error.SaveDoesNotMatchStory;
    }

    /// The container at the path in string `node` (ink's ContentAtPath(...).container).
    fn container_at(loader: *Loader, node: u32) Error!ContainerIndex {
        const target = try loader.resolve(node);
        if (target.content_index != null) return error.SaveDoesNotMatchStory;
        return target.container;
    }

    /// ink's PointerAtPath: an index at the end points at that item; a container path points
    /// at the container itself.
    fn pointer_at(loader: *Loader, node: u32) Error!Pointer {
        const target = try loader.resolve(node);
        const position = target.content_index orelse Pointer.container_self;
        return .{ .container = target.container, .index = position };
    }

    fn resolve(loader: *Loader, node: u32) Error!path_module.Target {
        try loader.kind_is(node, .string);
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        loader.tree.decode(node, &writer) catch return error.SaveTooLarge;
        const text = writer.buffered();
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
    assert(s.call_stack.threads.count > 0);
    for (s.call_stack.threads.slice()) |thread| {
        if (thread.counter == counter) return thread;
    }
    return null;
}
