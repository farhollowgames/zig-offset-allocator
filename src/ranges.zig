//! Byte ranges with alignment and checked handles, layered over the ported
//! core (offset_allocator.zig).
//!
//! The core hands out u32 offsets in the caller's units and trusts the
//! caller to free each allocation once. `Ranges` puts a fixed power-of-two
//! unit under it (256 bytes for Vulkan uniform buffer offsets, say), so
//! every offset is aligned to the unit and the space reaches past 4 GiB,
//! and it stamps each allocation with a generation, so a stale or double
//! free is caught instead of corrupting the core.
//!
//! It is a layer, not a change to the core: the core stays a line-by-line
//! translation that the differential tests prove against the original, and
//! everything here is built from the core's public API and its node array.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("offset_allocator.zig");

/// Ranges over an `Allocator` (32-bit node indices).
pub const Ranges = RangesOf(core.Allocator);

/// Ranges over an `Allocator16` (16-bit node indices, at most 65536 nodes).
pub const Ranges16 = RangesOf(core.Allocator16);

/// `Ranges.StorageReport`, shared by both node index widths.
const StorageReportBytes = struct {
    total_free_space: u64,
    largest_free_region: u64,
};

/// `Ranges.StorageReportFull`, shared by both node index widths.
const StorageReportFullBytes = struct {
    free_regions: [core.num_leaf_bins]Region,

    pub const Region = struct {
        /// The bin's size in bytes: the smallest free region the bin holds.
        size: u64,
        /// The number of free regions in the bin.
        count: u32,
    };
};

/// Why a handle cannot be freed or read.
pub const HandleError = error{
    /// The handle's node is past the node array: it is not from this
    /// allocator.
    NodeOutOfRange,
    /// The node's generation moved on: the handle was freed already, or
    /// `reset` ran since it was allocated.
    StaleGeneration,
    /// The node holds no allocation. With the generation matching, the
    /// handle was not made by `allocate`.
    NodeNotInUse,
};

/// Ranges over a core allocator type, `Allocator` or `Allocator16`.
///
/// The generations stay in every build mode, ReleaseFast included; only the
/// check in `free` compiles out there. They cost one u32 per node, one load
/// in `allocate` and one store in `free` (see the README's benchmark), and in
/// return `isLive` answers in every mode, `reset` invalidates every handle
/// in every mode, and `Handle` has one layout whatever the mode, so code
/// built in different modes agrees on it.
pub fn RangesOf(comptime Core: type) type {
    return struct {
        core: Core,
        /// The generation of each node, indexed like the core's nodes. An
        /// allocation's handle carries its node's generation; `free` and
        /// `reset` move it on, so older handles stop matching.
        generations: []u32,
        /// log2 of the unit: offsets and sizes in bytes are units shifted
        /// left by this.
        shift: u5,

        const Self = @This();

        pub const NodeIndex = @FieldType(Core.Allocation, "metadata");
        /// The core's `StorageReport` in bytes.
        pub const StorageReport = StorageReportBytes;
        /// The core's `StorageReportFull` with bin sizes in bytes.
        pub const StorageReportFull = StorageReportFullBytes;

        pub const Handle = struct {
            /// The range's first byte, a multiple of the unit.
            offset: u64,
            /// Internal: the core's node index.
            node: NodeIndex,
            /// Internal: the node's generation when it was allocated.
            generation: u32,
        };

        /// Ranges over `size_bytes` bytes in units of `unit` bytes, a power
        /// of two. The core manages `size_bytes / unit` units, which must
        /// fit in u32; a trailing partial unit is never handed out.
        /// `max_allocs` is the core's node count (see `Allocator.init`).
        pub fn init(gpa: std.mem.Allocator, size_bytes: u64, max_allocs: u32, unit: u32) error{OutOfMemory}!Self {
            assert(std.math.isPowerOfTwo(unit));
            const shift: u5 = @intCast(@ctz(unit));
            assert(size_bytes >> shift <= std.math.maxInt(u32));

            var allocator = try Core.init(gpa, @intCast(size_bytes >> shift), max_allocs);
            errdefer allocator.deinit(gpa);
            const generations = try gpa.alloc(u32, max_allocs);
            @memset(generations, 0);

            return .{ .core = allocator, .generations = generations, .shift = shift };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.core.deinit(gpa);
            gpa.free(self.generations);
            self.* = undefined;
        }

        /// The unit in bytes.
        pub fn unitBytes(self: *const Self) u32 {
            return @as(u32, 1) << self.shift;
        }

        /// Frees everything and moves every generation on, so every
        /// outstanding handle goes stale. O(max_allocs), as the core's.
        pub fn reset(self: *Self) void {
            self.core.reset();
            for (self.generations) |*generation| generation.* +%= 1;
        }

        /// A range of at least `size_bytes` bytes, rounded up to whole
        /// units, at an offset that is a multiple of the unit; or
        /// `error.NoSpace` (see `Allocator.allocate`, and a request of more
        /// than 2^32 - 1 units never fits).
        ///
        /// A zero-size request behaves as the core's: it takes a node and
        /// must be freed, holds no bytes, and its offset may equal the
        /// offset of a neighbouring range.
        pub fn allocate(self: *Self, size_bytes: u64) error{NoSpace}!Handle {
            // Rounded up without overflow for any u64.
            const units = (size_bytes >> self.shift) + @intFromBool(size_bytes & (self.unitBytes() - 1) != 0);
            if (units > std.math.maxInt(u32)) return error.NoSpace;

            const allocation = try self.core.allocate(@intCast(units));
            return .{
                .offset = @as(u64, allocation.offset) << self.shift,
                .node = allocation.metadata,
                .generation = self.generations[allocation.metadata],
            };
        }

        /// Frees `handle`. A stale handle (freed already, or allocated
        /// before a `reset`) or one not from this allocator panics in safe
        /// builds (Debug, ReleaseSafe); in ReleaseFast and ReleaseSmall the
        /// check compiles out and such a free is undefined, as in the core.
        pub fn free(self: *Self, handle: Handle) void {
            if (std.debug.runtime_safety) {
                self.checkHandle(handle) catch |err| std.debug.panic(
                    "offset_allocator: free of a handle that is not live ({t}): node {d}, generation {d}, offset {d}",
                    .{ err, handle.node, handle.generation, handle.offset },
                );
            }

            self.generations[handle.node] +%= 1;
            self.core.free(.{ .offset = @intCast(handle.offset >> self.shift), .metadata = handle.node });
        }

        /// Whether `handle` can be freed: its node is this allocator's, in
        /// use, and still at the handle's generation. `free` runs this in
        /// safe builds. A handle from another allocator with a node in range
        /// is not caught.
        ///
        /// A generation wraps after 2^32 frees of one node, so a handle that
        /// old would read as live again.
        pub fn checkHandle(self: *const Self, handle: Handle) HandleError!void {
            if (handle.node >= self.generations.len) return error.NodeOutOfRange;
            if (self.generations[handle.node] != handle.generation) return error.StaleGeneration;
            if (!self.core.nodes[handle.node].used) return error.NodeNotInUse;
        }

        /// Whether `handle` is allocated and not yet freed or reset.
        pub fn isLive(self: *const Self, handle: Handle) bool {
            self.checkHandle(handle) catch return false;
            return true;
        }

        /// The bytes `handle` holds: its request rounded up to whole units.
        /// `handle` must be live.
        pub fn sizeOf(self: *const Self, handle: Handle) u64 {
            assert(self.isLive(handle));
            return @as(u64, self.core.nodes[handle.node].data_size) << self.shift;
        }

        /// The core's report in bytes: the total free space, and the
        /// largest free region rounded down to its bin's size.
        pub fn storageReport(self: *const Self) StorageReport {
            const report = self.core.storageReport();
            return .{
                .total_free_space = @as(u64, report.total_free_space) << self.shift,
                .largest_free_region = @as(u64, report.largest_free_region) << self.shift,
            };
        }

        /// The core's full report with bin sizes in bytes. Bins 240 to 255
        /// keep the core's wrapped sizes, shifted; they never hold a region.
        pub fn storageReportFull(self: *const Self) StorageReportFull {
            const report = self.core.storageReportFull();
            var result: StorageReportFull = undefined;
            for (&result.free_regions, report.free_regions) |*region, core_region| {
                region.* = .{ .size = @as(u64, core_region.size) << self.shift, .count = core_region.count };
            }
            return result;
        }
    };
}
