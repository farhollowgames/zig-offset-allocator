//! Tests for the `Ranges` layer (src/ranges.zig), both node index widths.
//!
//! The core under it is proven against the original elsewhere; these check
//! what the layer adds: offsets aligned to the unit, byte ranges that never
//! overlap (against a simple model of the live ranges), sizes rounded up to
//! whole units, handles that go stale on free, reset and reuse, and spaces
//! past 4 GiB.
//!
//! Zig 0.17 has no way to catch a panic inside a test, so the panic in
//! `free` is tested in two parts: here through `checkHandle` and `isLive`,
//! the check `free` runs before it panics, and in test/ranges_panic.zig, a
//! program `zig build test` runs and expects to abort with the message.

const std = @import("std");
const testing = std.testing;
const oa = @import("offset_allocator");

const Range = struct { offset: u64, size: u64 };

/// The live byte ranges, unordered, for checking a new range against.
fn Model(comptime Ranges: type) type {
    return struct {
        live: std.ArrayList(Ranges.Handle) = .empty,
        sizes: std.ArrayList(Range) = .empty,

        const Self = @This();

        fn deinit(self: *Self) void {
            self.live.deinit(testing.allocator);
            self.sizes.deinit(testing.allocator);
        }

        fn expectAllocate(self: *Self, ranges: *Ranges, size_bytes: u64, total_bytes: u64) !void {
            const handle = ranges.allocate(size_bytes) catch |err| {
                try testing.expectEqual(error.NoSpace, err);
                return;
            };
            const unit = ranges.unitBytes();
            try testing.expect(ranges.isLive(handle));
            try testing.expectEqual(@as(u64, 0), handle.offset % unit);

            // At least the request, less than a unit more.
            const size = ranges.sizeOf(handle);
            try testing.expect(size >= size_bytes);
            try testing.expect(size < size_bytes + unit);
            try testing.expectEqual(@as(u64, 0), size % unit);
            try testing.expect(handle.offset + size <= total_bytes);

            // No byte in two live ranges. Empty ranges hold no bytes.
            for (self.sizes.items) |other| {
                const disjoint = size == 0 or other.size == 0 or
                    handle.offset + size <= other.offset or other.offset + other.size <= handle.offset;
                try testing.expect(disjoint);
            }

            try self.live.append(testing.allocator, handle);
            try self.sizes.append(testing.allocator, .{ .offset = handle.offset, .size = size });
        }

        fn free(self: *Self, ranges: *Ranges, index: usize) !void {
            const handle = self.live.swapRemove(index);
            _ = self.sizes.swapRemove(index);
            try ranges.checkHandle(handle);
            ranges.free(handle);
            try testing.expect(!ranges.isLive(handle));
            try testing.expectError(error.StaleGeneration, ranges.checkHandle(handle));
        }

        /// Every live handle is live and holds the bytes it was given, and
        /// the free space is the total less the live ranges, unless out of
        /// nodes.
        fn expectState(self: *const Self, ranges: *const Ranges, total_bytes: u64) !void {
            var used: u64 = 0;
            for (self.live.items, self.sizes.items) |handle, range| {
                try testing.expect(ranges.isLive(handle));
                try testing.expectEqual(range.size, ranges.sizeOf(handle));
                used += range.size;
            }
            const report = ranges.storageReport();
            if (report.total_free_space != 0) try testing.expectEqual(total_bytes - used, report.total_free_space);
        }
    };
}

const Config = struct { unit: u32, total_bytes: u64, max_allocs: u32, max_size: u64, steps: u32 };

fn randomSize(random: std.Random, config: Config) u64 {
    // Mostly small and unaligned, sometimes zero, an exact unit multiple or
    // large.
    return switch (random.uintLessThan(u32, 8)) {
        0 => 0,
        1 => random.intRangeAtMost(u64, 1, config.unit),
        2 => @as(u64, config.unit) * random.intRangeAtMost(u64, 1, 16),
        3, 4 => random.intRangeAtMost(u64, 1, @min(config.max_size, @as(u64, config.unit) * 64)),
        else => random.intRangeAtMost(u64, 1, config.max_size),
    };
}

fn run(comptime Ranges: type, seed: u64, config: Config) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var ranges = try Ranges.init(testing.allocator, config.total_bytes, config.max_allocs, config.unit);
    defer ranges.deinit(testing.allocator);
    var model: Model(Ranges) = .{};
    defer model.deinit();
    // The usable space: whole units only.
    const total = config.total_bytes / config.unit * config.unit;

    for (0..config.steps) |step| {
        if (model.live.items.len > 0 and random.uintLessThan(u32, 100) < 45) {
            try model.free(&ranges, random.uintLessThan(usize, model.live.items.len));
        } else {
            try model.expectAllocate(&ranges, randomSize(random, config), total);
        }
        if (step % 64 == 0) try model.expectState(&ranges, total);
    }

    // Reset with ranges outstanding: every handle goes stale, and the whole
    // space is free again.
    ranges.reset();
    for (model.live.items) |handle| {
        try testing.expect(!ranges.isLive(handle));
        try testing.expectError(error.StaleGeneration, ranges.checkHandle(handle));
    }
    model.live.clearRetainingCapacity();
    model.sizes.clearRetainingCapacity();
    try testing.expectEqual(total, ranges.storageReport().total_free_space);

    // Fill to exhaustion, then free everything back to one region.
    var failures: u32 = 0;
    while (failures < 64) {
        const before = model.live.items.len;
        try model.expectAllocate(&ranges, randomSize(random, config), total);
        if (model.live.items.len == before) failures += 1;
    }
    try model.expectState(&ranges, total);
    while (model.live.items.len > 0) {
        try model.free(&ranges, random.uintLessThan(usize, model.live.items.len));
    }
    try testing.expectEqual(total, ranges.storageReport().total_free_space);
}

const configs = [_]Config{
    // Vulkan uniform offsets in a 16 MiB buffer.
    .{ .unit = 256, .total_bytes = 16 << 20, .max_allocs = 4096, .max_size = 1 << 16, .steps = 8000 },
    // Byte units: the core as it is.
    .{ .unit = 1, .total_bytes = 1 << 20, .max_allocs = 1024, .max_size = 1 << 12, .steps = 6000 },
    // A space that is not a multiple of the unit, nodes running out first.
    .{ .unit = 64, .total_bytes = (1 << 24) + 100, .max_allocs = 48, .max_size = 1 << 14, .steps = 4000 },
    // 64 GiB in 4 KiB pages.
    .{ .unit = 4096, .total_bytes = 64 << 30, .max_allocs = 2048, .max_size = 1 << 30, .steps = 4000 },
};

test "Ranges: aligned, disjoint, rounded up; 32-bit node indices" {
    for ([_]u64{ 1, 2, 3, 0x5eed }) |seed| {
        for (configs) |config| try run(oa.Ranges, seed, config);
    }
}

test "Ranges: aligned, disjoint, rounded up; 16-bit node indices" {
    for ([_]u64{ 1, 2, 3, 0x5eed }) |seed| {
        for (configs) |config| try run(oa.Ranges16, seed, config);
    }
}

test "Ranges: a freed or reset handle is not live, and cannot be freed" {
    inline for (.{ oa.Ranges, oa.Ranges16 }) |Ranges| {
        var ranges = try Ranges.init(testing.allocator, 1 << 20, 64, 256);
        defer ranges.deinit(testing.allocator);

        const a = try ranges.allocate(1000);
        const b = try ranges.allocate(1);
        try testing.expect(ranges.isLive(a));
        try ranges.checkHandle(a);

        // Freed: a second free is caught.
        ranges.free(a);
        try testing.expect(!ranges.isLive(a));
        try testing.expectError(error.StaleGeneration, ranges.checkHandle(a));
        try testing.expect(ranges.isLive(b));

        // Reset: every outstanding handle goes stale.
        ranges.reset();
        try testing.expect(!ranges.isLive(b));
        try testing.expectError(error.StaleGeneration, ranges.checkHandle(b));
        try testing.expect(!ranges.isLive(a));
    }
}

test "Ranges: a reused node has a new generation" {
    inline for (.{ oa.Ranges, oa.Ranges16 }) |Ranges| {
        var ranges = try Ranges.init(testing.allocator, 1 << 20, 64, 256);
        defer ranges.deinit(testing.allocator);

        // Freeing `a` merges it with the free rest; the merged region takes
        // `a`'s node back, and the next allocation splits it again.
        const a = try ranges.allocate(512);
        ranges.free(a);
        const b = try ranges.allocate(512);
        try testing.expectEqual(a.node, b.node);
        try testing.expectEqual(a.offset, b.offset);
        try testing.expect(a.generation != b.generation);
        try testing.expect(ranges.isLive(b));
        try testing.expect(!ranges.isLive(a));
        try testing.expectError(error.StaleGeneration, ranges.checkHandle(a));

        // The same after a reset.
        ranges.reset();
        const c = try ranges.allocate(512);
        try testing.expectEqual(b.node, c.node);
        try testing.expect(!ranges.isLive(b));
        try testing.expect(ranges.isLive(c));
        ranges.free(c);
    }
}

test "Ranges: handles that are not from allocate" {
    inline for (.{ oa.Ranges, oa.Ranges16 }) |Ranges| {
        var ranges = try Ranges.init(testing.allocator, 1 << 20, 64, 256);
        defer ranges.deinit(testing.allocator);
        const a = try ranges.allocate(256);

        // A node past the array.
        try testing.expectError(error.NodeOutOfRange, ranges.checkHandle(.{ .offset = 0, .node = 64, .generation = 0 }));
        // A node that holds the free rest, at its current generation.
        const rest: Ranges.NodeIndex = for (ranges.core.nodes, 0..) |node, i| {
            if (!node.used and node.data_size > 0) break @intCast(i);
        } else unreachable;
        try testing.expectError(error.NodeNotInUse, ranges.checkHandle(.{ .offset = 256, .node = rest, .generation = ranges.generations[rest] }));
        try testing.expect(!ranges.isLive(.{ .offset = 256, .node = rest, .generation = ranges.generations[rest] }));
        ranges.free(a);
    }
}

test "Ranges: units, sizes and reports in bytes" {
    inline for (.{ oa.Ranges, oa.Ranges16 }) |Ranges| {
        // 1000 bytes in 256-byte units: 3 units, the last 232 bytes unused.
        var ranges = try Ranges.init(testing.allocator, 1000, 16, 256);
        defer ranges.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 256), ranges.unitBytes());
        try testing.expectEqual(Ranges.StorageReport{ .total_free_space = 768, .largest_free_region = 768 }, ranges.storageReport());

        const a = try ranges.allocate(1);
        try testing.expectEqual(@as(u64, 0), a.offset);
        try testing.expectEqual(@as(u64, 256), ranges.sizeOf(a));
        const b = try ranges.allocate(257);
        try testing.expectEqual(@as(u64, 256), b.offset);
        try testing.expectEqual(@as(u64, 512), ranges.sizeOf(b));
        try testing.expectError(error.NoSpace, ranges.allocate(1));
        try testing.expectEqual(Ranges.StorageReport{ .total_free_space = 0, .largest_free_region = 0 }, ranges.storageReport());

        // Zero bytes, as in the core: no bytes, a node, and the offset of
        // the next range.
        ranges.free(b);
        const z = try ranges.allocate(0);
        try testing.expectEqual(@as(u64, 256), z.offset);
        try testing.expectEqual(@as(u64, 0), ranges.sizeOf(z));
        try testing.expect(ranges.isLive(z));
        const c = try ranges.allocate(512);
        try testing.expectEqual(@as(u64, 256), c.offset);
        ranges.free(z);
        ranges.free(c);

        const full = ranges.storageReportFull();
        const core_full = ranges.core.storageReportFull();
        for (full.free_regions, core_full.free_regions) |region, core_region| {
            try testing.expectEqual(@as(u64, core_region.size) * 256, region.size);
            try testing.expectEqual(core_region.count, region.count);
        }
        ranges.free(a);
    }
}

test "Ranges: past 4 GiB with a large unit" {
    inline for (.{ oa.Ranges, oa.Ranges16 }) |Ranges| {
        // 1 TiB in 1 MiB units: 2^20 units.
        const unit = 1 << 20;
        const total: u64 = 1 << 40;
        var ranges = try Ranges.init(testing.allocator, total, 4096, unit);
        defer ranges.deinit(testing.allocator);

        // 5 GiB and 6 GiB requests, each more than a u32 holds.
        const a = try ranges.allocate(5 << 30);
        const b = try ranges.allocate((6 << 30) + 1);
        try testing.expectEqual(@as(u64, 0), a.offset);
        try testing.expectEqual(@as(u64, 5 << 30), b.offset);
        try testing.expectEqual(@as(u64, 5 << 30), ranges.sizeOf(a));
        try testing.expectEqual(@as(u64, (6 << 30) + unit), ranges.sizeOf(b));

        // Fill the rest in 64 GiB pieces; the offsets run to the end.
        var last: Ranges.Handle = b;
        var count: u32 = 0;
        while (ranges.allocate(64 << 30)) |h| : (count += 1) {
            try testing.expect(h.offset > last.offset);
            try testing.expect(h.offset + ranges.sizeOf(h) <= total);
            last = h;
        } else |_| {}
        try testing.expectEqual(@as(u32, 15), count);
        try testing.expect(last.offset > (1 << 39));

        // The whole space in one piece after a reset.
        ranges.reset();
        const all = try ranges.allocate(total);
        try testing.expectEqual(@as(u64, 0), all.offset);
        try testing.expectEqual(total, ranges.sizeOf(all));
        try testing.expectError(error.NoSpace, ranges.allocate(1));
        ranges.free(all);
    }
}

test "Ranges: requests too large for the core" {
    // The most units the core manages: 2^32 - 1 in 256-byte units.
    const total: u64 = (1 << 32) * 256 - 256;
    var ranges = try oa.Ranges.init(testing.allocator, total, 16, 256);
    defer ranges.deinit(testing.allocator);
    try testing.expectEqual(total, ranges.storageReport().total_free_space);

    // More than 2^32 - 1 units, and the largest u64, fail without
    // overflowing.
    try testing.expectError(error.NoSpace, ranges.allocate(total + 1));
    try testing.expectError(error.NoSpace, ranges.allocate(std.math.maxInt(u64)));
    const a = try ranges.allocate(1 << 39);
    try testing.expectEqual(@as(u64, 1 << 39), ranges.sizeOf(a));
    ranges.free(a);
}

test "Ranges: init out of memory frees what it took" {
    // The core takes two allocations, the generations a third.
    for (0..3) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, oa.Ranges.init(failing.allocator(), 1 << 20, 16, 256));
    }
}
