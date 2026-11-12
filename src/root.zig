pub const ink_format = @import("ink_format.zig");

// ── Compiler ──────────────────────────────────────────────────────────────────
/// The compiler (ink source to Program; ink_json.serialize writes ink's JSON).
pub const compiler = @import("compiler/compile.zig");

// ── Runtime ───────────────────────────────────────────────────────────────────
pub const value = @import("runtime/value.zig");
pub const path = @import("runtime/path.zig");
pub const pointer = @import("runtime/pointer.zig");
pub const json_loader = @import("runtime/json_loader.zig");
pub const variables = @import("runtime/variables.zig");
pub const choices = @import("runtime/choices.zig");
pub const callstack = @import("runtime/callstack.zig");
pub const state = @import("runtime/state.zig");
pub const evaluation = @import("runtime/evaluation.zig");
pub const story = @import("runtime/story.zig");
pub const lists = @import("runtime/lists.zig");

pub const Story = story.Story;
pub const RuntimeObject = value.RuntimeObject;
pub const Value = value.RuntimeObject;

pub const core = @import("core/root.zig");

/// The new runtime's public API (plan §4.7); it becomes the top-level API when the old
/// runtime is removed (P9.1).
pub const vm = @import("vm/api.zig");
