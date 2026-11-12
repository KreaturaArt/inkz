const std = @import("std");
const ink_json = @import("core/ink_json.zig");
const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    for ([_][]const u8{ "test/ground_truth/crime_scene.ink.json", "test/fixture/bench/generated.ink.json" }) |path| {
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
        var counting = CountingAllocator.init(gpa);
        var program = try ink_json.load(counting.allocator(), json);
        const bytes = counting.bytes_live;
        const src = try gpa.alloc(u8, bytes);
        @memset(src, 7);
        var t = std.Io.Timestamp.now(io, .awake);
        var sink: u64 = 0;
        for (0..2000) |_| {
            const dst = try gpa.alloc(u8, bytes);
            @memcpy(dst, src);
            sink +%= dst[bytes / 2];
            gpa.free(dst);
        }
        const copy_us = @as(f64, @floatFromInt(t.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 2000e3;
        t = std.Io.Timestamp.now(io, .awake);
        for (0..2000) |_| sink +%= @backingInt(program.check());
        const check_us = @as(f64, @floatFromInt(t.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 2000e3;
        t = std.Io.Timestamp.now(io, .awake);
        const strings = program.strings.strings;
        for (0..2000) |_| {
            var start: u32 = 0;
            for (strings.ends) |end| { sink +%= std.hash.Wyhash.hash(0, strings.bytes[start..end]); start = end; }
        }
        const hash_us = @as(f64, @floatFromInt(t.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 2000e3;
        std.debug.print("{s}: program {d} B; copy {d:.1} us, check {d:.1} us, rehash {d} strings {d:.1} us ({d})\n", .{ path, bytes, copy_us, check_us, strings.ends.len, hash_us, sink % 2 });
        program.deinit(counting.allocator());
    }
}
