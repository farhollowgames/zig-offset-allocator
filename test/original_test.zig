//! The original's own tests, translated from offsetAllocatorTests.cpp
//! (sebbbi/OffsetAllocator, commit 3610a73; MIT, see LICENSE and NOTICE), for both node
//! index widths. Patrick Walton's Rust port (pcwalton/offset-allocator)
//! carries the same suite.

const std = @import("std");
const testing = std.testing;
const oa = @import("offset_allocator");
const small_float = oa.small_float;

test "SmallFloat: uintToFloat" {
    // Denorms, exp=1 and exp=2 with mantissa 0 are all exact (3-bit mantissa).
    for (0..17) |i_usize| {
        const i: u32 = @intCast(i_usize);
        try testing.expectEqual(i, small_float.uintToFloatRoundUp(i));
        try testing.expectEqual(i, small_float.uintToFloatRoundDown(i));
    }

    const cases = [_]struct { number: u32, up: u32, down: u32 }{
        .{ .number = 17, .up = 17, .down = 16 },
        .{ .number = 118, .up = 39, .down = 38 },
        .{ .number = 1024, .up = 64, .down = 64 },
        .{ .number = 65536, .up = 112, .down = 112 },
        .{ .number = 529445, .up = 137, .down = 136 },
        .{ .number = 1048575, .up = 144, .down = 143 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.up, small_float.uintToFloatRoundUp(c.number));
        try testing.expectEqual(c.down, small_float.uintToFloatRoundDown(c.number));
    }
}

test "SmallFloat: floatToUint" {
    for (0..17) |i_usize| {
        const i: u32 = @intCast(i_usize);
        try testing.expectEqual(i, small_float.floatToUint(i));
    }

    // float -> uint -> float is exact for every bin below 240 (240 and up
    // overflow 32 bits).
    for (0..240) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const v = small_float.floatToUint(i);
        try testing.expectEqual(i, small_float.uintToFloatRoundUp(v));
        try testing.expectEqual(i, small_float.uintToFloatRoundDown(v));
    }
}

test "SmallFloat: the README's bin size table" {
    // The table in the original README, row by row: bin 8 * row + column.
    const first_of_row = [_]u32{
        0,        8,         16,        32,        64,         128,        256,      512,
        1024,     2048,      4096,      8192,      16384,      32768,      65536,    131072,
        262144,   524288,    1048576,   2097152,   4194304,    8388608,    16777216, 33554432,
        67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648,
    };
    for (first_of_row, 0..) |first, row| {
        const bin: u32 = @intCast(row * 8);
        try testing.expectEqual(first, small_float.floatToUint(bin));
    }
    try testing.expectEqual(@as(u32, 18), small_float.floatToUint(17));
    try testing.expectEqual(@as(u32, 4026531840), small_float.floatToUint(239));
}

fn Suite(comptime Allocator: type) type {
    return struct {
        const total: u32 = 1024 * 1024 * 256;

        fn expectClean(allocator: *Allocator) !void {
            // No fragmentation left: the whole space allocates at offset 0.
            const all = try allocator.allocate(total);
            try testing.expectEqual(@as(u32, 0), all.offset);
            allocator.free(all);
        }

        fn basic() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);
            const a = try allocator.allocate(1337);
            try testing.expectEqual(@as(u32, 0), a.offset);
            allocator.free(a);
        }

        fn simple() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);

            const a = try allocator.allocate(0);
            try testing.expectEqual(@as(u32, 0), a.offset);
            const b = try allocator.allocate(1);
            try testing.expectEqual(@as(u32, 0), b.offset);
            const c = try allocator.allocate(123);
            try testing.expectEqual(@as(u32, 1), c.offset);
            const d = try allocator.allocate(1234);
            try testing.expectEqual(@as(u32, 124), d.offset);

            allocator.free(a);
            allocator.free(b);
            allocator.free(c);
            allocator.free(d);
            try expectClean(&allocator);
        }

        fn mergeTrivial() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);

            const a = try allocator.allocate(1337);
            try testing.expectEqual(@as(u32, 0), a.offset);
            allocator.free(a);
            const b = try allocator.allocate(1337);
            try testing.expectEqual(@as(u32, 0), b.offset);
            allocator.free(b);
            try expectClean(&allocator);
        }

        fn reuseTrivial() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);

            // C reuses A's node: same bin (a power of two to be sure).
            const a = try allocator.allocate(1024);
            try testing.expectEqual(@as(u32, 0), a.offset);
            const b = try allocator.allocate(3456);
            try testing.expectEqual(@as(u32, 1024), b.offset);
            allocator.free(a);
            const c = try allocator.allocate(1024);
            try testing.expectEqual(@as(u32, 0), c.offset);

            allocator.free(c);
            allocator.free(b);
            try expectClean(&allocator);
        }

        fn reuseComplex() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);

            // C does not fit A's freed bin; D and E do and reuse it.
            const a = try allocator.allocate(1024);
            try testing.expectEqual(@as(u32, 0), a.offset);
            const b = try allocator.allocate(3456);
            try testing.expectEqual(@as(u32, 1024), b.offset);
            allocator.free(a);
            const c = try allocator.allocate(2345);
            try testing.expectEqual(@as(u32, 1024 + 3456), c.offset);
            const d = try allocator.allocate(456);
            try testing.expectEqual(@as(u32, 0), d.offset);
            const e = try allocator.allocate(512);
            try testing.expectEqual(@as(u32, 456), e.offset);

            const report = allocator.storageReport();
            try testing.expectEqual(total - 3456 - 2345 - 456 - 512, report.total_free_space);
            try testing.expect(report.largest_free_region != report.total_free_space);

            allocator.free(c);
            allocator.free(d);
            allocator.free(b);
            allocator.free(e);
            try expectClean(&allocator);
        }

        fn zeroFragmentation() !void {
            var allocator = try Allocator.init(testing.allocator, total, maxAllocs());
            defer allocator.deinit(testing.allocator);

            // 256 x 1 MiB fill the space exactly.
            var allocations: [256]Allocator.Allocation = undefined;
            for (&allocations, 0..) |*a, i| {
                a.* = try allocator.allocate(1024 * 1024);
                try testing.expectEqual(@as(u32, @intCast(i * 1024 * 1024)), a.offset);
            }

            const report = allocator.storageReport();
            try testing.expectEqual(@as(u32, 0), report.total_free_space);
            try testing.expectEqual(@as(u32, 0), report.largest_free_region);

            // Four scattered slots, then four contiguous ones (which merge).
            for ([_]usize{ 243, 5, 123, 95, 151, 152, 153, 154 }) |i| allocator.free(allocations[i]);

            allocations[243] = try allocator.allocate(1024 * 1024);
            allocations[5] = try allocator.allocate(1024 * 1024);
            allocations[123] = try allocator.allocate(1024 * 1024);
            allocations[95] = try allocator.allocate(1024 * 1024);
            allocations[151] = try allocator.allocate(1024 * 1024 * 4); // 4x larger

            for (allocations, 0..) |a, i| {
                if (i < 152 or i > 154) allocator.free(a);
            }

            const report2 = allocator.storageReport();
            try testing.expectEqual(total, report2.total_free_space);
            try testing.expectEqual(total, report2.largest_free_region);
            try expectClean(&allocator);
        }

        /// The original's default, or as many as 16-bit indices address.
        fn maxAllocs() u32 {
            return @min(oa.default_max_allocs, Allocator.max_max_allocs);
        }
    };
}

test "basic" {
    try Suite(oa.Allocator).basic();
    try Suite(oa.Allocator16).basic();
}

test "allocate: simple" {
    try Suite(oa.Allocator).simple();
    try Suite(oa.Allocator16).simple();
}

test "allocate: merge trivial" {
    try Suite(oa.Allocator).mergeTrivial();
    try Suite(oa.Allocator16).mergeTrivial();
}

test "allocate: reuse trivial" {
    try Suite(oa.Allocator).reuseTrivial();
    try Suite(oa.Allocator16).reuseTrivial();
}

test "allocate: reuse complex" {
    try Suite(oa.Allocator).reuseComplex();
    try Suite(oa.Allocator16).reuseComplex();
}

test "allocate: zero fragmentation" {
    try Suite(oa.Allocator).zeroFragmentation();
    try Suite(oa.Allocator16).zeroFragmentation();
}
