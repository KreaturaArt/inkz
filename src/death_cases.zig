//! Cases that must panic, run by `zig build test-death` (plan D20).
//!
//! Each public function in `must_panic` is one case. The build runs `tools/death.zig` once per
//! case as a child process and expects it to abort. If a case returns instead, the runner
//! exits with `did_not_die_exit_code` and the step fails.
//!
//! Two control groups show that the step tells a panic apart from a normal exit:
//! - `must_return` cases return, and the runner exits with 0.
//! - `self_test_must_panic` cases return although the runner expects a panic, so the runner
//!   exits with `did_not_die_exit_code`. The build expects exactly that code for them.

const std = @import("std");
const assert = std.debug.assert;
const fault = @import("core/fault.zig");
const index = @import("core/index.zig");
const string_pool = @import("core/string_pool.zig");
const api = @import("runtime/api.zig");

pub const did_not_die_exit_code = 3;

pub const must_panic = struct {
    pub fn verify_panics_on_a_fault() void {
        const Fault = enum { ok, broken };
        const result: Fault = .broken;
        assert(result != .ok);
        fault.verify(result);
    }

    pub fn index_to_int_of_none_panics() void {
        const missing: index.ContainerIndex = .none;
        assert(missing.is_none());
        assert(missing.to_optional() == null);
        _ = missing.to_int();
    }

    pub fn index_from_int_of_none_pattern_panics() void {
        const pattern: u32 = std.math.maxInt(u32);
        assert(pattern == @backingInt(index.StringId.none));
        assert(pattern > 0);
        _ = index.StringId.from_int(pattern);
    }

    pub fn string_pool_get_of_unissued_id_panics() void {
        var pool = string_pool.StringPool.init(std.heap.page_allocator) catch unreachable;
        assert(pool.count() == 1);
        const unissued = index.StringId.from_int(1);
        assert(pool.find("anything") == null);
        _ = pool.get(unissued);
    }

    /// P6.3: a borrowed view used after the next mutating call asserts in Debug.
    pub fn stale_view_access_panics() void {
        assert(std.debug.runtime_safety);
        const json = "{\"inkVersion\":21,\"root\":[[\"^One\",\"\\n\",\"^Two\",\"\\n\"," ++
            "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}";
        var story: api.Story = undefined;
        story.init_from_json(std.heap.page_allocator, json, .{}) catch unreachable;
        const line = story.cont() catch unreachable;
        assert(std.mem.eql(u8, line.get(), "One\n"));
        _ = story.cont() catch unreachable;
        _ = line.get();
    }
};

pub const must_return = struct {
    pub fn verify_returns_on_ok() void {
        const Fault = enum { ok, broken };
        const result: Fault = .ok;
        assert(result == .ok);
        fault.verify(result);
    }
};

pub const self_test_must_panic = struct {
    pub fn returning_case_is_caught() void {
        const steps: u32 = 1;
        assert(steps > 0);
        assert(steps < 2);
    }
};

test "case names are unique across both groups" {
    // Goal: the build derives one step argument per name, so duplicates would hide a case.
    // Method: compare every pair of declaration names at compile time.
    const panic_names = comptime std.meta.declarations(must_panic);
    const return_names = comptime std.meta.declarations(must_return);
    inline for (panic_names) |a| {
        inline for (return_names) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    try std.testing.expect(panic_names.len > 0);
}
