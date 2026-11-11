//! A program that breaks one contract of the allocators, which must abort
//! in safe builds. Zig 0.17 cannot catch a panic inside a test, so
//! `zig build test` runs this once per case and expects the abort and its
//! message (build.zig lists them). The argument names the case:
//!
//! - the port's core: `free_twice`, `free_none` (`Allocation.none`),
//!   `free_foreign` (a node index past the nodes), `init_one_node`, and
//!   `init_16_too_many` (65537 nodes with 16-bit indices);
//! - the original, built with its asserts: `original_free_twice`,
//!   `original_free_none` and `original_init_16_too_many`, the cases its
//!   own asserts catch;
//! - `Ranges`: `ranges_free_twice`, `ranges_free_after_reset`.

const std = @import("std");
const oa = @import("offset_allocator");

const Case = enum {
    free_twice,
    free_none,
    free_foreign,
    init_one_node,
    init_16_too_many,
    original_free_twice,
    original_free_none,
    original_init_16_too_many,
    ranges_free_twice,
    ranges_free_after_reset,
};

/// An allocator of the original, behind the shim's C ABI.
const Cxx = opaque {};
extern fn oa32_create(size: u32, max_allocs: u32) ?*Cxx;
extern fn oa16_create(size: u32, max_allocs: u32) ?*Cxx;
extern fn oa32_allocate(allocator: *Cxx, size: u32, offset: *u32, metadata: *u32) void;
extern fn oa32_free(allocator: *Cxx, offset: u32, metadata: u32) void;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArgument;
    const case = std.meta.stringToEnum(Case, args[1]) orelse return error.InvalidArgument;
    const gpa = init.gpa;

    switch (case) {
        .free_twice => {
            var allocator = try oa.Allocator.init(gpa, 1000, 16);
            const a = try allocator.allocate(10);
            allocator.free(a);
            allocator.free(a);
        },
        .free_none => {
            var allocator = try oa.Allocator.init(gpa, 1000, 16);
            allocator.free(.none);
        },
        .free_foreign => {
            var allocator = try oa.Allocator.init(gpa, 1000, 16);
            allocator.free(.{ .offset = 0, .metadata = 16 });
        },
        .init_one_node => _ = try oa.Allocator.init(gpa, 1000, 1),
        .init_16_too_many => _ = try oa.Allocator16.init(gpa, 1000, 65537),
        .original_free_twice => {
            const allocator = oa32_create(1000, 16) orelse return error.OutOfMemory;
            var offset: u32 = undefined;
            var metadata: u32 = undefined;
            oa32_allocate(allocator, 10, &offset, &metadata);
            oa32_free(allocator, offset, metadata);
            oa32_free(allocator, offset, metadata);
        },
        .original_free_none => {
            const allocator = oa32_create(1000, 16) orelse return error.OutOfMemory;
            oa32_free(allocator, oa.no_space, oa.no_space);
        },
        .original_init_16_too_many => _ = oa16_create(1000, 65537),
        .ranges_free_twice, .ranges_free_after_reset => {
            var ranges = try oa.Ranges.init(gpa, 1 << 20, 64, 256);
            const a = try ranges.allocate(1000);
            if (case == .ranges_free_twice) ranges.free(a) else ranges.reset();
            ranges.free(a);
        },
    }
    // Every case aborts before this.
    return error.NoAbort;
}
