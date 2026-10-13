//! Benchmark: the core allocator against the `Ranges` layer over it, both
//! node index widths, on GPU sub-allocation workloads. Prints a Markdown
//! table of ns per allocate and ns per free (the median of several runs)
//! and the layer's overhead.
//!
//! Both sides get the same requests: the layer the sizes in bytes with a
//! 256-byte unit, the core the same sizes already rounded up to units. The
//! core's state goes through the same steps on both sides, so the difference
//! is the layer's own work: rounding, shifting, the generation load and
//! store, and the handle check in safe builds.
//!
//! Each timed batch is hundreds of calls or more, so the clock's cost (tens
//! of ns) is spread thin.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const oa = @import("offset_allocator");

const unit = 256;
/// 16 GiB, 2^26 units.
const space_bytes: u64 = 16 << 30;
const max_allocs = 32768;
const runs = 11;

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

const Timing = struct { alloc_ns: f64, free_ns: f64 };

/// A workload's requests, made once and replayed on every side.
const Script = struct {
    /// Sizes in bytes, and the same in units for the core.
    sizes: []const u64,
    size_units: []const u32,
    /// Slots to free, for workloads that free at random.
    slots: []const u32,
};

/// One side of the comparison: the core or the layer, over `Core`.
fn Side(comptime Core: type, comptime layered: bool) type {
    return struct {
        const Impl = if (layered) oa.RangesOf(Core) else Core;
        const Handle = if (layered) Impl.Handle else Core.Allocation;

        fn init(gpa: std.mem.Allocator) !Impl {
            return if (layered)
                Impl.init(gpa, space_bytes, max_allocs, unit)
            else
                Impl.init(gpa, @intCast(space_bytes / unit), max_allocs);
        }

        inline fn allocate(impl: *Impl, script: Script, i: usize) Handle {
            const result = if (layered) impl.allocate(script.sizes[i]) else impl.allocate(script.size_units[i]);
            return result catch @panic("benchmark: out of space");
        }
    };
}

fn timer(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

fn ns(from: Io.Timestamp, to: Io.Timestamp) f64 {
    return @floatFromInt(from.durationTo(to).toNanoseconds());
}

/// (a) Steady state: `live` allocations, then rounds of freeing `batch` at
/// random and allocating `batch` new ones.
fn steady(comptime S: type, gpa: std.mem.Allocator, io: Io, script: Script, live: usize, batch: usize) !Timing {
    var impl = try S.init(gpa);
    defer impl.deinit(gpa);
    const handles = try gpa.alloc(S.Handle, live);
    defer gpa.free(handles);

    var next: usize = 0;
    for (handles) |*h| {
        h.* = S.allocate(&impl, script, next);
        next += 1;
    }

    var alloc_ns: f64 = 0;
    var free_ns: f64 = 0;
    var calls: f64 = 0;
    var slot: usize = 0;
    while (next + batch <= script.sizes.len) {
        const slots = script.slots[slot..][0..batch];
        slot += batch;

        const t0 = timer(io);
        for (slots) |s| impl.free(handles[s]);
        const t1 = timer(io);
        for (slots) |s| {
            handles[s] = S.allocate(&impl, script, next);
            next += 1;
        }
        const t2 = timer(io);

        free_ns += ns(t0, t1);
        alloc_ns += ns(t1, t2);
        calls += @floatFromInt(batch);
    }
    std.mem.doNotOptimizeAway(handles);
    return .{ .alloc_ns = alloc_ns / calls, .free_ns = free_ns / calls };
}

/// (b) Fill then free all: allocate `count`, then free them all in random
/// order, `rounds` times over.
fn fillFree(comptime S: type, gpa: std.mem.Allocator, io: Io, script: Script, count: usize, rounds: usize) !Timing {
    var impl = try S.init(gpa);
    defer impl.deinit(gpa);
    const handles = try gpa.alloc(S.Handle, count);
    defer gpa.free(handles);

    var alloc_ns: f64 = 0;
    var free_ns: f64 = 0;
    for (0..rounds) |_| {
        const t0 = timer(io);
        for (handles, 0..) |*h, i| h.* = S.allocate(&impl, script, i);
        const t1 = timer(io);
        // `slots` is a permutation of 0..count.
        for (script.slots[0..count]) |s| impl.free(handles[s]);
        const t2 = timer(io);
        alloc_ns += ns(t0, t1);
        free_ns += ns(t1, t2);
    }

    const calls: f64 = @floatFromInt(count * rounds);
    return .{ .alloc_ns = alloc_ns / calls, .free_ns = free_ns / calls };
}

/// (c) Per-frame churn: `resident` mixed allocations stay, and every frame
/// allocates `per_frame` same-size transient buffers and frees them in
/// order.
fn churn(comptime S: type, gpa: std.mem.Allocator, io: Io, script: Script, resident: usize, per_frame: usize, frames: usize, transient_bytes: u64) !Timing {
    var impl = try S.init(gpa);
    defer impl.deinit(gpa);
    const handles = try gpa.alloc(S.Handle, resident + per_frame);
    defer gpa.free(handles);

    for (handles[0..resident], 0..) |*h, i| h.* = S.allocate(&impl, script, i);
    const transient: Script = .{ .sizes = &.{transient_bytes}, .size_units = &.{units(transient_bytes)}, .slots = &.{} };
    const frame = handles[resident..];

    var alloc_ns: f64 = 0;
    var free_ns: f64 = 0;
    for (0..frames) |_| {
        const t0 = timer(io);
        for (frame) |*h| h.* = S.allocate(&impl, transient, 0);
        const t1 = timer(io);
        for (frame) |h| impl.free(h);
        const t2 = timer(io);
        alloc_ns += ns(t0, t1);
        free_ns += ns(t1, t2);
    }
    std.mem.doNotOptimizeAway(handles);
    const calls: f64 = @floatFromInt(frames * per_frame);
    return .{ .alloc_ns = alloc_ns / calls, .free_ns = free_ns / calls };
}

const Workload = enum { steady, fill_free, churn };

fn measure(comptime S: type, workload: Workload, gpa: std.mem.Allocator, io: Io, script: Script) !Timing {
    return switch (workload) {
        .steady => steady(S, gpa, io, script, 10_000, 1000),
        .fill_free => fillFree(S, gpa, io, script, 10_000, 20),
        .churn => churn(S, gpa, io, script, 2000, 256, 400, 64 << 10),
    };
}

fn median(values: *[runs]f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[runs / 2];
}

/// The median of `runs` runs, after one to warm up.
fn medianTiming(comptime S: type, workload: Workload, gpa: std.mem.Allocator, io: Io, script: Script) !Timing {
    _ = try measure(S, workload, gpa, io, script);
    var allocs: [runs]f64 = undefined;
    var frees: [runs]f64 = undefined;
    for (&allocs, &frees) |*a, *f| {
        const t = try measure(S, workload, gpa, io, script);
        a.* = t.alloc_ns;
        f.* = t.free_ns;
    }
    return .{ .alloc_ns = median(&allocs), .free_ns = median(&frees) };
}

fn makeScript(gpa: std.mem.Allocator, workload: Workload) !Script {
    var prng: std.Random.DefaultPrng = .init(0x0ff5e7);
    const random = prng.random();
    const count: usize = switch (workload) {
        .steady => 10_000 + 200 * 1000,
        .fill_free, .churn => 10_000,
    };
    const sizes = try gpa.alloc(u64, count);
    const size_units = try gpa.alloc(u32, count);
    for (sizes, size_units) |*s, *u| {
        s.* = mixedSize(random);
        u.* = units(s.*);
    }
    const slots = try gpa.alloc(u32, if (workload == .steady) count - 10_000 else 10_000);
    switch (workload) {
        // Distinct slots within each batch of 1000, so no handle is freed
        // twice before it is replaced.
        .steady => {
            var perm: [10_000]u32 = undefined;
            for (&perm, 0..) |*p, i| p.* = @intCast(i);
            var i: usize = 0;
            while (i < slots.len) : (i += 1000) {
                random.shuffle(u32, &perm);
                @memcpy(slots[i..][0..1000], perm[0..1000]);
            }
        },
        .fill_free, .churn => {
            for (slots, 0..) |*s, i| s.* = @intCast(i);
            random.shuffle(u32, slots);
        },
    }
    return .{ .sizes = sizes, .size_units = size_units, .slots = slots };
}

fn overhead(core: f64, layer: f64) f64 {
    return (layer - core) / core * 100;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("zig-offset-allocator bench, {s}, {d} runs (median), unit {d} B, {d} nodes\n\n", .{ switch (builtin.mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    }, runs, unit, max_allocs });
    try out.writeAll(
        \\| workload | op | core u32 | Ranges u32 | overhead | core u16 | Ranges16 | overhead |
        \\| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
        \\
    );
    try out.flush();

    const names = [_][]const u8{ "steady state, 10k live", "fill 10k, free all", "churn, 256 x 64 KiB per frame" };
    inline for (.{ Workload.steady, Workload.fill_free, Workload.churn }, names) |workload, name| {
        const script = try makeScript(arena, workload);
        const c32 = try medianTiming(Side(oa.Allocator, false), workload, gpa, io, script);
        const r32 = try medianTiming(Side(oa.Allocator, true), workload, gpa, io, script);
        const c16 = try medianTiming(Side(oa.Allocator16, false), workload, gpa, io, script);
        const r16 = try medianTiming(Side(oa.Allocator16, true), workload, gpa, io, script);
        try out.print("| {s} | allocate | {d:.1} | {d:.1} | {d:.0}% | {d:.1} | {d:.1} | {d:.0}% |\n", .{
            name,           c32.alloc_ns,                           r32.alloc_ns, overhead(c32.alloc_ns, r32.alloc_ns),
            c16.alloc_ns,   r16.alloc_ns,                           overhead(c16.alloc_ns, r16.alloc_ns),
        });
        try out.print("| | free | {d:.1} | {d:.1} | {d:.0}% | {d:.1} | {d:.1} | {d:.0}% |\n", .{
            c32.free_ns, r32.free_ns, overhead(c32.free_ns, r32.free_ns),
            c16.free_ns, r16.free_ns, overhead(c16.free_ns, r16.free_ns),
        });
        try out.flush();
    }
}
