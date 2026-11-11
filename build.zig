const std = @import("std");
const builtin = @import("builtin");

// Every build uses the compiler `.zigversion` names.
comptime {
    const wanted = std.mem.trim(u8, @embedFile(".zigversion"), " \r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, wanted)) {
        @compileError("zig-offset-allocator builds with Zig " ++ wanted ++
            " (see .zigversion), not " ++ builtin.zig_version_string);
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
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

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

    // The original C++, built only for the tests: once as shipped and once
    // with 16-bit node indices, each through the shim (see
    // reference/README.md). DEBUG turns on the original's asserts, and
    // -UNDEBUG keeps them, since Zig defines NDEBUG for C++ in release modes.
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
    const shim = b.path("reference/shim/offset_allocator_shim.cpp");
    reference.root_module.addCSourceFile(.{ .file = shim, .flags = &reference_flags });
    reference.root_module.addCSourceFile(.{
        .file = shim,
        .flags = &(reference_flags ++ flags_16),
    });

    // A broken contract aborts in safe builds, which no test can catch
    // in-process in Zig 0.17: run a program that breaks one per run and
    // expect the abort and the message (test/panic.zig).
    if (test_optimize == .debug or test_optimize == .safe) {
        const panic_exe = b.addExecutable(.{
            .name = "panic",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/panic.zig"),
                .target = target,
                .optimize = test_optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "offset_allocator", .module = test_mod }},
            }),
        });
        panic_exe.root_module.linkLibrary(reference);
        const unreachable_code = "reached unreachable code";
        const stale = "free of a handle that is not live (StaleGeneration)";
        const cases = [_]struct { []const u8, []const u8 }{
            .{ "free_twice", unreachable_code },
            .{ "free_none", unreachable_code },
            .{ "free_foreign", "index out of bounds: index 16, len 16" },
            .{ "init_one_node", unreachable_code },
            .{ "init_16_too_many", unreachable_code },
            .{ "original_free_twice", "Assertion `node.used == true' failed" },
            .{
                "original_free_none",
                "Assertion `allocation.metadata != Allocation::NO_SPACE' failed",
            },
            .{ "original_init_16_too_many", "Assertion `maxAllocs <= 65536' failed" },
            .{ "ranges_free_twice", stale },
            .{ "ranges_free_after_reset", stale },
        };
        for (cases) |case| {
            const run = b.addRunArtifact(panic_exe);
            run.setName(b.fmt("panic {s}", .{case[0]}));
            run.addArg(case[0]);
            run.expectStdErrMatch(case[1]);
            if (target.result.os.tag != .windows) {
                run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            }
            test_step.dependOn(&run.step);
        }
    }

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

    // The benchmark (bench/bench.zig): the port against the original, and
    // the Ranges layer against the port. The port in ReleaseFast unless
    // -Dbench-optimize says otherwise; the original always at -O3 without
    // its asserts, for the same target. -Dbench-cpu=N pins it to CPU N with
    // taskset (Linux). The binary is installed, for profiling.
    const bench_optimize = b.option(
        std.lang.Optimize,
        "bench-optimize",
        "Optimize mode of the port in the benchmark (default ReleaseFast)",
    ) orelse .fast;
    const bench_cpu = b.option([]const u8, "bench-cpu", "Pin the benchmark to this CPU");
    const original = b.addLibrary(.{
        .name = "offset_allocator_original",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    const original_source = b.path("bench/original.cpp");
    original.root_module.addCSourceFile(.{ .file = original_source, .flags = &original_flags });
    original.root_module.addCSourceFile(.{
        .file = original_source,
        .flags = &(original_flags ++ flags_16),
    });
    const bench_options = b.addOptions();
    bench_options.addOption(
        []const u8,
        "original_flags",
        std.mem.join(b.allocator, " ", &original_flags) catch @panic("out of memory"),
    );
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "offset_allocator", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = bench_optimize,
                }) },
                .{ .name = "bench_options", .module = bench_options.createModule() },
            },
        }),
    });
    bench_exe.root_module.linkLibrary(original);
    const bench_run = if (bench_cpu) |cpu| blk: {
        const run = b.addSystemCommand(&.{ "taskset", "-c", cpu });
        run.addArtifactArg(bench_exe);
        break :blk run;
    } else b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run the benchmark: the port against the original");
    bench_step.dependOn(&bench_run.step);
    bench_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
}

const reference_flags = [_][]const u8{
    "-std=c++20",
    "-DDEBUG",
    "-UNDEBUG",
    "-fno-exceptions",
    "-fno-rtti",
};

const original_flags = [_][]const u8{ "-std=c++20", "-O3", "-fno-exceptions", "-fno-rtti" };

// The 16-bit build renames the namespace and the C symbols so both builds
// link into one binary. The original narrows uint32 into the 16-bit
// NodeIndex in braced initializers, which clang rejects unless told not to.
const flags_16 = [_][]const u8{
    "-DUSE_16_BIT_NODE_INDICES",
    "-DOffsetAllocator=OffsetAllocator16",
    "-DOA_PREFIX=oa16_",
    "-Wno-c++11-narrowing",
    "-Wno-constant-conversion",
    "-Wno-tautological-constant-out-of-range-compare",
};
