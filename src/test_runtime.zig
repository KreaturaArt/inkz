//! Test root for the runtime: `zig build test-runtime`.

test {
    _ = @import("ink_format.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/path.zig");
    _ = @import("runtime/pointer.zig");
    _ = @import("runtime/json_loader.zig");
    _ = @import("runtime/variables.zig");
    _ = @import("runtime/choices.zig");
    _ = @import("runtime/callstack.zig");
    _ = @import("runtime/state.zig");
    _ = @import("runtime/evaluation.zig");
    _ = @import("runtime/story.zig");
    _ = @import("runtime/lists.zig");
    _ = @import("test/helpers.zig");
}
