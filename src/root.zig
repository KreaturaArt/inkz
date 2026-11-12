pub const ink_format = @import("ink_format.zig");

// ── Compiler ──────────────────────────────────────────────────────────────────
pub const compiler = struct {
    pub const parsed = @import("compiler/parsed.zig");
    pub const tokenizer = @import("compiler/tokenizer.zig");
    pub const parser = @import("compiler/parser.zig");
    pub const codegen = @import("compiler/codegen.zig");
    pub const serializer = @import("compiler/serializer.zig");
    pub const compile = @import("compiler/compiler.zig");
    pub const codegen_to_runtime = @import("compiler/codegen_to_runtime.zig");
};

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
