//! Containers: the unit of addressing. Their instructions are one contiguous
//! range of the program's instruction array; named children (knots, stitches, labelled
//! gathers) are a range of the named table. Stored as SoA (`std.MultiArrayList`).

const std = @import("std");
const index = @import("index.zig");
const ContainerIndex = index.ContainerIndex;
const InstructionIndex = index.InstructionIndex;
const StringId = index.StringId;

/// `index_in_parent` of a container that is only reachable by name.
pub const named_only = std.math.maxInt(u32);

pub const ContainerFlags = packed struct(u8) {
    visits_counted: bool = false,
    turns_counted: bool = false,
    /// Count a visit only when the container is entered at its start.
    count_start_only: bool = false,
    padding: u5 = 0,
};

pub const ContainerInfo = struct {
    instruction_first: InstructionIndex,
    instruction_count: u32,
    parent: ContainerIndex,
    /// The content index of this container in its parent, or `named_only`.
    index_in_parent: u32,
    /// The root has depth 0.
    depth: u16,
    flags: ContainerFlags,
    /// `.none` for anonymous containers.
    name: StringId,
    /// The dotted path, for save/load and choice ids.
    path: StringId,
    /// ink's shuffle seed for this container.
    path_hash: u32,
    named_first: u32,
    named_count: u32,
    /// The dense index into the visit and turn arrays, or `none` if neither is counted.
    count_slot: u32,
};

pub const no_count_slot = std.math.maxInt(u32);

/// `extern`: program images write it as raw bytes, so its field order is fixed.
pub const NamedEntry = extern struct {
    name: StringId,
    child: ContainerIndex,
};
