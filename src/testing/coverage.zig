//! Code coverage of a swarm run (`zig build swarm-coverage`, docs/fuzzing.md).
//!
//! The coverage build compiles `dev` with Zig's fuzz instrumentation (`-ffuzz`): LLVM gives
//! every basic block an 8-bit hit counter in the `__sancov_cntrs` section and its address in
//! `__sancov_pcs1`. After the run, `write_report` resolves each block's address to a source
//! line with the program's own debug info and writes, for the files under `src/`, the blocks
//! hit per module and per file and the line ranges no block of which ran. It needs no tool
//! outside Zig and works wherever `std.debug.SelfInfo` does (macOS, Linux).
//!
//! Only code that is compiled is counted: a function nothing in `dev` references is not in
//! the binary, so it is missing from the report rather than unreached.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The sections' boundary symbols as the linker names them.
const section_bounds: [2][]const u8 = switch (builtin.object_format) {
    .elf => .{ "__start_", "__stop_" },
    .macho => .{ "\x01section$start$__DATA$", "\x01section$end$__DATA$" },
    else => @compileError("coverage needs ELF or Mach-O"),
};
const section_start = section_bounds[0];
const section_end = section_bounds[1];

/// The report's modules: a file belongs to the first whose prefix it starts with.
const modules = [_][]const u8{
    "src/compiler/",
    "src/runtime/",
    "src/core/",
    "src/testing/",
    "src/",
};

/// One source line's blocks, the unit of the unreached ranges.
const Line = struct {
    file: []const u8,
    line: u32,
    blocks: u32,
    hit: u32,
};

fn section(comptime T: type, comptime name: []const u8) []T {
    const start = @extern([*]T, .{ .name = section_start ++ name, .linkage = .weak }) orelse
        @panic("coverage: missing section " ++ name ++ " (build with -ffuzz)");
    const end = @extern([*]T, .{ .name = section_end ++ name, .linkage = .weak }).?;
    return start[0 .. end - start];
}

/// Resolves every instrumented block and writes the report to `path`; prints the per-module
/// totals to `summary`.
pub fn write_report(
    io: std.Io,
    path: []const u8,
    summary: *std.Io.Writer,
) !void {
    // Not the program's allocator: resolving holds the debug info's lock, and a Debug
    // allocator that captures stack traces would take it again.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const counters = section(u8, "__sancov_cntrs");
    const addresses = section(usize, "__sancov_pcs1");
    assert(counters.len == addresses.len);
    assert(counters.len > 0);

    const lines = try resolve_lines(arena, io, counters, addresses);
    const root = try std.process.currentPathAlloc(io, arena);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;
    try write_totals(out, summary, lines, root);
    try write_files(out, lines, root);
    try write_unreached(out, lines, root);
    try out.flush();
}

/// The source lines of the blocks in files under `src/`, sorted by file and line.
fn resolve_lines(
    arena: std.mem.Allocator,
    io: std.Io,
    counters: []const u8,
    addresses: []const usize,
) ![]Line {
    const info = try std.debug.getSelfDebugInfo();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    var by_place: std.StringArrayHashMapUnmanaged(Line) = .empty;
    var text: std.heap.ArenaAllocator = .init(arena);
    for (counters, addresses) |counter, address| {
        symbols.clearRetainingCapacity();
        info.getSymbols(io, arena, text.allocator(), address, false, &symbols) catch continue;
        if (symbols.items.len == 0) continue;
        const location = symbols.items[0].source_location orelse continue;
        if (std.mem.indexOf(u8, location.file_name, "/src/") == null) continue;
        if (std.mem.indexOf(u8, location.file_name, "/lib/std/") != null) continue;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{d}", .{
            location.file_name, location.line,
        });
        const entry = try by_place.getOrPut(arena, key);
        if (!entry.found_existing) entry.value_ptr.* = .{
            .file = key[0..location.file_name.len],
            .line = @intCast(location.line),
            .blocks = 0,
            .hit = 0,
        };
        entry.value_ptr.blocks += 1;
        if (counter != 0) entry.value_ptr.hit += 1;
    }
    const lines = by_place.values();
    std.mem.sort(Line, lines, {}, line_less);
    return lines;
}

fn line_less(_: void, a: Line, b: Line) bool {
    const order = std.mem.order(u8, a.file, b.file);
    if (order != .eq) return order == .lt;
    return a.line < b.line;
}

/// `file` relative to the repository root.
fn relative(file: []const u8, root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, file, root) and file.len > root.len + 1) {
        return file[root.len + 1 ..];
    }
    return file;
}

fn module_of(file: []const u8) ?usize {
    for (modules, 0..) |prefix, index| {
        if (std.mem.startsWith(u8, file, prefix)) return index;
    }
    return null;
}

fn percent(hit: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(hit)) * 100 / @as(f64, @floatFromInt(total));
}

fn write_totals(
    out: *std.Io.Writer,
    summary: *std.Io.Writer,
    lines: []const Line,
    root: []const u8,
) !void {
    var blocks: [modules.len]u64 = @splat(0);
    var hit: [modules.len]u64 = @splat(0);
    var lines_total: [modules.len]u64 = @splat(0);
    var lines_hit: [modules.len]u64 = @splat(0);
    for (lines) |line| {
        const index = module_of(relative(line.file, root)) orelse continue;
        blocks[index] += line.blocks;
        hit[index] += line.hit;
        lines_total[index] += 1;
        if (line.hit > 0) lines_hit[index] += 1;
    }
    for ([_]*std.Io.Writer{ out, summary }) |writer| {
        try writer.print("{s:<16} {s:>8} {s:>8} {s:>6} {s:>7} {s:>7} {s:>6}\n", .{
            "module", "blocks", "hit", "%", "lines", "hit", "%",
        });
        for (modules, 0..) |prefix, index| {
            try writer.print("{s:<16} {d:>8} {d:>8} {d:>6.1} {d:>7} {d:>7} {d:>6.1}\n", .{
                prefix,                                        blocks[index],
                hit[index],                                    percent(hit[index], blocks[index]),
                lines_total[index],                            lines_hit[index],
                percent(lines_hit[index], lines_total[index]),
            });
        }
        try writer.writeAll("\n");
    }
}

fn write_files(out: *std.Io.Writer, lines: []const Line, root: []const u8) !void {
    try out.print("{s:<48} {s:>7} {s:>7} {s:>6}\n", .{ "file", "blocks", "hit", "%" });
    var start: usize = 0;
    while (start < lines.len) {
        var end = start;
        var blocks: u64 = 0;
        var hit: u64 = 0;
        while (end < lines.len and std.mem.eql(u8, lines[end].file, lines[start].file)) {
            blocks += lines[end].blocks;
            hit += lines[end].hit;
            end += 1;
        }
        try out.print("{s:<48} {d:>7} {d:>7} {d:>6.1}\n", .{
            relative(lines[start].file, root), blocks, hit, percent(hit, blocks),
        });
        start = end;
    }
    try out.writeAll("\n");
}

/// Each run of lines whose blocks all stayed at zero, as `file:first-last (blocks)`. Lines
/// without blocks (comments, declarations) don't break a run; a line with a block that ran
/// does.
fn write_unreached(out: *std.Io.Writer, lines: []const Line, root: []const u8) !void {
    try out.writeAll("unreached line ranges (file:first-last blocks)\n");
    var index: usize = 0;
    while (index < lines.len) {
        if (lines[index].hit > 0) {
            index += 1;
            continue;
        }
        const first = lines[index];
        var last = first;
        var blocks: u64 = 0;
        while (index < lines.len and lines[index].hit == 0 and
            std.mem.eql(u8, lines[index].file, first.file))
        {
            last = lines[index];
            blocks += lines[index].blocks;
            index += 1;
        }
        try out.print("{s}:{d}-{d} {d}\n", .{
            relative(first.file, root), first.line, last.line, blocks,
        });
    }
}

/// References every public function of the library's files and of the types they declare
/// (two levels, no deeper), so that the coverage build compiles the functions the swarm never
/// calls and the report lists them as unreached instead of leaving them out. Generic
/// functions are compiled per instantiation and can't be referenced alone.
pub fn reference_library() void {
    comptime {
        @setEvalBranchQuota(200_000);
        const files = .{
            @import("../runtime/root.zig"),
            @import("../core/root.zig"),
            @import("../compiler/compile.zig"),
            @import("../compiler/messages.zig"),
            @import("../root.zig"),
        };
        for (files) |file| {
            for (std.meta.declarations(file)) |name| {
                if (@TypeOf(@field(file, name)) != type) continue;
                const module = @field(file, name);
                if (!is_namespace(module)) continue;
                reference_functions(module);
                for (std.meta.declarations(module)) |inner| {
                    if (@TypeOf(@field(module, inner)) != type) continue;
                    reference_functions(@field(module, inner));
                }
            }
        }
    }
}

fn is_namespace(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

fn reference_functions(comptime T: type) void {
    @setEvalBranchQuota(200_000);
    // The profile zones' report needs profiling compiled in (src/profile_check.zig).
    if (!is_namespace(T) or T == @import("../core/profile.zig")) return;
    for (std.meta.declarations(T)) |name| {
        const info = @typeInfo(@TypeOf(@field(T, name)));
        if (info != .@"fn" or info.@"fn".is_generic) continue;
        _ = &@field(T, name);
    }
}

test "coverage: unreached ranges bridge lines without blocks and stop at hit lines" {
    const lines = [_]Line{
        .{ .file = "/r/src/runtime/a.zig", .line = 3, .blocks = 2, .hit = 1 },
        .{ .file = "/r/src/runtime/a.zig", .line = 5, .blocks = 1, .hit = 0 },
        .{ .file = "/r/src/runtime/a.zig", .line = 9, .blocks = 3, .hit = 0 },
        .{ .file = "/r/src/runtime/a.zig", .line = 10, .blocks = 1, .hit = 1 },
        .{ .file = "/r/src/runtime/a.zig", .line = 12, .blocks = 1, .hit = 0 },
        .{ .file = "/r/src/runtime/b.zig", .line = 1, .blocks = 1, .hit = 0 },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_unreached(&writer, &lines, "/r");
    try std.testing.expectEqualStrings(
        \\unreached line ranges (file:first-last blocks)
        \\src/runtime/a.zig:5-9 4
        \\src/runtime/a.zig:12-12 1
        \\src/runtime/b.zig:1-1 1
        \\
    , writer.buffered());
}

test "coverage: module totals count lines with a block that ran" {
    const lines = [_]Line{
        .{ .file = "/r/src/core/a.zig", .line = 1, .blocks = 2, .hit = 1 },
        .{ .file = "/r/src/core/a.zig", .line = 2, .blocks = 2, .hit = 0 },
        .{ .file = "/r/lib/std/x.zig", .line = 1, .blocks = 9, .hit = 9 },
    };
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var summary_buffer: [1024]u8 = undefined;
    var summary: std.Io.Writer = .fixed(&summary_buffer);
    try write_totals(&writer, &summary, &lines, "/r");
    try std.testing.expectEqualStrings(writer.buffered(), summary.buffered());
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "src/core/               4        1   25.0       2       1   50.0",
    ) != null);
}
