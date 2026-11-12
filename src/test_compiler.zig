//! Test root for the compiler: `zig build test-compiler`.

test {
    _ = @import("testing/e2e_new_vm.zig");
    _ = @import("testing/e2e_new_vm_api.zig");
    _ = @import("testing/e2e_tests.zig");
    _ = @import("testing/structure_gate.zig");
    _ = @import("compiler/tokenizer.zig");
    _ = @import("compiler/ast.zig");
    _ = @import("compiler/core.zig");
    _ = @import("compiler/grammar.zig");
    _ = @import("compiler/dump.zig");
    _ = @import("compiler/grammar_snapshots.zig");
    _ = @import("compiler/parser_shape_tests.zig");
    _ = @import("compiler/sema.zig");
    _ = @import("compiler/resolve.zig");
    _ = @import("compiler/source_space.zig");
    _ = @import("compiler/values.zig");
    _ = @import("compiler/lower_ir.zig");
    _ = @import("compiler/compile.zig");
    _ = @import("compiler/lowering_tests.zig");
    _ = @import("compiler/termination_tests.zig");
}
