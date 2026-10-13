//! The `offset_allocator` module: the ported core (offset_allocator.zig),
//! re-exported unchanged, and the `Ranges` layer over it (ranges.zig).

const core = @import("offset_allocator.zig");
const ranges = @import("ranges.zig");

// The core, the translation of the original.
pub const num_top_bins = core.num_top_bins;
pub const bins_per_leaf = core.bins_per_leaf;
pub const top_bins_index_shift = core.top_bins_index_shift;
pub const leaf_bins_index_mask = core.leaf_bins_index_mask;
pub const num_leaf_bins = core.num_leaf_bins;
pub const no_space = core.no_space;
pub const default_max_allocs = core.default_max_allocs;
pub const StorageReport = core.StorageReport;
pub const StorageReportFull = core.StorageReportFull;
pub const Allocator = core.Allocator;
pub const Allocator16 = core.Allocator16;
pub const AllocatorOf = core.AllocatorOf;
pub const small_float = core.small_float;

// The layer: byte ranges with a unit and checked handles.
pub const Ranges = ranges.Ranges;
pub const Ranges16 = ranges.Ranges16;
pub const RangesOf = ranges.RangesOf;
pub const HandleError = ranges.HandleError;

// Every public declaration of the core is re-exported.
comptime {
    for (@typeInfo(core).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("root.zig does not re-export " ++ name);
    }
}
