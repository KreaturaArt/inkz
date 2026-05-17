const std = @import("std");
const value = @import("value.zig");
const callstack_mod = @import("callstack.zig");
const variables_mod = @import("variables.zig");
const choices_mod = @import("choices.zig");

pub const RuntimeObject = value.RuntimeObject;
pub const CallStack = callstack_mod.CallStack;
pub const VariablesState = variables_mod.VariablesState;
pub const Choice = choices_mod.Choice;

pub const StoryState = struct {
    call_stack: CallStack,
    output_stream: std.ArrayList(RuntimeObject),
    evaluation_stack: std.ArrayList(RuntimeObject),
    current_choices: std.ArrayList(Choice),
    variables_state: VariablesState,
    current_turn_index: i32,
    story_seed: u32,
    did_safe_exit: bool,
    allocator: std.mem.Allocator,
    /// Depth of nested str/str string-eval blocks. Avoids O(n) scan of output_stream
    /// to detect string-eval mode; incremented by begin_string, decremented by end_string.
    string_eval_depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !StoryState {
        return StoryState{
            .call_stack = try CallStack.init(allocator),
            .output_stream = std.ArrayList(RuntimeObject).empty,
            .evaluation_stack = std.ArrayList(RuntimeObject).empty,
            .current_choices = std.ArrayList(Choice).empty,
            .variables_state = VariablesState.init(),
            .current_turn_index = 0,
            .story_seed = 0,
            .did_safe_exit = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StoryState) void {
        self.call_stack.deinit();
        self.output_stream.deinit(self.allocator);
        self.evaluation_stack.deinit(self.allocator);
        self.current_choices.deinit(self.allocator);
        self.variables_state.deinit(self.allocator);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "StoryState init and deinit" {
    const alloc = std.testing.allocator;
    var s = try StoryState.init(alloc);
    defer s.deinit();

    try std.testing.expectEqual(@as(i32, 0), s.current_turn_index);
    try std.testing.expectEqual(@as(u32, 0), s.story_seed);
    try std.testing.expect(!s.did_safe_exit);
    try std.testing.expectEqual(@as(usize, 0), s.output_stream.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.evaluation_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.current_choices.items.len);
}

test "StoryState deinit after pushing items" {
    const alloc = std.testing.allocator;
    var s = try StoryState.init(alloc);
    defer s.deinit();

    try s.output_stream.append(alloc, .{ .string = "hello" });
    try s.evaluation_stack.append(alloc, .{ .int = 42 });
}
