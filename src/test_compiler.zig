//! Test root for the compiler: `zig build test-compiler`.

test {
    _ = @import("compiler/parsed.zig");
    _ = @import("compiler/tokenizer.zig");
    _ = @import("compiler/parser.zig");
    _ = @import("compiler/codegen.zig");
    _ = @import("compiler/serializer.zig");
    _ = @import("compiler/compiler.zig");
    _ = @import("compiler/codegen_to_runtime.zig");
    _ = @import("test/compiler_helpers.zig");
    _ = @import("compiler_next/spike.zig");
    _ = @import("compiler_next/tokenizer.zig");
}
