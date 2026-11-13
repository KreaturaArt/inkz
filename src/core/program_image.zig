//! The binary program image: a Program written as its arrays, so loading
//! is copying and checking, without parsing. A Program holds only indices into its own
//! arrays, never pointers, so its arrays are the whole program; only the string table's hash
//! index is rebuilt on load. The format is described in docs/program_image.md.
//!
//! Layout, all little-endian:
//! - the header: `magic`, `format_version`, an endianness word, the Program's scalars and
//!   `sections_count`;
//! - the section table: for each section, its element size in bytes and its element count;
//! - the sections, in table order, each padded to a multiple of 8 bytes.
//!
//! Loading never trusts the image: it checks the header and every section's size, the string
//! ends, the opcodes, every index and string id (`check_references`) and then `Program.check`,
//! and returns a named error for anything wrong.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("profile.zig");
const Allocator = std.mem.Allocator;
const program_module = @import("program.zig");
const string_pool = @import("string_pool.zig");
const instruction_module = @import("instruction.zig");
const container_module = @import("container.zig");
const index = @import("index.zig");
const Program = program_module.Program;
const Instruction = instruction_module.Instruction;
const Opcode = instruction_module.Opcode;
const ContainerInfo = container_module.ContainerInfo;
const NamedEntry = container_module.NamedEntry;

pub const magic = "INKZPROG";
pub const format_version: u32 = 1;
const endianness_word: u32 = 0x0102_0304;
const section_alignment = 8;

pub const Error = error{
    /// Not an image, or one this build can't read.
    NotAProgramImage,
    UnsupportedFormatVersion,
    UnsupportedEndianness,
    /// A section's element size differs from this build's.
    SectionLayoutMismatch,
    /// The image is shorter than its sections, or longer.
    ImageTruncated,
    /// Bytes that no Program has: bad string ends, unknown opcodes, indices out of range.
    InvalidImage,
} || Allocator.Error;

const Header = extern struct {
    magic: [8]u8,
    format_version: u32,
    endianness: u32,
    ink_version: u32,
    global_declaration: u32,
    count_slots_count: u32,
    newline: u32,
    sections_count: u32,
    reserved: u32 = 0,
};

const SectionEntry = extern struct { element_bytes: u32, count: u32 };

/// Every section, in image order: what it holds and its element type.
const Section = enum {
    string_bytes,
    string_ends,
    opcodes,
    operands,
    extra,
    instruction_first,
    instruction_count,
    parent,
    index_in_parent,
    depth,
    flags,
    name,
    path,
    path_hash,
    named_first,
    named_count,
    count_slot,
    named,
    globals,
    list_origins,
    list_items,
    externals,

    fn Element(comptime section: Section) type {
        return switch (section) {
            .string_bytes => u8,
            .string_ends => u32,
            .opcodes => Opcode,
            .operands => u32,
            .extra => u32,
            .named => NamedEntry,
            .globals => program_module.GlobalInfo,
            .list_origins => program_module.ListOrigin,
            .list_items => program_module.ListItem,
            .externals => program_module.ExternalInfo,
            else => @FieldType(ContainerInfo, @tagName(section)),
        };
    }
};

const sections_count = @typeInfo(Section).@"enum".field_names.len;

comptime {
    assert(@sizeOf(Header) == 40);
    assert(@sizeOf(SectionEntry) == 8);
    // Elements are copied as bytes, so they must have no padding.
    for (std.enums.values(Section)) |section| {
        assert(std.meta.hasUniqueRepresentation(section.Element()));
    }
}

fn column_of(comptime section: Section) std.meta.FieldEnum(ContainerInfo) {
    comptime assert(@backingInt(section) >= @backingInt(Section.instruction_first));
    comptime assert(@backingInt(section) <= @backingInt(Section.count_slot));
    return @field(std.meta.FieldEnum(ContainerInfo), @tagName(section));
}

/// The bytes of `section` in `program`.
fn section_bytes(program: *const Program, comptime section: Section) []const u8 {
    assert(program.containers.len > 0);
    const strings = program.strings.strings;
    const items: []const section.Element() = switch (section) {
        .string_bytes => strings.bytes,
        .string_ends => strings.ends,
        .opcodes => program.instructions.items(.opcode),
        .operands => program.instructions.items(.operand),
        .extra => program.extra,
        .named => program.named,
        .globals => program.globals,
        .list_origins => program.list_origins,
        .list_items => program.list_items,
        .externals => program.externals,
        else => program.containers.items(comptime column_of(section)),
    };
    assert(items.len < std.math.maxInt(u32));
    return std.mem.sliceAsBytes(items);
}

fn element_count(program: *const Program, comptime section: Section) u32 {
    const bytes = section_bytes(program, section);
    assert(bytes.len % @sizeOf(section.Element()) == 0);
    assert(bytes.len / @sizeOf(section.Element()) < std.math.maxInt(u32));
    return @intCast(bytes.len / @sizeOf(section.Element()));
}

fn padding_of(length: usize) usize {
    assert(length < std.math.maxInt(u32));
    const padded = std.mem.alignForward(usize, length, section_alignment);
    assert(padded - length < section_alignment);
    return padded - length;
}

/// Writes `program` as an image. The same program always gives the same bytes.
pub fn write(program: *const Program, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const profile_zone = profile.begin(.image_write);
    defer profile_zone.end();
    comptime assert(@import("builtin").cpu.arch.endian() == .little);
    assert(program.containers.len > 0);
    const header: Header = .{
        .magic = magic.*,
        .format_version = format_version,
        .endianness = endianness_word,
        .ink_version = program.ink_version,
        .global_declaration = @backingInt(program.global_declaration),
        .count_slots_count = program.count_slots_count,
        .newline = @backingInt(program.newline),
        .sections_count = sections_count,
    };
    try writer.writeAll(std.mem.asBytes(&header));
    inline for (comptime std.enums.values(Section)) |section| {
        const entry: SectionEntry = .{
            .element_bytes = @sizeOf(section.Element()),
            .count = element_count(program, section),
        };
        try writer.writeAll(std.mem.asBytes(&entry));
    }
    const zeros: [section_alignment]u8 = @splat(0);
    inline for (comptime std.enums.values(Section)) |section| {
        const bytes = section_bytes(program, section);
        try writer.writeAll(bytes);
        try writer.writeAll(zeros[0..padding_of(bytes.len)]);
    }
}

/// The image's size in bytes, as `write` writes it.
pub fn image_bytes(program: *const Program) u64 {
    assert(program.containers.len > 0);
    var total: u64 = @sizeOf(Header) + sections_count * @sizeOf(SectionEntry);
    inline for (comptime std.enums.values(Section)) |section| {
        const length = section_bytes(program, section).len;
        total += length + padding_of(length);
    }
    assert(total % section_alignment == 0);
    return total;
}

/// Where each section's bytes are in an image, after its header and table were checked.
const Layout = struct {
    header: Header,
    sections: [sections_count][]const u8,

    fn of(bytes: []const u8) Error!Layout {
        assert(bytes.len < std.math.maxInt(u32));
        if (bytes.len < @sizeOf(Header)) return error.NotAProgramImage;
        var layout: Layout = undefined;
        @memcpy(std.mem.asBytes(&layout.header), bytes[0..@sizeOf(Header)]);
        const header = &layout.header;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotAProgramImage;
        if (header.endianness != endianness_word) return error.UnsupportedEndianness;
        if (header.format_version != format_version) return error.UnsupportedFormatVersion;
        if (header.sections_count != sections_count) return error.SectionLayoutMismatch;
        const table_end = @sizeOf(Header) + sections_count * @sizeOf(SectionEntry);
        if (bytes.len < table_end) return error.ImageTruncated;
        var at: u64 = table_end;
        inline for (comptime std.enums.values(Section), 0..) |section, position| {
            var entry: SectionEntry = undefined;
            const entry_at = @sizeOf(Header) + position * @sizeOf(SectionEntry);
            @memcpy(std.mem.asBytes(&entry), bytes[entry_at..][0..@sizeOf(SectionEntry)]);
            if (entry.element_bytes != @sizeOf(section.Element())) {
                return error.SectionLayoutMismatch;
            }
            const length = @as(u64, entry.count) * entry.element_bytes;
            if (at + length > bytes.len) return error.ImageTruncated;
            layout.sections[position] = bytes[@intCast(at)..][0..@intCast(length)];
            at += length + padding_of(@intCast(length));
        }
        if (at != bytes.len) return error.ImageTruncated;
        assert(at >= table_end);
        return layout;
    }

    fn get(layout: *const Layout, comptime section: Section) []const u8 {
        assert(layout.header.sections_count == sections_count);
        const bytes = layout.sections[@backingInt(section)];
        assert(bytes.len % @sizeOf(section.Element()) == 0);
        return bytes;
    }

    fn count(layout: *const Layout, comptime section: Section) u32 {
        assert(@sizeOf(section.Element()) > 0);
        const length = layout.get(section).len / @sizeOf(section.Element());
        assert(length < std.math.maxInt(u32));
        return @intCast(length);
    }
};

/// Copies a section into a new array. Sections may sit at any alignment in the caller's
/// buffer, so they are copied as bytes.
fn copy_section(
    gpa: Allocator,
    layout: *const Layout,
    comptime section: Section,
) Allocator.Error![]section.Element() {
    const bytes = layout.get(section);
    assert(bytes.len < std.math.maxInt(u32));
    const items = try gpa.alloc(section.Element(), layout.count(section));
    @memcpy(std.mem.sliceAsBytes(items), bytes);
    assert(items.len == layout.count(section));
    return items;
}

/// The bytes of an opcode section are all opcodes; other enums are open (indices) or
/// packed bits, checked below.
/// Which byte values name an opcode: one lookup per byte (std.enums.fromInt scans the
/// enum's values, and was two thirds of a load).
const opcode_bytes: [256]bool = table: {
    var table: [256]bool = @splat(false);
    for (std.enums.values(Opcode)) |opcode| table[@backingInt(opcode)] = true;
    break :table table;
};

fn check_opcodes(bytes: []const u8) Error!void {
    assert(@sizeOf(Opcode) == 1);
    assert(bytes.len < std.math.maxInt(u32));
    for (bytes) |byte| {
        if (!opcode_bytes[byte]) return error.InvalidImage;
    }
}

test "the opcode check accepts exactly the bytes that name an opcode" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const named = std.enums.fromInt(Opcode, byte) != null;
        try std.testing.expectEqual(named, opcode_bytes[byte]);
        const result = check_opcodes(&.{ @backingInt(Opcode.text), byte });
        if (named) try result else try std.testing.expectError(error.InvalidImage, result);
    }
}

/// String ends: string 0 is empty, ends never decrease, the last is the byte count.
fn check_string_ends(ends: []const u32, bytes_count: usize) Error!void {
    assert(bytes_count < std.math.maxInt(u32));
    assert(ends.len < std.math.maxInt(u32));
    if (ends.len == 0 or ends[0] != 0) return error.InvalidImage;
    var previous: u32 = 0;
    for (ends) |end| {
        if (end < previous) return error.InvalidImage;
        previous = end;
    }
    if (previous != bytes_count) return error.InvalidImage;
}

/// Loads a program from an image, copying everything out of `bytes`.
pub fn load(gpa: Allocator, bytes: []const u8) Error!Program {
    assert(bytes.len < std.math.maxInt(u32));
    assert(sections_count > 0);
    const shape_zone = profile.begin(.image_shape);
    const layout = try Layout.of(bytes);
    try check_shape(&layout);
    shape_zone.end();
    const strings_zone = profile.begin(.image_strings);
    var strings = try load_strings(gpa, &layout);
    strings_zone.end();
    const arrays_zone = profile.begin(.image_arrays);
    var program = load_arrays(gpa, &layout, strings) catch |err| {
        strings.deinit(gpa);
        return err;
    };
    arrays_zone.end();
    errdefer program.deinit(gpa);
    const references_zone = profile.begin(.image_references);
    try check_references(&program);
    references_zone.end();
    if (program.check() != .ok) return error.InvalidImage;
    return program;
}

/// What can be checked on the raw sections: opcodes, flag bits, equal column lengths.
fn check_shape(layout: *const Layout) Error!void {
    assert(layout.header.sections_count == sections_count);
    try check_opcodes(layout.get(.opcodes));
    for (layout.get(.flags)) |flags| {
        if (flags & ~@as(u8, 0b111) != 0) return error.InvalidImage;
    }
    if (layout.count(.opcodes) != layout.count(.operands)) return error.InvalidImage;
    const containers = layout.count(.parent);
    if (containers == 0) return error.InvalidImage;
    inline for (comptime std.meta.fieldNames(ContainerInfo)) |name| {
        if (layout.count(@field(Section, name)) != containers) return error.InvalidImage;
    }
    assert(containers > 0);
}

fn load_strings(gpa: Allocator, layout: *const Layout) Error!string_pool.FrozenStringPool {
    assert(layout.header.sections_count == sections_count);
    const string_bytes = try copy_section(gpa, layout, .string_bytes);
    errdefer gpa.free(string_bytes);
    const ends = try copy_section(gpa, layout, .string_ends);
    errdefer gpa.free(ends);
    try check_string_ends(ends, string_bytes.len);
    const strings = string_pool.FrozenStringPool.init_unique(gpa, string_bytes, ends) catch |err|
        return switch (err) {
            error.DuplicateString => error.InvalidImage,
            error.OutOfMemory => error.OutOfMemory,
        };
    assert(strings.count() == ends.len);
    return strings;
}

/// Everything but the strings, copied into a Program that owns `strings` (on success).
fn load_arrays(
    gpa: Allocator,
    layout: *const Layout,
    strings: string_pool.FrozenStringPool,
) Allocator.Error!Program {
    assert(layout.count(.opcodes) == layout.count(.operands));
    assert(strings.count() > 0);
    var instructions: std.MultiArrayList(Instruction) = .empty;
    errdefer instructions.deinit(gpa);
    try instructions.resize(gpa, layout.count(.opcodes));
    @memcpy(std.mem.sliceAsBytes(instructions.items(.opcode)), layout.get(.opcodes));
    @memcpy(std.mem.sliceAsBytes(instructions.items(.operand)), layout.get(.operands));
    var containers: std.MultiArrayList(ContainerInfo) = .empty;
    errdefer containers.deinit(gpa);
    try containers.resize(gpa, layout.count(.parent));
    inline for (comptime std.meta.fieldNames(ContainerInfo)) |name| {
        const column = containers.items(@field(std.meta.FieldEnum(ContainerInfo), name));
        @memcpy(std.mem.sliceAsBytes(column), layout.get(@field(Section, name)));
    }
    const extra = try copy_section(gpa, layout, .extra);
    errdefer gpa.free(extra);
    const named = try copy_section(gpa, layout, .named);
    errdefer gpa.free(named);
    const globals = try copy_section(gpa, layout, .globals);
    errdefer gpa.free(globals);
    const list_origins = try copy_section(gpa, layout, .list_origins);
    errdefer gpa.free(list_origins);
    const list_items = try copy_section(gpa, layout, .list_items);
    errdefer gpa.free(list_items);
    const externals = try copy_section(gpa, layout, .externals);
    const header = layout.header;
    return .{
        .strings = strings,
        .instructions = instructions.toOwnedSlice(),
        .extra = extra,
        .containers = containers.toOwnedSlice(),
        .named = named,
        .globals = globals,
        .list_origins = list_origins,
        .list_items = list_items,
        .externals = externals,
        .global_declaration = @fromBackingInt(header.global_declaration),
        .count_slots_count = header.count_slots_count,
        .ink_version = header.ink_version,
        .newline = @fromBackingInt(header.newline),
    };
}

/// What `Program.check` takes for granted, since programs normally come from the builder:
/// every string id names a string, index ranges fit (in 64 bits), indices that must exist
/// aren't `.none`.
fn check_references(program: *const Program) Error!void {
    const strings: u64 = program.strings.count();
    assert(strings > 0);
    assert(program.containers.len > 0);
    const containers = program.containers;
    if (!is_string(program.newline, strings)) return error.InvalidImage;
    if (!program.global_declaration.is_none() and
        @backingInt(program.global_declaration) >= containers.len) return error.InvalidImage;
    for (0..containers.len) |position| {
        const info = containers.get(position);
        if (!info.name.is_none() and !is_string(info.name, strings)) return error.InvalidImage;
        if (!is_string(info.path, strings)) return error.InvalidImage;
        if (info.instruction_first.is_none()) return error.InvalidImage;
        const first: u64 = @backingInt(info.instruction_first);
        const instructions_end = first + info.instruction_count;
        if (instructions_end > program.instructions.len) return error.InvalidImage;
        const named_end = @as(u64, info.named_first) + info.named_count;
        if (named_end > program.named.len) return error.InvalidImage;
    }
    for (program.named) |entry| if (!is_string(entry.name, strings)) return error.InvalidImage;
    for (program.globals) |global| if (!is_string(global.name, strings)) return error.InvalidImage;
    for (program.externals) |external| {
        if (!is_string(external.name, strings)) return error.InvalidImage;
    }
    for (program.list_origins) |origin| {
        if (!is_string(origin.name, strings) or origin.items_first.is_none()) {
            return error.InvalidImage;
        }
    }
    for (program.list_items) |item| {
        const named = is_string(item.name, strings) and is_string(item.full_name, strings);
        if (!named or item.origin.is_none()) return error.InvalidImage;
    }
}

fn is_string(id: index.StringId, strings: u64) bool {
    assert(strings > 0);
    assert(strings <= std.math.maxInt(u32));
    return @backingInt(id) < strings;
}
