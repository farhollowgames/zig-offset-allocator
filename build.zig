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

    // The core (src/offset_allocator.zig) and the Ranges layer
    // (src/ranges.zig), re-exported by src/root.zig.
    _ = b.addModule("offset_allocator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: the exhaustive SmallFloat sweep takes
    // minutes in Debug, and ReleaseSafe keeps every assert and overflow check
    // on.
    const test_optimize = b.option(std.lang.Optimize, "test-optimize", "Optimize mode for the tests (default ReleaseSafe)") orelse .safe;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
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

    // A stale free in Ranges panics in safe builds, which no test can catch
    // in-process in Zig 0.17: run a program that does it and expect the
    // abort and the message, for a double free and a free after reset.
    if (test_optimize == .debug or test_optimize == .safe) {
        const panic_exe = b.addExecutable(.{
            .name = "ranges_panic",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/ranges_panic.zig"),
                .target = target,
                .optimize = test_optimize,
                .imports = &.{.{ .name = "offset_allocator", .module = test_mod }},
            }),
        });
        for ([_][]const u8{ "double", "reset" }) |case| {
            const run = b.addRunArtifact(panic_exe);
            run.addArg(case);
            run.expectStdErrMatch("free of a handle that is not live (StaleGeneration)");
            if (target.result.os.tag != .windows) run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            test_step.dependOn(&run.step);
        }
    }

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

    // The benchmark: the core against the Ranges layer (bench/bench.zig).
    // ReleaseFast unless -Dbench-optimize says otherwise; -Dbench-cpu=N runs
    // it pinned to CPU N with taskset (Linux).
    const bench_optimize = b.option(std.lang.Optimize, "bench-optimize", "Optimize mode for the benchmark (default ReleaseFast)") orelse .fast;
    const bench_cpu = b.option([]const u8, "bench-cpu", "Pin the benchmark to this CPU with taskset");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "offset_allocator", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = bench_optimize,
            }) }},
        }),
    });
    const bench_run = if (bench_cpu) |cpu| blk: {
        const run = b.addSystemCommand(&.{ "taskset", "-c", cpu });
        run.addArtifactArg(bench_exe);
        break :blk run;
    } else b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmark: core against Ranges");
    bench_step.dependOn(&bench_run.step);
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
