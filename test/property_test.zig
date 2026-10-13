//! Properties of the allocator, checked against an independent model of the
//! space: an ordered list of segments, each live or free, with free
//! neighbours always merged. After every call:
//!
//! - an allocation lies inside one free segment of the model, so it never
//!   overlaps another or runs past the end;
//! - `allocate` fails exactly when the original's rule says it must: no
//!   node left, or no free segment whose bin (size rounded down) reaches the
//!   request's bin (size rounded up);
//! - the reports match the model: free space, the largest region's bin,
//!   and the number of free regions in every bin, which proves that every
//!   free range has merged with its free neighbours;
//! - freeing everything leaves one free region, and the whole space
//!   allocates at offset 0.
//!
//! Sizes here are at least 1: a zero-size allocation shares its offset with
//! its neighbour, which the model cannot tell apart. The differential tests
//! cover zero sizes.

const std = @import("std");
const testing = std.testing;
const oa = @import("offset_allocator");
const small_float = oa.small_float;

const Segment = struct { offset: u32, size: u32, live: bool };

fn Model(comptime Allocator: type) type {
    return struct {
        gpa: std.mem.Allocator,
        total: u32,
        max_allocs: u32,
        segments: std.ArrayList(Segment),
        live: std.ArrayList(Allocator.Allocation),

        const Self = @This();

        fn init(gpa: std.mem.Allocator, total: u32, max_allocs: u32) !Self {
            var self: Self = .{ .gpa = gpa, .total = total, .max_allocs = max_allocs, .segments = .empty, .live = .empty };
            try self.segments.append(gpa, .{ .offset = 0, .size = total, .live = false });
            return self;
        }

        fn deinit(self: *Self) void {
            self.segments.deinit(self.gpa);
            self.live.deinit(self.gpa);
        }

        /// Nodes the allocator has left: each segment is one node, and one
        /// node is always held back.
        fn nodesLeft(self: *const Self) u32 {
            return self.max_allocs - 1 - @as(u32, @intCast(self.segments.items.len));
        }

        fn expectAllocate(self: *Self, allocator: *Allocator, size: u32) !bool {
            const want_bin = small_float.uintToFloatRoundUp(size);
            var fits = false;
            for (self.segments.items) |s| {
                if (!s.live and small_float.uintToFloatRoundDown(s.size) >= want_bin) fits = true;
            }
            const expect_ok = fits and self.nodesLeft() > 0;

            const a = allocator.allocate(size) catch |err| {
                try testing.expectEqual(error.NoSpace, err);
                try testing.expect(!expect_ok);
                return false;
            };
            try testing.expect(expect_ok);
            try testing.expectEqual(size, allocator.allocationSize(a));

            // The allocation starts a free segment that holds it.
            const i = for (self.segments.items, 0..) |s, i| {
                if (s.offset == a.offset) break i;
            } else return error.TestUnexpectedResult;
            const s = self.segments.items[i];
            try testing.expect(!s.live);
            try testing.expect(s.size >= size);
            try testing.expect(small_float.uintToFloatRoundDown(s.size) >= want_bin);

            self.segments.items[i] = .{ .offset = s.offset, .size = size, .live = true };
            if (s.size > size) {
                try self.segments.insert(self.gpa, i + 1, .{ .offset = s.offset + size, .size = s.size - size, .live = false });
            }
            try self.live.append(self.gpa, a);
            return true;
        }

        fn free(self: *Self, allocator: *Allocator, live_index: usize) !void {
            const a = self.live.swapRemove(live_index);
            allocator.free(a);

            var i = for (self.segments.items, 0..) |s, i| {
                if (s.offset == a.offset) break i;
            } else return error.TestUnexpectedResult;
            try testing.expect(self.segments.items[i].live);
            self.segments.items[i].live = false;
            if (i + 1 < self.segments.items.len and !self.segments.items[i + 1].live) {
                self.segments.items[i].size += self.segments.items[i + 1].size;
                _ = self.segments.orderedRemove(i + 1);
            }
            if (i > 0 and !self.segments.items[i - 1].live) {
                self.segments.items[i - 1].size += self.segments.items[i].size;
                _ = self.segments.orderedRemove(i);
                i -= 1;
            }
        }

        fn expectReports(self: *const Self, allocator: *const Allocator) !void {
            var free_space: u32 = 0;
            var largest_bin: ?u32 = null;
            var counts: [oa.num_leaf_bins]u32 = @splat(0);
            var end: u32 = 0;
            for (self.segments.items) |s| {
                try testing.expectEqual(end, s.offset);
                end += s.size;
                if (s.live) continue;
                free_space += s.size;
                const bin = small_float.uintToFloatRoundDown(s.size);
                counts[bin] += 1;
                largest_bin = @max(largest_bin orelse 0, bin);
            }
            try testing.expectEqual(self.total, end);

            const report = allocator.storageReport();
            if (self.nodesLeft() > 0) {
                try testing.expectEqual(free_space, report.total_free_space);
                const largest = if (largest_bin) |bin| small_float.floatToUint(bin) else 0;
                try testing.expectEqual(largest, report.largest_free_region);
            } else {
                try testing.expectEqual(@as(u32, 0), report.total_free_space);
                try testing.expectEqual(@as(u32, 0), report.largest_free_region);
            }

            const full = allocator.storageReportFull();
            for (full.free_regions, counts, 0..) |region, count, bin| {
                try testing.expectEqual(count, region.count);
                try testing.expectEqual(small_float.floatToUint(@intCast(bin)), region.size);
            }
        }

        fn freeAll(self: *Self, allocator: *Allocator, random: std.Random) !void {
            while (self.live.items.len > 0) {
                try self.free(allocator, random.uintLessThan(usize, self.live.items.len));
                try self.expectReports(allocator);
            }
            try testing.expectEqual(@as(usize, 1), self.segments.items.len);
            // The largest request that fits is the region's bin size, the
            // whole space when that is a bin size.
            const largest = small_float.floatToUint(small_float.uintToFloatRoundDown(self.total));
            const all = try allocator.allocate(largest);
            try testing.expectEqual(@as(u32, 0), all.offset);
            allocator.free(all);
            if (largest < self.total) try testing.expectError(error.NoSpace, allocator.allocate(largest + 1));
        }
    };
}

const Config = struct { total: u32, max_allocs: u32, max_size: u32, steps: u32 };

fn randomSize(random: std.Random, max_size: u32) u32 {
    // Mostly small, sometimes up to the limit, so the bins at both ends see
    // use.
    return switch (random.uintLessThan(u32, 4)) {
        0 => random.intRangeAtMost(u32, 1, 16),
        1 => random.intRangeAtMost(u32, 1, @min(max_size, 1024)),
        else => random.intRangeAtMost(u32, 1, max_size),
    };
}

fn run(comptime Allocator: type, seed: u64, config: Config) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var allocator = try Allocator.init(testing.allocator, config.total, config.max_allocs);
    defer allocator.deinit(testing.allocator);
    var model = try Model(Allocator).init(testing.allocator, config.total, config.max_allocs);
    defer model.deinit();
    try model.expectReports(&allocator);

    // Random allocates and frees, weighted towards whichever keeps the
    // allocator between empty and full.
    for (0..config.steps) |_| {
        const fill = random.uintLessThan(u32, 100);
        if (model.live.items.len > 0 and fill < 45) {
            try model.free(&allocator, random.uintLessThan(usize, model.live.items.len));
        } else {
            _ = try model.expectAllocate(&allocator, randomSize(random, config.max_size));
        }
        try model.expectReports(&allocator);
    }
    try model.freeAll(&allocator, random);

    // Fill to exhaustion, then free everything.
    var failures: u32 = 0;
    while (failures < 64) {
        if (!try model.expectAllocate(&allocator, randomSize(random, config.max_size))) failures += 1;
        try model.expectReports(&allocator);
    }
    try model.freeAll(&allocator, random);
}

const configs = [_]Config{
    // Space runs out first.
    .{ .total = 1 << 20, .max_allocs = 4096, .max_size = 1 << 16, .steps = 6000 },
    // Nodes run out first.
    .{ .total = 1 << 30, .max_allocs = 48, .max_size = 1 << 12, .steps = 4000 },
    // Large sizes in the top bins.
    .{ .total = 0xffff_ffff, .max_allocs = 1024, .max_size = 1 << 30, .steps = 4000 },
    // A tiny space: denorm bins only.
    .{ .total = 100, .max_allocs = 256, .max_size = 12, .steps = 4000 },
};

test "properties: 32-bit node indices" {
    for ([_]u64{ 1, 2, 3, 0x5eed }) |seed| {
        for (configs) |config| try run(oa.Allocator, seed, config);
    }
}

test "properties: 16-bit node indices" {
    for ([_]u64{ 1, 2, 3, 0x5eed }) |seed| {
        for (configs) |config| try run(oa.Allocator16, seed, config);
    }
    // All 65536 nodes, the most 16-bit indices address.
    try run(oa.Allocator16, 7, .{ .total = 1 << 24, .max_allocs = 65536, .max_size = 64, .steps = 3000 });
}

test "NO_SPACE: out of nodes" {
    inline for (.{ oa.Allocator, oa.Allocator16 }) |Allocator| {
        // 4 nodes: one held back, one for the remaining free region, so two
        // allocations that leave a remainder fit, and the third fails.
        var allocator = try Allocator.init(testing.allocator, 1000, 4);
        defer allocator.deinit(testing.allocator);
        const a = try allocator.allocate(10);
        const b = try allocator.allocate(10);
        try testing.expectError(error.NoSpace, allocator.allocate(10));
        // Out of nodes: the report shows no free space although 980 units
        // are free.
        try testing.expectEqual(oa.StorageReport{ .total_free_space = 0, .largest_free_region = 0 }, allocator.storageReport());
        allocator.free(b);
        const c = try allocator.allocate(10);
        try testing.expectEqual(b.offset, c.offset);
        allocator.free(a);
        allocator.free(c);
        try testing.expectEqual(oa.StorageReport{ .total_free_space = 1000, .largest_free_region = 960 }, allocator.storageReport());
    }
}

test "NO_SPACE: a free region too small for the request's bin" {
    inline for (.{ oa.Allocator, oa.Allocator16 }) |Allocator| {
        // 17 units of space: bin 16 (size 16). A request for 17 rounds up
        // to bin 17 (size 18), so it fails although 17 units are free.
        var allocator = try Allocator.init(testing.allocator, 17, 16);
        defer allocator.deinit(testing.allocator);
        try testing.expectError(error.NoSpace, allocator.allocate(17));
        const a = try allocator.allocate(16);
        try testing.expectEqual(@as(u32, 0), a.offset);
        try testing.expectError(error.NoSpace, allocator.allocate(2));
        const b = try allocator.allocate(1);
        try testing.expectEqual(@as(u32, 16), b.offset);
        try testing.expectError(error.NoSpace, allocator.allocate(0));
        try testing.expectEqual(oa.StorageReport{ .total_free_space = 0, .largest_free_region = 0 }, allocator.storageReport());
    }
}

test "allocationSize, Allocation.none and reset" {
    inline for (.{ oa.Allocator, oa.Allocator16 }) |Allocator| {
        var allocator = try Allocator.init(testing.allocator, 1 << 20, 64);
        defer allocator.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 0), allocator.allocationSize(Allocator.Allocation.none));
        try testing.expectEqual(oa.no_space, Allocator.Allocation.none.offset);

        const a = try allocator.allocate(777);
        const z = try allocator.allocate(0);
        try testing.expectEqual(@as(u32, 777), allocator.allocationSize(a));
        try testing.expectEqual(@as(u32, 0), allocator.allocationSize(z));
        try testing.expectEqual(@as(u32, 777), z.offset);

        allocator.reset();
        try testing.expectEqual(oa.StorageReport{ .total_free_space = 1 << 20, .largest_free_region = 1 << 20 }, allocator.storageReport());
        const all = try allocator.allocate(1 << 20);
        try testing.expectEqual(@as(u32, 0), all.offset);
        try testing.expectEqual(a.metadata, all.metadata);
    }
}

test "init: out of memory frees what it took" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, oa.Allocator.init(failing.allocator(), 100, 16));
    try testing.expectError(error.OutOfMemory, oa.Allocator.init(testing.failing_allocator, 100, 16));
}

test "SmallFloat: rounding brackets every value and bins are monotonic" {
    // Exhaustive against the reference in test/differential.zig; here the
    // properties at and around every bin boundary.
    for (0..240) |bin_usize| {
        const bin: u32 = @intCast(bin_usize);
        const size = small_float.floatToUint(bin);
        const next = if (bin < 239) small_float.floatToUint(bin + 1) else 0xffff_ffff;
        for ([_]u32{ size, size +| 1, next -| 1, size + (next - size) / 2 }) |x| {
            if (x < size or x > next) continue;
            const down = small_float.uintToFloatRoundDown(x);
            const up = small_float.uintToFloatRoundUp(x);
            try testing.expect(small_float.floatToUint(down) <= x);
            if (up < 240) try testing.expect(small_float.floatToUint(up) >= x);
            try testing.expect(up == down or up == down + 1);
            try testing.expectEqual(x == small_float.floatToUint(down), up == down);
        }
    }
    // Bins 240 and up wrap past 32 bits, as in the original.
    try testing.expectEqual(@as(u32, 0), small_float.floatToUint(240));
    try testing.expectEqual(@as(u32, 0x2000_0000), small_float.floatToUint(241));
    try testing.expectEqual(@as(u32, 0xc000_0000), small_float.floatToUint(255));
    try testing.expectEqual(@as(u32, 0x8000_0000), small_float.floatToUint(263));
    try testing.expectEqual(@as(u32, 240), small_float.uintToFloatRoundUp(0xffff_ffff));
    try testing.expectEqual(@as(u32, 239), small_float.uintToFloatRoundDown(0xffff_ffff));
}
