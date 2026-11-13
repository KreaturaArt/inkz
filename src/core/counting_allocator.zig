//! An allocator that counts what passes through it. The zero-allocation gates
//! wrap a story's allocator, run `cont`, `choose_choice_index` and the rest, and
//! assert that `growths()` didn't change.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const CountingAllocator = struct {
    child: Allocator,
    allocations_count: u64 = 0,
    /// In-place resizes that succeeded, both growing and shrinking.
    resizes_count: u64 = 0,
    remaps_count: u64 = 0,
    frees_count: u64 = 0,
    /// Resizes and remaps that made a block bigger.
    grows_count: u64 = 0,
    bytes_live: u64 = 0,
    bytes_peak: u64 = 0,

    pub fn init(child: Allocator) CountingAllocator {
        const counting: CountingAllocator = .{ .child = child };
        assert(counting.bytes_live == 0);
        assert(counting.allocations_count == 0);
        return counting;
    }

    pub fn allocator(counting: *CountingAllocator) Allocator {
        assert(counting.bytes_live <= counting.bytes_peak);
        const result: Allocator = .{ .ptr = counting, .vtable = &vtable };
        assert(result.ptr == @as(*anyopaque, counting));
        return result;
    }

    /// Every event that could take new memory: allocations and grows.
    pub fn growths(counting: *const CountingAllocator) u64 {
        assert(counting.grows_count <= counting.resizes_count + counting.remaps_count);
        const result = counting.allocations_count + counting.grows_count;
        assert(result >= counting.allocations_count);
        return result;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn from(context: *anyopaque) *CountingAllocator {
        const counting: *CountingAllocator = @ptrCast(@alignCast(context));
        assert(counting.bytes_live <= counting.bytes_peak);
        assert(counting.frees_count <= counting.allocations_count);
        return counting;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const counting = from(context);
        const memory = counting.child.rawAlloc(len, alignment, return_address) orelse return null;
        counting.allocations_count += 1;
        counting.add_live(len);
        assert(counting.bytes_live >= len);
        assert(counting.allocations_count > counting.frees_count);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const counting = from(context);
        assert(counting.bytes_live >= memory.len);
        if (!counting.child.rawResize(memory, alignment, new_len, return_address)) return false;
        counting.resizes_count += 1;
        counting.change_live(memory.len, new_len);
        assert(counting.bytes_live >= new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const counting = from(context);
        assert(counting.bytes_live >= memory.len);
        const result = counting.child.rawRemap(memory, alignment, new_len, return_address) orelse
            return null;
        counting.remaps_count += 1;
        counting.change_live(memory.len, new_len);
        assert(counting.bytes_live >= new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const counting = from(context);
        assert(counting.bytes_live >= memory.len);
        counting.child.rawFree(memory, alignment, return_address);
        counting.frees_count += 1;
        counting.bytes_live -= memory.len;
        assert(counting.frees_count <= counting.allocations_count);
    }

    fn change_live(counting: *CountingAllocator, old_len: usize, new_len: usize) void {
        assert(counting.bytes_live >= old_len);
        if (new_len > old_len) {
            counting.grows_count += 1;
            counting.add_live(new_len - old_len);
        } else {
            counting.bytes_live -= old_len - new_len;
        }
        assert(counting.bytes_live <= counting.bytes_peak);
    }

    fn add_live(counting: *CountingAllocator, bytes: usize) void {
        counting.bytes_live += bytes;
        counting.bytes_peak = @max(counting.bytes_peak, counting.bytes_live);
        assert(counting.bytes_live <= counting.bytes_peak);
        assert(counting.bytes_live >= bytes);
    }
};

test "counts allocations, frees and live bytes" {
    // The counters match what was done: allocate, grow through an ArrayList,
    // then free everything, and check each counter.
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    const block = try gpa.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
    try std.testing.expectEqual(@as(u64, 100), counting.bytes_live);
    var list: std.ArrayList(u32) = .empty;
    for (0..1000) |number| try list.append(gpa, @intCast(number));
    try std.testing.expect(counting.growths() > 1);
    list.deinit(gpa);
    gpa.free(block);
    try std.testing.expectEqual(@as(u64, 0), counting.bytes_live);
    try std.testing.expect(counting.bytes_peak >= 100 + 1000 * 4);
}

test "a gate sees no growth when nothing allocates" {
    // The pattern the zero-allocation gates use: take growths() before and after
    // work that only uses preallocated memory.
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    var list: std.ArrayList(u32) = try .initCapacity(gpa, 64);
    defer list.deinit(gpa);
    const before = counting.growths();
    for (0..64) |number| list.appendAssumeCapacity(@intCast(number));
    try std.testing.expectEqual(before, counting.growths());
    try list.append(gpa, 64);
    try std.testing.expect(counting.growths() > before);
}
