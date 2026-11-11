//! Runs one case from `src/core/death_cases.zig` by name, for `zig build test-death`.
//! A case in `must_panic` should abort; returning exits with `did_not_die_exit_code`.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("death_cases");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    assert(arguments.len == 2);
    const name = arguments[1];
    assert(name.len > 0);
    if (run_case(cases.must_panic, name)) std.process.exit(cases.did_not_die_exit_code);
    if (run_case(cases.self_test_must_panic, name)) std.process.exit(cases.did_not_die_exit_code);
    if (run_case(cases.must_return, name)) return;
    std.debug.panic("unknown death case '{s}'", .{name});
}

/// Runs the case called `name` in `group`, and returns whether it existed.
fn run_case(comptime group: type, name: []const u8) bool {
    comptime assert(@typeInfo(group) == .@"struct");
    assert(name.len > 0);
    inline for (comptime std.meta.declarations(group)) |declaration| {
        if (std.mem.eql(u8, declaration, name)) {
            @field(group, declaration)();
            return true;
        }
    }
    return false;
}
