const std = @import("std");
const builtin = @import("builtin");

// Every build uses the compiler `.zigversion` names.
comptime {
    const wanted = std.mem.trim(u8, @embedFile(".zigversion"), " \r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, wanted)) {
        @compileError("zig-offset-allocator builds with Zig " ++ wanted ++ " (see .zigversion), not " ++ builtin.zig_version_string);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("offset_allocator", .{
        .root_source_file = b.path("src/offset_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: the exhaustive SmallFloat sweep takes
    // minutes in Debug, and ReleaseSafe keeps every assert and overflow check
    // on.
    const test_optimize = b.option(std.lang.Optimize, "test-optimize", "Optimize mode for the tests (default ReleaseSafe)") orelse .safe;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/offset_allocator.zig"),
        .target = target,
        .optimize = test_optimize,
    });

    const test_step = b.step("test", "Run unit, property and differential tests");

    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/unit.zig"),
            .target = target,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "offset_allocator", .module = test_mod }},
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The original C++, built only for the differential tests: once as
    // shipped and once with 16-bit node indices, each through the shim (see
    // reference/README.md). DEBUG turns on the original's asserts.
    const reference = b.addLibrary(.{
        .name = "offset_allocator_reference",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            // The original uses new and delete; the port links neither.
            .link_libcpp = true,
        }),
    });
    reference.root_module.addCSourceFile(.{ .file = b.path("reference/shim/offset_allocator_shim.cpp"), .flags = &cpp_flags });
    reference.root_module.addCSourceFile(.{ .file = b.path("reference/shim/offset_allocator_shim.cpp"), .flags = &(cpp_flags ++ cpp_flags_16) });

    const differential = b.addTest(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "offset_allocator", .module = test_mod }},
        }),
        .filters = test_filters,
    });
    differential.root_module.linkLibrary(reference);
    test_step.dependOn(&b.addRunArtifact(differential).step);
}

const cpp_flags = [_][]const u8{ "-std=c++20", "-DDEBUG", "-fno-exceptions", "-fno-rtti" };

// The 16-bit build renames the namespace and the shim's symbols so both
// builds link into one binary. The original narrows uint32 into the 16-bit
// NodeIndex in braced initializers, which clang rejects unless told not to.
const cpp_flags_16 = [_][]const u8{
    "-DUSE_16_BIT_NODE_INDICES",
    "-DOffsetAllocator=OffsetAllocator16",
    "-DOA_PREFIX=oa16_",
    "-Wno-c++11-narrowing",
    "-Wno-constant-conversion",
    "-Wno-tautological-constant-out-of-range-compare",
};
