//! Differential tests: the Zig port against the original C++ built from
//! reference/, both node index widths. Both allocators get the same calls;
//! every result must be identical (offsets, node indices, failures,
//! allocation sizes, both storage reports), and so must every field of
//! their state after every call: the bin tables and masks, the freelist and
//! every node.

const std = @import("std");
const testing = std.testing;
const oa = @import("offset_allocator");
const small_float = oa.small_float;

/// The shim's C ABI for one build of the original: `oa32_` for 32-bit node
/// indices, `oa16_` for 16-bit.
fn Reference(comptime prefix: []const u8) type {
    return struct {
        const Handle = *anyopaque;

        fn ext(comptime name: []const u8, comptime T: type) *const T {
            return @extern(*const T, .{ .name = prefix ++ name });
        }

        const node_index_bytes = ext("node_index_bytes", fn () callconv(.c) u32);
        const uint_to_float_round_up = ext("uint_to_float_round_up", fn (u32) callconv(.c) u32);
        const uint_to_float_round_down = ext("uint_to_float_round_down", fn (u32) callconv(.c) u32);
        const float_to_uint = ext("float_to_uint", fn (u32) callconv(.c) u32);
        const create = ext("create", fn (u32, u32) callconv(.c) ?Handle);
        const create_default = ext("create_default", fn (u32) callconv(.c) ?Handle);
        const move = ext("move", fn (Handle) callconv(.c) ?Handle);
        const destroy = ext("destroy", fn (Handle) callconv(.c) void);
        const reset = ext("reset", fn (Handle) callconv(.c) void);
        const allocate = ext("allocate", fn (Handle, u32, *u32, *u32) callconv(.c) void);
        const free = ext("free", fn (Handle, u32, u32) callconv(.c) void);
        const allocation_size = ext("allocation_size", fn (Handle, u32, u32) callconv(.c) u32);
        const storage_report = ext("storage_report", fn (Handle, *[2]u32) callconv(.c) void);
        const storage_report_full = ext("storage_report_full", fn (Handle, *[2 * oa.num_leaf_bins]u32) callconv(.c) void);
        const state = ext("state", fn (Handle, *[5]u32, *[oa.num_top_bins]u8, *[oa.num_leaf_bins]u32) callconv(.c) void);
        const node = ext("node", fn (Handle, u32, *[7]u32) callconv(.c) void);
        const free_node = ext("free_node", fn (Handle, u32) callconv(.c) u32);
    };
}

const Ref32 = Reference("oa32_");
const Ref16 = Reference("oa16_");

test "the reference builds have the node index widths they claim" {
    try testing.expectEqual(@as(u32, 4), Ref32.node_index_bytes());
    try testing.expectEqual(@as(u32, 2), Ref16.node_index_bytes());
}

// SmallFloat ---------------------------------------------------------------

// Every u32 through both roundings, against the reference. 2^32 values,
// split across threads; each thread checks one range.
test "SmallFloat: uintToFloatRoundUp and uintToFloatRoundDown, every u32" {
    const threads = 16;
    const per_thread: u64 = (1 << 32) / threads;
    var mismatches: [threads]u64 = @splat(0);
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, t| {
        h.* = try std.Thread.spawn(.{}, sweep, .{ @as(u64, t) * per_thread, per_thread, &mismatches[t] });
    }
    for (handles) |h| h.join();
    for (mismatches) |m| try testing.expectEqual(@as(u64, 0), m);
}

fn sweep(start: u64, count: u64, mismatches: *u64) void {
    var x = start;
    while (x < start + count) : (x += 1) {
        const v: u32 = @intCast(x);
        const up = small_float.uintToFloatRoundUp(v);
        const down = small_float.uintToFloatRoundDown(v);
        if (up != Ref32.uint_to_float_round_up(v)) mismatches.* += 1;
        if (down != Ref32.uint_to_float_round_down(v)) mismatches.* += 1;
        // The functions do not depend on the node index width; the 16-bit
        // build on a sparser grid shows it.
        if (x % 251 == 0) {
            if (up != Ref16.uint_to_float_round_up(v)) mismatches.* += 1;
            if (down != Ref16.uint_to_float_round_down(v)) mismatches.* += 1;
        }
    }
}

test "SmallFloat: floatToUint, its whole defined domain" {
    // The original shifts by exponent - 1, defined for values below 264;
    // bins 240 to 263 wrap past 32 bits.
    for (0..33 << small_float.mantissa_bits) |i| {
        const v: u32 = @intCast(i);
        try testing.expectEqual(Ref32.float_to_uint(v), small_float.floatToUint(v));
        try testing.expectEqual(Ref16.float_to_uint(v), small_float.floatToUint(v));
    }
}

// The allocator -----------------------------------------------------------

fn Pair(comptime Allocator: type, comptime Ref: type) type {
    return struct {
        zig: Allocator,
        ref: Ref.Handle,
        live: std.ArrayList(Allocator.Allocation),
        /// Calls made, for the failure message.
        calls: u64 = 0,

        const Self = @This();
        const NodeIndex = @FieldType(Allocator.Allocation, "metadata");

        fn init(size: u32, max_allocs: u32) !Self {
            return .{
                .zig = try Allocator.init(testing.allocator, size, max_allocs),
                .ref = Ref.create(size, max_allocs) orelse return error.OutOfMemory,
                .live = .empty,
            };
        }

        fn deinit(self: *Self) void {
            self.zig.deinit(testing.allocator);
            Ref.destroy(self.ref);
            self.live.deinit(testing.allocator);
        }

        fn allocate(self: *Self, size: u32) !bool {
            self.calls += 1;
            var offset: u32 = undefined;
            var metadata: u32 = undefined;
            Ref.allocate(self.ref, size, &offset, &metadata);
            const result = self.zig.allocate(size);
            if (result) |a| {
                try self.expectEq(offset, a.offset);
                try self.expectEq(metadata, a.metadata);
                try self.expectEq(Ref.allocation_size(self.ref, offset, metadata), self.zig.allocationSize(a));
                try self.live.append(testing.allocator, a);
                return true;
            } else |err| {
                try testing.expectEqual(error.NoSpace, err);
                // The original's failed allocation: NO_SPACE in both fields,
                // the metadata narrowed to the node index type.
                try self.expectEq(oa.no_space, offset);
                try self.expectEq(std.math.maxInt(NodeIndex), metadata);
                return false;
            }
        }

        fn free(self: *Self, live_index: usize) void {
            self.calls += 1;
            const a = self.live.swapRemove(live_index);
            Ref.free(self.ref, a.offset, a.metadata);
            self.zig.free(a);
        }

        fn reset(self: *Self) void {
            self.calls += 1;
            Ref.reset(self.ref);
            self.zig.reset();
            self.live.clearRetainingCapacity();
        }

        /// The C++ move constructor against a Zig copy: Zig moves a value by
        /// copying it. The moved-from C++ allocator is destroyed.
        fn move(self: *Self) !void {
            self.calls += 1;
            const moved = Ref.move(self.ref) orelse return error.OutOfMemory;
            Ref.destroy(self.ref);
            self.ref = moved;
            const copy = self.zig;
            self.zig = undefined;
            self.zig = copy;
        }

        /// Every report and every field of both allocators.
        fn expectSame(self: *Self, check_nodes: bool) !void {
            var report: [2]u32 = undefined;
            Ref.storage_report(self.ref, &report);
            const zig_report = self.zig.storageReport();
            try self.expectEq(report[0], zig_report.total_free_space);
            try self.expectEq(report[1], zig_report.largest_free_region);

            var full: [2 * oa.num_leaf_bins]u32 = undefined;
            Ref.storage_report_full(self.ref, &full);
            const zig_full = self.zig.storageReportFull();
            for (zig_full.free_regions, 0..) |region, i| {
                try self.expectEq(full[2 * i], region.size);
                try self.expectEq(full[2 * i + 1], region.count);
            }

            var scalars: [5]u32 = undefined;
            var used_bins: [oa.num_top_bins]u8 = undefined;
            var bin_indices: [oa.num_leaf_bins]u32 = undefined;
            Ref.state(self.ref, &scalars, &used_bins, &bin_indices);
            const z = &self.zig;
            try self.expectEq(scalars[0], z.size);
            try self.expectEq(scalars[1], z.max_allocs);
            try self.expectEq(scalars[2], z.free_storage);
            try self.expectEq(scalars[3], z.used_bins_top);
            try self.expectEq(scalars[4], z.free_offset);
            for (used_bins, z.used_bins) |r, zz| try self.expectEq(r, zz);
            for (bin_indices, z.bin_indices) |r, zz| try self.expectEq(r, zz);

            if (!check_nodes) return;
            for (self.live.items) |a| {
                try self.expectEq(Ref.allocation_size(self.ref, a.offset, a.metadata), z.allocationSize(a));
            }
            for (z.nodes, z.free_nodes, 0..) |n, free_node, i| {
                var r: [7]u32 = undefined;
                Ref.node(self.ref, @intCast(i), &r);
                try self.expectEq(r[0], n.data_offset);
                try self.expectEq(r[1], n.data_size);
                try self.expectEq(r[2], n.bin_list_prev);
                try self.expectEq(r[3], n.bin_list_next);
                try self.expectEq(r[4], n.neighbor_prev);
                try self.expectEq(r[5], n.neighbor_next);
                try self.expectEq(r[6], @intFromBool(n.used));
                try self.expectEq(Ref.free_node(self.ref, @intCast(i)), free_node);
            }
        }

        fn expectEq(self: *const Self, expected: u32, actual: u32) !void {
            if (expected != actual) {
                std.debug.print("after call {d}: reference {d}, port {d}\n", .{ self.calls, expected, actual });
                return error.TestExpectedEqual;
            }
        }
    };
}

const Config = struct {
    total: u32,
    max_allocs: u32,
    max_size: u32,
    steps: u32,
    /// Compare every node, the freelist and the size of every live
    /// allocation every this many calls (every call when 1); the results,
    /// the reports and the bin tables are compared after every call.
    node_check_every: u32 = 1,
};

fn randomSize(random: std.Random, config: Config) u32 {
    return switch (random.uintLessThan(u32, 16)) {
        0 => 0,
        1, 2, 3 => random.intRangeAtMost(u32, 1, 16),
        4, 5, 6 => random.intRangeAtMost(u32, 1, @max(1, @min(config.max_size, 1024))),
        // A bin size exactly, or one off: the rounding edges.
        7, 8 => blk: {
            const top = small_float.uintToFloatRoundDown(config.max_size);
            const size = small_float.floatToUint(random.uintAtMost(u32, top));
            break :blk switch (random.uintLessThan(u32, 3)) {
                0 => size,
                1 => size +| 1,
                else => size -| 1,
            };
        },
        9 => random.intRangeAtMost(u32, 0, config.total),
        else => random.intRangeAtMost(u32, 1, @max(1, config.max_size)),
    };
}

fn run(comptime Allocator: type, comptime Ref: type, seed: u64, config: Config) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var pair = try Pair(Allocator, Ref).init(config.total, config.max_allocs);
    defer pair.deinit();
    try pair.expectSame(true);

    for (0..2) |round| {
        // Random allocates and frees; a move once, halfway.
        for (0..config.steps) |step| {
            if (round == 0 and step == config.steps / 2) try pair.move();
            if (pair.live.items.len > 0 and random.uintLessThan(u32, 100) < 45) {
                pair.free(random.uintLessThan(usize, pair.live.items.len));
            } else {
                _ = try pair.allocate(randomSize(random, config));
            }
            try pair.expectSame(pair.calls % config.node_check_every == 0);
        }

        // Fill to exhaustion: until 64 requests in a row fail.
        var failures: u32 = 0;
        while (failures < 64) {
            failures = if (try pair.allocate(randomSize(random, config))) 0 else failures + 1;
            try pair.expectSame(pair.calls % config.node_check_every == 0);
        }
        try pair.expectSame(true);

        // Free everything in random order: one free region again.
        while (pair.live.items.len > 0) {
            pair.free(random.uintLessThan(usize, pair.live.items.len));
            try pair.expectSame(pair.calls % config.node_check_every == 0);
        }
        try pair.expectSame(true);
        var count: u32 = 0;
        for (pair.zig.storageReportFull().free_regions) |r| count += r.count;
        try testing.expectEqual(@as(u32, 1), count);

        if (round == 0) {
            // Fill again, then reset with allocations outstanding.
            for (0..config.steps / 4) |_| _ = try pair.allocate(randomSize(random, config));
            pair.reset();
            try pair.expectSame(true);
        }
    }
}

const configs = [_]Config{
    // Space runs out first.
    .{ .total = 1 << 20, .max_allocs = 4096, .max_size = 1 << 16, .steps = 20000, .node_check_every = 16 },
    // Nodes run out first.
    .{ .total = 1 << 30, .max_allocs = 48, .max_size = 1 << 12, .steps = 20000 },
    // The whole u32 range, large sizes in the top bins.
    .{ .total = 0xffff_ffff, .max_allocs = 1024, .max_size = 0xffff_ffff, .steps = 20000, .node_check_every = 4 },
    // A tiny space: denorm bins only.
    .{ .total = 100, .max_allocs = 256, .max_size = 12, .steps = 20000 },
    // A space that is not a bin size, mid-range sizes.
    .{ .total = 1_000_003, .max_allocs = 512, .max_size = 100_000, .steps = 20000, .node_check_every = 4 },
    // The fewest nodes the original works with.
    .{ .total = 1000, .max_allocs = 2, .max_size = 1000, .steps = 2000 },
    // An empty space.
    .{ .total = 0, .max_allocs = 16, .max_size = 4, .steps = 2000 },
};

const seeds = [_]u64{ 1, 2, 3, 4, 0x5eed, 0xdead_beef };

test "allocator: random sequences, 32-bit node indices" {
    for (seeds) |seed| {
        for (configs) |config| try run(oa.Allocator, Ref32, seed, config);
    }
    // The original's default node count, 128 * 1024.
    try run(oa.Allocator, Ref32, 9, .{ .total = 1 << 28, .max_allocs = oa.default_max_allocs, .max_size = 1 << 12, .steps = 200_000, .node_check_every = 50_000 });
}

test "allocator: random sequences, 16-bit node indices" {
    for (seeds) |seed| {
        for (configs) |config| try run(oa.Allocator16, Ref16, seed, config);
    }
    // All 65536 nodes, the most 16-bit indices address.
    try run(oa.Allocator16, Ref16, 9, .{ .total = 1 << 24, .max_allocs = 65536, .max_size = 64, .steps = 200_000, .node_check_every = 50_000 });
}

test "allocator: the default node count" {
    // The C++ default argument against default_max_allocs.
    const ref = Ref32.create_default(1 << 20) orelse return error.OutOfMemory;
    defer Ref32.destroy(ref);
    var scalars: [5]u32 = undefined;
    var used_bins: [oa.num_top_bins]u8 = undefined;
    var bin_indices: [oa.num_leaf_bins]u32 = undefined;
    Ref32.state(ref, &scalars, &used_bins, &bin_indices);
    try testing.expectEqual(oa.default_max_allocs, scalars[1]);
}

test "allocator: allocationSize of a failed allocation" {
    // 32-bit: the original returns 0 for NO_SPACE metadata.
    {
        var pair = try Pair(oa.Allocator, Ref32).init(10, 16);
        defer pair.deinit();
        try testing.expect(!try pair.allocate(11));
        try testing.expectEqual(Ref32.allocation_size(pair.ref, oa.no_space, oa.no_space), pair.zig.allocationSize(oa.Allocator.Allocation.none));
    }
    // 16-bit: the original compares the 16-bit metadata with the 32-bit
    // NO_SPACE, never equal, and reads node 65535. With 65536 nodes that
    // node exists and is never used, so it reports 0 as well; with fewer the
    // original reads out of bounds, and the port still returns 0.
    {
        var pair = try Pair(oa.Allocator16, Ref16).init(10, 65536);
        defer pair.deinit();
        try testing.expect(!try pair.allocate(11));
        try testing.expectEqual(Ref16.allocation_size(pair.ref, oa.no_space, 0xffff), pair.zig.allocationSize(oa.Allocator16.Allocation.none));
    }
}
