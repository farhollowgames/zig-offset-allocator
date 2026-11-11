//! Benchmark: the port against the original C++, and the `Ranges` layer
//! against the port, for both node index widths, on a GPU sub-allocation
//! workload. Prints a Markdown table of ns per call: the median of several
//! runs, with the interquartile range.
//!
//! Every side gets the same requests: the original and the port the sizes in
//! 256-byte units, the layer the same sizes in bytes. A request sequence takes
//! every side through the same allocator states, and the benchmark stops if
//! the sides' results differ, so each side does the same work.
//!
//! - The original is built at -O3 for the same CPU as the port (build.zig),
//!   and its batches run in C++ (bench/original.cpp): each side pays one call
//!   per batch, and each compiler sees its allocator whole. Neither inlines
//!   allocate or free into the loop, and both keep frame pointers.
//! - The port's loops handle `error.NoSpace` from every allocate, as a
//!   caller must; the original's loops store the result unchecked.
//! - Node arrays come from the C allocator on every side, as the original's
//!   `new` takes them from malloc.
//! - Every side runs once to warm up, then the runs rotate the order of the
//!   sides, so that a slow moment on a busy machine falls on all of them.
//! - Results stay alive: handles are stored and read back for the check, and
//!   the repeated calls (reset, the full report) clobber memory after each.
//!
//! `zig build bench -- <runs> <workload>` sets the number of runs (default
//! 11) and runs one workload alone (`steady`, `fill_free`, `churn`, `reset`
//! or `report_full`), as when profiling one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const oa = @import("offset_allocator");
const options = @import("bench_options");

const unit = 256;
/// 16 GiB, 2^26 units.
const space_bytes: u64 = 16 << 30;
const space_units: u32 = @intCast(space_bytes / unit);
const max_allocs = 32768;
const runs_default = 11;

const steady_live = 10_000;
const steady_batch = 1000;
const steady_rounds = 200;
const fill_count = 10_000;
const fill_rounds = 20;
const churn_resident = 2000;
const churn_per_frame = 256;
const churn_frames = 400;
const churn_bytes: u64 = 64 << 10;
const reset_count = 50;
const report_count = 200;
const handles_max = @max(steady_live, fill_count, churn_resident + churn_per_frame);

/// A GPU-like size mix: mostly small uniform and vertex chunks, some
/// medium buffers, a few large textures.
fn mixedSize(random: std.Random) u64 {
    return switch (random.uintLessThan(u32, 100)) {
        0...69 => random.intRangeAtMost(u64, 64, 16 << 10),
        70...94 => random.intRangeAtMost(u64, 16 << 10, 1 << 20),
        else => random.intRangeAtMost(u64, 1 << 20, 16 << 20),
    };
}

fn units(bytes: u64) u32 {
    return @intCast(std.math.divCeil(u64, bytes, unit) catch unreachable);
}

/// The requests of every run, made once and given to every side.
const Script = struct {
    /// Sizes in bytes, for the layer.
    bytes: []const u64,
    /// The same sizes rounded up to units, for the original and the port.
    units: []const u32,
    /// Handles to free and allocate again: for the steady state, batches of
    /// distinct slots; the first `fill_count` are a permutation.
    slots: []const u32,
    /// The even slots below `fill_count`.
    evens: []const u32,
};

/// A side's results folded into one number: its handles' offsets in units
/// and node indices, or a report's region counts.
const Digest = u64;

fn fold(digest: Digest, a: u64, b: u64) Digest {
    return (digest ^ a ^ (b << 32)) *% 0x9e37_79b9_7f4a_7c15;
}

/// The original, through the C functions of bench/original.cpp.
fn Original(comptime prefix: []const u8, comptime NodeIndex: type) type {
    return struct {
        allocator: *Cxx,

        const Self = @This();

        /// The original's `OffsetAllocator::Allocator`.
        const Cxx = opaque {};
        /// The original's `Allocation`.
        const Handle = extern struct { offset: u32, metadata: NodeIndex };
        /// The original's `StorageReportFull`.
        const Report = extern struct {
            free_regions: [oa.num_leaf_bins]extern struct { size: u32, count: u32 },
        };

        fn function(comptime symbol: []const u8, comptime T: type) *const T {
            return @extern(*const T, .{ .name = prefix ++ symbol });
        }

        const create = function("create", fn (u32, u32) callconv(.c) ?*Cxx);
        const destroy = function("destroy", fn (*Cxx) callconv(.c) void);
        const allocate_each = function(
            "allocate_each",
            fn (*Cxx, [*]const u32, u32, [*]Handle) callconv(.c) void,
        );
        const allocate_into = function(
            "allocate_into",
            fn (*Cxx, [*]const u32, [*]const u32, u32, [*]Handle) callconv(.c) void,
        );
        const allocate_same = function(
            "allocate_same",
            fn (*Cxx, u32, u32, [*]Handle) callconv(.c) void,
        );
        const free_each = function(
            "free_each",
            fn (*Cxx, [*]const Handle, u32) callconv(.c) void,
        );
        const free_from = function(
            "free_from",
            fn (*Cxx, [*]const Handle, [*]const u32, u32) callconv(.c) void,
        );
        const reset_times = function("reset_times", fn (*Cxx, u32) callconv(.c) void);
        const report_full_times = function(
            "report_full_times",
            fn (*Cxx, u32, *Report) callconv(.c) void,
        );

        fn init(gpa: std.mem.Allocator) !Self {
            _ = gpa;
            const allocator = create(space_units, max_allocs) orelse return error.OutOfMemory;
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            _ = gpa;
            destroy(self.allocator);
        }

        fn sizes(script: Script) []const u32 {
            return script.units;
        }

        fn allocateEach(self: *Self, request: []const u32, handles: []Handle) !void {
            const count: u32 = @intCast(request.len);
            allocate_each(self.allocator, request.ptr, count, handles.ptr);
        }

        fn allocateInto(
            self: *Self,
            request: []const u32,
            slots: []const u32,
            handles: []Handle,
        ) !void {
            const count: u32 = @intCast(slots.len);
            allocate_into(self.allocator, request.ptr, slots.ptr, count, handles.ptr);
        }

        fn allocateSame(self: *Self, size_bytes: u64, handles: []Handle) !void {
            const count: u32 = @intCast(handles.len);
            allocate_same(self.allocator, units(size_bytes), count, handles.ptr);
        }

        fn freeEach(self: *Self, handles: []const Handle) void {
            free_each(self.allocator, handles.ptr, @intCast(handles.len));
        }

        fn freeFrom(self: *Self, handles: []const Handle, slots: []const u32) void {
            free_from(self.allocator, handles.ptr, slots.ptr, @intCast(slots.len));
        }

        fn resetTimes(self: *Self, count: u32) void {
            reset_times(self.allocator, count);
        }

        fn reportFullTimes(self: *Self, count: u32) Digest {
            var report: Report = undefined;
            report_full_times(self.allocator, count, &report);
            var digest: Digest = 0;
            for (report.free_regions) |region| digest = fold(digest, region.count, 0);
            return digest;
        }

        fn digestOf(handles: []const Handle) Digest {
            var digest: Digest = 0;
            for (handles) |handle| {
                if (handle.offset == oa.no_space) @panic("benchmark: out of space");
                digest = fold(digest, handle.offset, handle.metadata);
            }
            return digest;
        }
    };
}

/// The port: the core allocator, `Allocator` or `Allocator16`.
fn Port(comptime Core: type) type {
    return struct {
        core: Core,

        const Self = @This();
        const Handle = Core.Allocation;

        fn init(gpa: std.mem.Allocator) !Self {
            return .{ .core = try Core.init(gpa, space_units, max_allocs) };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.core.deinit(gpa);
        }

        fn sizes(script: Script) []const u32 {
            return script.units;
        }

        noinline fn allocateEach(self: *Self, request: []const u32, handles: []Handle) !void {
            for (request, handles) |size, *handle| handle.* = try self.core.allocate(size);
        }

        noinline fn allocateInto(
            self: *Self,
            request: []const u32,
            slots: []const u32,
            handles: []Handle,
        ) !void {
            for (request, slots) |size, slot| handles[slot] = try self.core.allocate(size);
        }

        noinline fn allocateSame(self: *Self, size_bytes: u64, handles: []Handle) !void {
            const size = units(size_bytes);
            for (handles) |*handle| handle.* = try self.core.allocate(size);
        }

        noinline fn freeEach(self: *Self, handles: []const Handle) void {
            for (handles) |handle| self.core.free(handle);
        }

        noinline fn freeFrom(self: *Self, handles: []const Handle, slots: []const u32) void {
            for (slots) |slot| self.core.free(handles[slot]);
        }

        noinline fn resetTimes(self: *Self, count: u32) void {
            for (0..count) |_| {
                self.core.reset();
                std.mem.doNotOptimizeAway(&self.core);
            }
        }

        noinline fn reportFullTimes(self: *Self, count: u32) Digest {
            var report: oa.StorageReportFull = undefined;
            for (0..count) |_| {
                report = self.core.storageReportFull();
                std.mem.doNotOptimizeAway(&report);
            }
            var digest: Digest = 0;
            for (report.free_regions) |region| digest = fold(digest, region.count, 0);
            return digest;
        }

        fn digestOf(handles: []const Handle) Digest {
            var digest: Digest = 0;
            for (handles) |handle| digest = fold(digest, handle.offset, handle.metadata);
            return digest;
        }
    };
}

/// The `Ranges` layer over the port, in bytes with a 256-byte unit.
fn Layer(comptime Core: type) type {
    return struct {
        ranges: Ranges,

        const Self = @This();
        const Ranges = oa.RangesOf(Core);
        const Handle = Ranges.Handle;

        fn init(gpa: std.mem.Allocator) !Self {
            return .{ .ranges = try Ranges.init(gpa, space_bytes, max_allocs, unit) };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.ranges.deinit(gpa);
        }

        fn sizes(script: Script) []const u64 {
            return script.bytes;
        }

        noinline fn allocateEach(self: *Self, request: []const u64, handles: []Handle) !void {
            for (request, handles) |size, *handle| handle.* = try self.ranges.allocate(size);
        }

        noinline fn allocateInto(
            self: *Self,
            request: []const u64,
            slots: []const u32,
            handles: []Handle,
        ) !void {
            for (request, slots) |size, slot| handles[slot] = try self.ranges.allocate(size);
        }

        noinline fn allocateSame(self: *Self, size_bytes: u64, handles: []Handle) !void {
            for (handles) |*handle| handle.* = try self.ranges.allocate(size_bytes);
        }

        noinline fn freeEach(self: *Self, handles: []const Handle) void {
            for (handles) |handle| self.ranges.free(handle);
        }

        noinline fn freeFrom(self: *Self, handles: []const Handle, slots: []const u32) void {
            for (slots) |slot| self.ranges.free(handles[slot]);
        }

        noinline fn resetTimes(self: *Self, count: u32) void {
            for (0..count) |_| {
                self.ranges.reset();
                std.mem.doNotOptimizeAway(&self.ranges);
            }
        }

        noinline fn reportFullTimes(self: *Self, count: u32) Digest {
            var report: Ranges.StorageReportFull = undefined;
            for (0..count) |_| {
                report = self.ranges.storageReportFull();
                std.mem.doNotOptimizeAway(&report);
            }
            var digest: Digest = 0;
            for (report.free_regions) |region| digest = fold(digest, region.count, 0);
            return digest;
        }

        fn digestOf(handles: []const Handle) Digest {
            var digest: Digest = 0;
            for (handles) |handle| digest = fold(digest, handle.offset / unit, handle.node);
            return digest;
        }
    };
}

const Workload = enum {
    steady,
    fill_free,
    churn,
    reset,
    report_full,

    fn label(workload: Workload) []const u8 {
        return switch (workload) {
            .steady => "steady state, 10k live",
            .fill_free => "fill 10k, free all",
            .churn => "churn, 256 x 64 KiB per frame",
            .reset => "reset",
            .report_full => "storageReportFull, 5001 free regions",
        };
    }

    /// The calls a run times, one or two.
    fn ops(workload: Workload) []const []const u8 {
        return switch (workload) {
            .steady, .fill_free, .churn => &.{ "allocate", "free" },
            .reset => &.{"reset"},
            .report_full => &.{"report"},
        };
    }
};

const workloads = [_]Workload{ .steady, .fill_free, .churn, .reset, .report_full };

/// One run of a workload on one side: ns per call of each op it times, and
/// the digest of its results.
const Run = struct { ns: [2]f64, digest: Digest };

fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

fn nsBetween(from: Io.Timestamp, to: Io.Timestamp) f64 {
    return @floatFromInt(from.durationTo(to).toNanoseconds());
}

fn runOnce(
    comptime S: type,
    workload: Workload,
    gpa: std.mem.Allocator,
    io: Io,
    script: Script,
) !Run {
    var side = try S.init(gpa);
    defer side.deinit(gpa);
    const request = S.sizes(script);
    const handles = try gpa.alloc(S.Handle, handles_max);
    defer gpa.free(handles);

    var ns: [2]f64 = .{ 0, 0 };
    var calls: f64 = 0;
    var digest: Digest = 0;
    switch (workload) {
        // `steady_live` allocations, then rounds of freeing a batch at
        // random and allocating as many new ones.
        .steady => {
            const live = handles[0..steady_live];
            try side.allocateEach(request[0..steady_live], live);
            for (0..steady_rounds) |round| {
                const slots = script.slots[round * steady_batch ..][0..steady_batch];
                const first = steady_live + round * steady_batch;
                const t0 = now(io);
                side.freeFrom(live, slots);
                const t1 = now(io);
                try side.allocateInto(request[first..][0..steady_batch], slots, live);
                const t2 = now(io);
                ns[0] += nsBetween(t1, t2);
                ns[1] += nsBetween(t0, t1);
                calls += steady_batch;
            }
            digest = S.digestOf(live);
        },
        // `fill_count` allocations, then all freed in random order.
        .fill_free => {
            const all = handles[0..fill_count];
            for (0..fill_rounds) |_| {
                const t0 = now(io);
                try side.allocateEach(request[0..fill_count], all);
                const t1 = now(io);
                digest = fold(digest, S.digestOf(all), 0);
                const t2 = now(io);
                side.freeFrom(all, script.slots[0..fill_count]);
                const t3 = now(io);
                ns[0] += nsBetween(t0, t1);
                ns[1] += nsBetween(t2, t3);
                calls += fill_count;
            }
        },
        // `churn_resident` allocations stay; every frame allocates
        // `churn_per_frame` buffers of one size and frees them in order.
        .churn => {
            try side.allocateEach(request[0..churn_resident], handles[0..churn_resident]);
            const frame = handles[churn_resident..][0..churn_per_frame];
            for (0..churn_frames) |_| {
                const t0 = now(io);
                try side.allocateSame(churn_bytes, frame);
                const t1 = now(io);
                side.freeEach(frame);
                const t2 = now(io);
                ns[0] += nsBetween(t0, t1);
                ns[1] += nsBetween(t1, t2);
                calls += churn_per_frame;
            }
            digest = S.digestOf(handles[0 .. churn_resident + churn_per_frame]);
        },
        // Resets of an allocator holding `steady_live` allocations, then of
        // the empty one: neither side's reset depends on the state.
        .reset => {
            try side.allocateEach(request[0..steady_live], handles[0..steady_live]);
            digest = S.digestOf(handles[0..steady_live]);
            const t0 = now(io);
            side.resetTimes(reset_count);
            const t1 = now(io);
            ns[0] = nsBetween(t0, t1);
            calls = reset_count;
        },
        // `fill_count` allocations with every other one freed: 5000 free
        // regions between them, and the rest of the space.
        .report_full => {
            const all = handles[0..fill_count];
            try side.allocateEach(request[0..fill_count], all);
            side.freeFrom(all, script.evens);
            const t0 = now(io);
            digest = side.reportFullTimes(report_count);
            const t1 = now(io);
            ns[0] = nsBetween(t0, t1);
            calls = report_count;
        },
    }
    return .{ .ns = .{ ns[0] / calls, ns[1] / calls }, .digest = digest };
}

fn makeScript(gpa: std.mem.Allocator) !Script {
    var prng: std.Random.DefaultPrng = .init(0x0ff5e7);
    const random = prng.random();
    const count = steady_live + steady_rounds * steady_batch;
    const bytes = try gpa.alloc(u64, count);
    const size_units = try gpa.alloc(u32, count);
    for (bytes, size_units) |*b, *u| {
        b.* = mixedSize(random);
        u.* = units(b.*);
    }
    // Each run of `steady_live` slots is a permutation, so the slots within
    // a batch are distinct: no handle is freed twice before it is replaced.
    const slots = try gpa.alloc(u32, steady_rounds * steady_batch);
    var permutation: [steady_live]u32 = undefined;
    for (&permutation, 0..) |*p, i| p.* = @intCast(i);
    var i: usize = 0;
    while (i < slots.len) : (i += steady_live) {
        random.shuffle(u32, &permutation);
        @memcpy(slots[i..][0..steady_live], &permutation);
    }
    const evens = try gpa.alloc(u32, fill_count / 2);
    for (evens, 0..) |*e, k| e.* = @intCast(2 * k);
    return .{ .bytes = bytes, .units = size_units, .slots = slots, .evens = evens };
}

/// ns per call over the runs, for each side (original, port, layer) and
/// each op the workload times.
const Samples = [3][2][]f64;

fn Width(comptime label: []const u8, comptime Core: type, comptime prefix: []const u8) type {
    return struct {
        const name = label;
        const NodeIndex = @FieldType(Core.Allocation, "metadata");
        const sides = .{ Original(prefix, NodeIndex), Port(Core), Layer(Core) };

        fn measure(
            workload: Workload,
            gpa: std.mem.Allocator,
            arena: std.mem.Allocator,
            io: Io,
            script: Script,
            runs: usize,
        ) !Samples {
            var samples: Samples = undefined;
            for (&samples) |*side| {
                for (side) |*op| op.* = try arena.alloc(f64, runs);
            }
            // Round 0 warms every side up and is not kept.
            for (0..runs + 1) |round| {
                var digests: [3]Digest = undefined;
                for (0..3) |k| {
                    const side_index = (round + k) % 3;
                    const result = switch (side_index) {
                        inline 0, 1, 2 => |s| try runOnce(sides[s], workload, gpa, io, script),
                        else => unreachable,
                    };
                    digests[side_index] = result.digest;
                    if (round == 0) continue;
                    for (&samples[side_index], result.ns) |op, value| op[round - 1] = value;
                }
                if (digests[0] != digests[1] or digests[1] != digests[2]) {
                    std.debug.panic("benchmark: the sides' results differ: {s}, {s}", .{
                        workload.label(),
                        name,
                    });
                }
            }
            return samples;
        }
    };
}

const Summary = struct { median: f64, low: f64, high: f64 };

/// The median and the interquartile range.
fn summarize(values: []f64) Summary {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    return .{ .median = values[n / 2], .low = values[n / 4], .high = values[(3 * n) / 4] };
}

fn printTime(out: *Io.Writer, s: Summary) !void {
    if (s.median >= 1000) {
        try out.print("{d:.0} ({d:.0}–{d:.0})", .{ s.median, s.low, s.high });
    } else {
        try out.print("{d:.1} ({d:.1}–{d:.1})", .{ s.median, s.low, s.high });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    // The original's `new` takes its node arrays from malloc; so does every
    // side here.
    const gpa = std.heap.c_allocator;

    const args = try init.minimal.args.toSlice(arena);
    const runs = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else runs_default;
    if (runs < 1) return error.InvalidArgument;
    const only: ?Workload = if (args.len > 2)
        std.meta.stringToEnum(Workload, args[2]) orelse return error.InvalidArgument
    else
        null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const mode = switch (builtin.mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
    try out.print(
        \\zig-offset-allocator bench: the port in {s}, the original with {s}
        \\{d} runs, ns per call: median (interquartile range); unit {d} B, {d} nodes
        \\
        \\
    , .{ mode, options.original_flags, runs, unit, max_allocs });
    try out.writeAll("| workload | op | node index | original | port | port / original | " ++
        "Ranges | Ranges / port |\n" ++
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |\n");
    try out.flush();

    const script = try makeScript(arena);
    for (workloads) |workload| {
        if (only != null and only != workload) continue;
        inline for (.{
            Width("u32", oa.Allocator, "oa32_"),
            Width("u16", oa.Allocator16, "oa16_"),
        }) |W| {
            const samples = try W.measure(workload, gpa, arena, io, script, runs);
            for (workload.ops(), 0..) |op, o| {
                const original = summarize(samples[0][o]);
                const port = summarize(samples[1][o]);
                const layer = summarize(samples[2][o]);
                try out.print("| {s} | {s} | {s} | ", .{ workload.label(), op, W.name });
                try printTime(out, original);
                try out.writeAll(" | ");
                try printTime(out, port);
                try out.print(" | {d:.2} | ", .{port.median / original.median});
                try printTime(out, layer);
                try out.print(" | {d:.2} |\n", .{layer.median / port.median});
                try out.flush();
            }
        }
    }
}
