//! One-shot: `zig run emit_crime_json.zig` → writes `test/fixture/compiled/crime_scene.ink.json`
const std = @import("std");
const compiler = @import("src/compiler/compiler.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/crime_scene.ink", a, .limited(10 << 20));
    defer a.free(src);
    const json = try compiler.compile(a, src);
    defer a.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "test/fixture/compiled/crime_scene.ink.json", .data = json });
    std.debug.print("wrote test/fixture/compiled/crime_scene.ink.json ({d} bytes)\n", .{json.len});
}
