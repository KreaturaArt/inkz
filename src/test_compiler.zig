//! Test root for the compiler: `zig build test-compiler`.

test {
    _ = @import("compiler/parsed.zig");
    _ = @import("compiler/tokenizer.zig");
    _ = @import("compiler/parser.zig");
    _ = @import("compiler/codegen.zig");
    _ = @import("compiler/serializer.zig");
    _ = @import("compiler/compiler.zig");
    _ = @import("compiler/codegen_to_runtime.zig");
    _ = @import("compiler/codegen_to_program.zig");
    _ = @import("testing/e2e_new_vm.zig");
    _ = @import("testing/e2e_new_vm_api.zig");
    _ = @import("testing/structure_gate.zig");
    _ = @import("test/compiler_helpers.zig");
    _ = @import("compiler_next/tokenizer.zig");
    _ = @import("compiler_next/ast.zig");
    _ = @import("compiler_next/core.zig");
    _ = @import("compiler_next/grammar.zig");
    _ = @import("compiler_next/dump.zig");
    _ = @import("compiler_next/grammar_snapshots.zig");
    _ = @import("compiler_next/parser_shape_tests.zig");
    _ = @import("compiler_next/sema.zig");
    _ = @import("compiler_next/resolve.zig");
    _ = @import("compiler_next/source_space.zig");
    _ = @import("compiler_next/values.zig");
    _ = @import("compiler_next/lower_ir.zig");
    _ = @import("compiler_next/compile.zig");
    _ = @import("compiler_next/lowering_tests.zig");
}
