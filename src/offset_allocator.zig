//! A fast, hard real-time O(1) offset allocator with minimal fragmentation.
//!
//! Translated to Zig from OffsetAllocator by Sebastian Aaltonen
//! (https://github.com/sebbbi/OffsetAllocator, offsetAllocator.hpp and
//! offsetAllocator.cpp at commit 3610a73), under the original's MIT licence
//! (see LICENSE and NOTICE). The translation keeps the original's algorithm,
//! its bin layout and every step that decides an offset, a node index or a
//! report, so that it gives the same results as the C++;
//! test/differential.zig checks that, field by field, after every call.
//!
//! The allocator hands out ranges of a contiguous space of `size` units
//! (bytes, or elements of a buffer of fixed-size structures: the unit is the
//! caller's). It never touches that space; it returns offsets into it. Free
//! ranges are kept in 256 bins whose sizes follow an 8-bit float (3-bit
//! mantissa, 5-bit exponent), found through a two-level bitmask with two
//! bit scans, so every operation is O(1), and a free range merges with its
//! free neighbours at once.

const std = @import("std");
const assert = std.debug.assert;

pub const num_top_bins = 32;
pub const bins_per_leaf = 8;
pub const top_bins_index_shift = 3;
pub const leaf_bins_index_mask = 0x7;
pub const num_leaf_bins = num_top_bins * bins_per_leaf;

/// The original's `Allocation::NO_SPACE`: the offset of `Allocation.none`.
/// `allocate` returns `error.NoSpace` where the original returns an
/// allocation holding it.
pub const no_space: u32 = 0xffffffff;

/// The original's default for `maxAllocs`.
pub const default_max_allocs: u32 = 128 * 1024;

pub const StorageReport = struct {
    total_free_space: u32,
    largest_free_region: u32,
};

pub const StorageReportFull = struct {
    free_regions: [num_leaf_bins]Region,

    pub const Region = struct {
        /// The bin's size: the smallest free region the bin holds.
        size: u32,
        /// The number of free regions in the bin.
        count: u32,
    };
};

/// Allocator with 32-bit node indices: up to 2^32 - 1 nodes.
pub const Allocator = AllocatorOf(u32);

/// Allocator with 16-bit node indices (the original's
/// `USE_16_BIT_NODE_INDICES`): half the metadata, at most 65536 nodes.
pub const Allocator16 = AllocatorOf(u16);

/// The bin sizes: a float with a 3-bit mantissa and a 5-bit exponent, so
/// each size class wastes at most 12.5 percent (6.25 on average).
pub const small_float = struct {
    pub const mantissa_bits = 3;
    pub const mantissa_value = 1 << mantissa_bits;
    pub const mantissa_mask = mantissa_value - 1;

    /// The smallest bin whose size is at least `size`: the bin an
    /// allocation of `size` can come from. 0 to 240.
    pub fn uintToFloatRoundUp(size: u32) u32 {
        // Rounding down, then up a bin when any bit below the mantissa is
        // set. Adding (not or-ing) lets the mantissa carry into the exponent.
        const start = mantissaStartBit(size);
        return uintToFloatRoundDown(size) + @intFromBool((size >> start) << start != size);
    }

    /// The largest bin whose size is at most `size`: the bin a free region
    /// of `size` goes in. 0 to 239.
    pub fn uintToFloatRoundDown(size: u32) u32 {
        // With the hidden bit kept, `size >> start` is the mantissa plus
        // `mantissa_value`, which adds the 1 the exponent is ahead of
        // `start`. A denorm (below `mantissa_value`) starts at bit 0 and is
        // its own mantissa.
        const start = mantissaStartBit(size);
        return (@as(u32, start) << mantissa_bits) + (size >> start);
    }

    /// The lowest bit of `size`'s mantissa: `mantissa_bits` below its
    /// highest set bit, or 0 for a denorm. The original branches on denorms;
    /// setting bit `mantissa_bits` gives the same without a branch, since it
    /// leaves a normalized size's highest bit and lifts a denorm's to it.
    fn mantissaStartBit(size: u32) u5 {
        return @intCast((31 - mantissa_bits) - @clz(size | mantissa_value));
    }

    /// The size of bin `float_value`, which must be below 264: the original
    /// shifts by `exponent - 1` and is undefined from 264 on. Bins 240 and
    /// up overflow 32 bits and wrap, as in the original (whose
    /// `storageReportFull` reports bins up to 255).
    pub fn floatToUint(float_value: u32) u32 {
        assert(float_value < 33 << mantissa_bits);
        const exponent = float_value >> mantissa_bits;
        const mantissa = float_value & mantissa_mask;
        if (exponent == 0) {
            // Denorms.
            return mantissa;
        } else {
            const shift: u5 = @intCast(exponent - 1);
            return (mantissa | mantissa_value) << shift;
        }
    }
};

/// The index of the lowest bit of `bit_mask` at or above `start_bit_index`,
/// or null (the original's `NO_SPACE`).
fn findLowestSetBitAfter(bit_mask: u32, start_bit_index: u5) ?u5 {
    const mask_before_start_index = (@as(u32, 1) << start_bit_index) - 1;
    const mask_after_start_index = ~mask_before_start_index;
    const bits_after = bit_mask & mask_after_start_index;
    if (bits_after == 0) return null;
    return @intCast(@ctz(bits_after));
}

/// The allocator, with node indices of type `NodeIndex` (`u32` or `u16`).
/// It owns its node arrays, so a copy of it shares them: once copied, only
/// the copy may be used, as only the target of a C++ move may.
pub fn AllocatorOf(comptime NodeIndex: type) type {
    comptime assert(NodeIndex == u32 or NodeIndex == u16);

    return struct {
        size: u32,
        max_allocs: u32,
        free_storage: u32,

        used_bins_top: u32,
        used_bins: [num_top_bins]u8,
        bin_indices: [num_leaf_bins]NodeIndex,

        nodes: []Node,
        /// A stack of free node indices; `free_offset` is its top.
        free_nodes: []NodeIndex,
        free_offset: u32,

        const Self = @This();

        /// The largest `max_allocs` the node index type can address.
        pub const max_max_allocs: u32 = if (NodeIndex == u16) 65536 else std.math.maxInt(u32);

        const unused: NodeIndex = std.math.maxInt(NodeIndex);

        /// A range from `allocate`, valid until it is freed or the allocator
        /// is reset. The core does not check that, as the original does
        /// not: a stale one given to `free` or `allocationSize` reads
        /// whichever node took its index. `Ranges` stamps a generation into
        /// its handles and checks it.
        pub const Allocation = struct {
            offset: u32,
            /// Internal: the node index, which `free` and `allocationSize`
            /// read.
            metadata: NodeIndex,

            /// The original's default `Allocation`, which it also returns
            /// when out of space; `allocationSize(none)` is 0.
            pub const none: Allocation = .{ .offset = no_space, .metadata = unused };
        };

        /// A free region or an allocation: the original's fields, with
        /// `used` moved ahead of the indices (`extern` keeps this order).
        /// A new node's four indices are then stored as one vector and its
        /// size on its own, so a read of the size soon after, as the next
        /// `free` of a neighbour makes, does not wait for the vector.
        pub const Node = extern struct {
            data_offset: u32 = 0,
            data_size: u32 = 0,
            used: bool = false,
            bin_list_prev: NodeIndex = unused,
            bin_list_next: NodeIndex = unused,
            neighbor_prev: NodeIndex = unused,
            neighbor_next: NodeIndex = unused,
        };

        /// An allocator over `size` units, with room for `max_allocs` nodes
        /// (allocations plus free regions; one is held back, as in the
        /// original). `max_allocs` is at least 2 (the original misbehaves
        /// below) and at most `max_max_allocs`. The node arrays come from
        /// `gpa`; nothing allocates after this.
        pub fn init(gpa: std.mem.Allocator, size: u32, max_allocs: u32) error{OutOfMemory}!Self {
            assert(max_allocs >= 2);
            assert(max_allocs <= max_max_allocs);

            const nodes = try gpa.alloc(Node, max_allocs);
            errdefer gpa.free(nodes);
            const free_nodes = try gpa.alloc(NodeIndex, max_allocs);

            var self: Self = .{
                .size = size,
                .max_allocs = max_allocs,
                .free_storage = undefined,
                .used_bins_top = undefined,
                .used_bins = undefined,
                .bin_indices = undefined,
                .nodes = nodes,
                .free_nodes = free_nodes,
                .free_offset = undefined,
            };
            self.reset();
            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.nodes);
            gpa.free(self.free_nodes);
            self.* = undefined;
        }

        /// Frees everything: back to one free region of `size`. Every
        /// outstanding allocation becomes invalid.
        pub fn reset(self: *Self) void {
            self.free_storage = 0;
            self.used_bins_top = 0;
            self.free_offset = self.max_allocs - 1;

            @memset(&self.used_bins, 0);
            @memset(&self.bin_indices, unused);

            // The original allocates fresh, default-initialized arrays here.
            // Copying 16 nodes at a time lets the stores be whole vectors: a
            // node is 28 bytes (20 with 16-bit indices), which no vector
            // store fits.
            const nodes = self.nodes;
            const block: [16]Node = @splat(.{});
            var i: usize = 0;
            while (i + block.len <= nodes.len) : (i += block.len) {
                nodes[i..][0..block.len].* = block;
            }
            @memset(nodes[i..], .{});

            // The freelist is a stack. Nodes in inverse order so that [0]
            // pops first.
            const free_nodes = self.free_nodes;
            const lanes = 64 / @sizeOf(NodeIndex);
            const Lanes = @Vector(lanes, NodeIndex);
            // With fewer nodes than lanes, the lanes below 0 wrap, and the
            // loop stores none of them.
            var descending: Lanes = @as(Lanes, @splat(@intCast(free_nodes.len - 1))) -%
                std.simd.iota(NodeIndex, lanes);
            var j: usize = 0;
            while (j + lanes <= free_nodes.len) : (j += lanes) {
                free_nodes[j..][0..lanes].* = descending;
                descending -%= @splat(lanes);
            }
            for (free_nodes[j..], j..) |*free_node, k| {
                free_node.* = @intCast(free_nodes.len - 1 - k);
            }

            // Start state: the whole storage as one big node. The algorithm
            // splits remainders off and pushes them back as smaller nodes.
            _ = self.insertNodeIntoBin(self.size, 0);
        }

        /// A contiguous range of `size` units, or `error.NoSpace` when no
        /// free region fits it or no node is left.
        pub inline fn allocate(self: *Self, size: u32) error{NoSpace}!Allocation {
            const allocation = self.allocatePacked(size);
            if (allocation.offset == no_space) return error.NoSpace;
            return .{ .offset = allocation.offset, .metadata = allocation.metadata };
        }

        /// `Allocation` as one integer, which a function returns in a
        /// register; a struct comes back through memory.
        const PackedAllocation = packed struct { offset: u32, metadata: NodeIndex };

        /// The original's `allocate`: offset `no_space` when out of space or
        /// nodes. No allocation has that offset: every offset is below
        /// `size`, or 0 when `size` is 0.
        fn allocatePacked(self: *Self, size: u32) PackedAllocation {
            const none: PackedAllocation = .{ .offset = no_space, .metadata = unused };

            // Out of nodes?
            if (self.free_offset == 0) return none;

            // Round up to a bin index so that the bin is at least the size:
            // the smallest bin that fits.
            const min_bin_index = small_float.uintToFloatRoundUp(size);

            const min_top_bin_index: u5 = @intCast(min_bin_index >> top_bins_index_shift);
            const min_leaf_bin_index: u5 = @intCast(min_bin_index & leaf_bins_index_mask);

            var top_bin_index = min_top_bin_index;
            var leaf_bin_index: ?u5 = null;

            // If the top bin has free regions, scan its leaf bins. This can
            // find none.
            if (self.used_bins_top & (@as(u32, 1) << top_bin_index) != 0) {
                const leaf_bins = self.used_bins[top_bin_index];
                leaf_bin_index = findLowestSetBitAfter(leaf_bins, min_leaf_bin_index);
            }

            // If not, search the top bins from the next one up. (The
            // largest top bin is 30, so this never passes 31.)
            if (leaf_bin_index == null) {
                const above = min_top_bin_index + 1;
                top_bin_index = findLowestSetBitAfter(self.used_bins_top, above) orelse return none;

                // Every leaf bin here fits, since the top bin was rounded
                // up: take the lowest. Its top bit is set, so one is.
                leaf_bin_index = @intCast(@ctz(self.used_bins[top_bin_index]));
            }

            const bin_index = (@as(u32, top_bin_index) << top_bins_index_shift) | leaf_bin_index.?;

            // Pop the bin's first node.
            const node_index: u32 = self.bin_indices[bin_index];
            const node = &self.nodes[node_index];
            const node_total_size = node.data_size;
            node.data_size = size;
            node.used = true;
            self.bin_indices[bin_index] = node.bin_list_next;
            if (node.bin_list_next != unused) self.nodes[node.bin_list_next].bin_list_prev = unused;
            self.free_storage -= node_total_size;

            // Bin empty?
            if (self.bin_indices[bin_index] == unused) {
                self.used_bins[top_bin_index] &= ~(@as(u8, 1) << @intCast(leaf_bin_index.?));

                // All its top bin's leaf bins empty?
                if (self.used_bins[top_bin_index] == 0) {
                    self.used_bins_top &= ~(@as(u32, 1) << top_bin_index);
                }
            }

            // Push the remainder back as a free region in a lower bin.
            const remainder_size = node_total_size - size;
            if (remainder_size > 0) {
                // `node` stays valid: insertNodeIntoBin writes other nodes
                // but never moves the array.
                const new_node_index = self.insertNodeIntoBin(
                    remainder_size,
                    node.data_offset + size,
                );

                // Link the neighbours so that free can merge them, and
                // point the old next neighbour at the new middle node.
                if (node.neighbor_next != unused) {
                    self.nodes[node.neighbor_next].neighbor_prev = @intCast(new_node_index);
                }
                self.nodes[new_node_index].neighbor_prev = @intCast(node_index);
                self.nodes[new_node_index].neighbor_next = node.neighbor_next;
                node.neighbor_next = @intCast(new_node_index);
            }

            return .{ .offset = node.data_offset, .metadata = @intCast(node_index) };
        }

        /// Frees `allocation`, merging it with free neighbours. Freeing
        /// `Allocation.none`, a freed allocation, or one from before a
        /// `reset` is illegal.
        pub fn free(self: *Self, allocation: Allocation) void {
            assert(allocation.metadata != unused);

            const node_index: u32 = allocation.metadata;
            const node = &self.nodes[node_index];

            // Double free?
            assert(node.used);

            // Merge with the neighbours.
            var offset = node.data_offset;
            var size = node.data_size;

            if (node.neighbor_prev != unused and !self.nodes[node.neighbor_prev].used) {
                // The previous neighbour is free: start at its offset and
                // add the sizes.
                const prev_node = &self.nodes[node.neighbor_prev];
                offset = prev_node.data_offset;
                size += prev_node.data_size;

                // Take it out of its bin and put it on the freelist.
                self.removeNodeFromBin(node.neighbor_prev);

                assert(prev_node.neighbor_next == node_index);
                node.neighbor_prev = prev_node.neighbor_prev;
            }

            if (node.neighbor_next != unused and !self.nodes[node.neighbor_next].used) {
                // The next neighbour is free: the offset stays, add the
                // sizes.
                const next_node = &self.nodes[node.neighbor_next];
                size += next_node.data_size;

                self.removeNodeFromBin(node.neighbor_next);

                assert(next_node.neighbor_prev == node_index);
                node.neighbor_next = next_node.neighbor_next;
            }

            const neighbor_next = node.neighbor_next;
            const neighbor_prev = node.neighbor_prev;

            // Put the freed node on the freelist.
            self.free_offset += 1;
            self.free_nodes[self.free_offset] = @intCast(node_index);

            // Insert the (merged) free region into a bin.
            const combined_node_index = self.insertNodeIntoBin(size, offset);

            // Connect the neighbours to the new merged node.
            if (neighbor_next != unused) {
                self.nodes[combined_node_index].neighbor_next = neighbor_next;
                self.nodes[neighbor_next].neighbor_prev = @intCast(combined_node_index);
            }
            if (neighbor_prev != unused) {
                self.nodes[combined_node_index].neighbor_prev = neighbor_prev;
                self.nodes[neighbor_prev].neighbor_next = @intCast(combined_node_index);
            }
        }

        fn insertNodeIntoBin(self: *Self, size: u32, data_offset: u32) u32 {
            // Round down to a bin index so that the region is at least the
            // bin's size.
            const bin_index = small_float.uintToFloatRoundDown(size);

            const top_bin_index: u5 = @intCast(bin_index >> top_bins_index_shift);
            const leaf_bin_index: u3 = @intCast(bin_index & leaf_bins_index_mask);

            // Bin empty before?
            if (self.bin_indices[bin_index] == unused) {
                self.used_bins[top_bin_index] |= @as(u8, 1) << leaf_bin_index;
                self.used_bins_top |= @as(u32, 1) << top_bin_index;
            }

            // Take a node off the freelist and push it on the bin's list.
            const top_node_index = self.bin_indices[bin_index];
            const node_index: u32 = self.free_nodes[self.free_offset];
            self.free_offset -= 1;
            self.nodes[node_index] = .{
                .data_offset = data_offset,
                .data_size = size,
                .bin_list_next = top_node_index,
            };
            if (top_node_index != unused) {
                self.nodes[top_node_index].bin_list_prev = @intCast(node_index);
            }
            self.bin_indices[bin_index] = @intCast(node_index);

            self.free_storage += size;

            return node_index;
        }

        fn removeNodeFromBin(self: *Self, node_index: NodeIndex) void {
            const node = &self.nodes[node_index];

            if (node.bin_list_prev != unused) {
                // Easy case: unlink from the middle of the list.
                self.nodes[node.bin_list_prev].bin_list_next = node.bin_list_next;
                if (node.bin_list_next != unused) {
                    self.nodes[node.bin_list_next].bin_list_prev = node.bin_list_prev;
                }
            } else {
                // The node is first in its bin: find the bin.
                const bin_index = small_float.uintToFloatRoundDown(node.data_size);

                const top_bin_index: u5 = @intCast(bin_index >> top_bins_index_shift);
                const leaf_bin_index: u3 = @intCast(bin_index & leaf_bins_index_mask);

                self.bin_indices[bin_index] = node.bin_list_next;
                if (node.bin_list_next != unused) {
                    self.nodes[node.bin_list_next].bin_list_prev = unused;
                }

                // Bin empty?
                if (self.bin_indices[bin_index] == unused) {
                    self.used_bins[top_bin_index] &= ~(@as(u8, 1) << leaf_bin_index);

                    if (self.used_bins[top_bin_index] == 0) {
                        self.used_bins_top &= ~(@as(u32, 1) << top_bin_index);
                    }
                }
            }

            // Put the node on the freelist.
            self.free_offset += 1;
            self.free_nodes[self.free_offset] = node_index;

            self.free_storage -= node.data_size;
        }

        /// The size `allocation` was allocated with; 0 for
        /// `Allocation.none`.
        pub fn allocationSize(self: *const Self, allocation: Allocation) u32 {
            if (allocation.metadata == unused) return 0;
            return self.nodes[allocation.metadata].data_size;
        }

        /// The total free space and the size of the largest free region's
        /// bin (rounded down to a bin size, so an allocation of this size
        /// always succeeds when a node is left). Both 0 when out of nodes.
        pub fn storageReport(self: *const Self) StorageReport {
            var largest_free_region: u32 = 0;
            var free_storage: u32 = 0;

            // Out of nodes: no free space.
            if (self.free_offset > 0) {
                free_storage = self.free_storage;
                if (self.used_bins_top != 0) {
                    const top_bin_index: u32 = 31 - @clz(self.used_bins_top);
                    const leaf_bin_index: u32 = 7 - @clz(self.used_bins[top_bin_index]);
                    const bin_index = (top_bin_index << top_bins_index_shift) | leaf_bin_index;
                    largest_free_region = small_float.floatToUint(bin_index);
                    assert(free_storage >= largest_free_region);
                }
            }

            return .{
                .total_free_space = free_storage,
                .largest_free_region = largest_free_region,
            };
        }

        /// The number of free regions in each bin, with the bin's size.
        /// O(free regions).
        pub fn storageReportFull(self: *const Self) StorageReportFull {
            var report: StorageReportFull = undefined;
            for (&report.free_regions, 0..) |*region, i| {
                var count: u32 = 0;
                var node_index = self.bin_indices[i];
                while (node_index != unused) {
                    node_index = self.nodes[node_index].bin_list_next;
                    count += 1;
                }
                region.* = .{ .size = small_float.floatToUint(@intCast(i)), .count = count };
            }
            return report;
        }
    };
}
