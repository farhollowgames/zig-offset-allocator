# zig-offset-allocator

A fast, hard real-time O(1) offset allocator in pure Zig.

zig-offset-allocator hands out ranges of a contiguous space, such as a GPU
heap, a vertex buffer or an array, and returns offsets into it; it never
touches the space itself. It is a translation of Sebastian Aaltonen's
[OffsetAllocator](#licence-and-credits), and tests show that it gives **the
same results as the original**: the same offsets, the same failures, the
same reports, and the same internal state after every call. It has no
dependencies beyond Zig's standard library and links no libc or libc++.

Free ranges are kept in 256 bins whose sizes follow an 8-bit float (3-bit
mantissa, 5-bit exponent), so an allocation wastes at most 12.5 percent of
its bin (6.25 on average). A two-level bitmask finds the first bin that
fits with two bit scans, so allocate and free are O(1), and a freed range
merges with its free neighbours at once. The design is close to TLSF.

This port was written by Claude (Anthropic's AI model) for Farhollow Games. How the code was verified [can be found below](#how-the-tests-prove-equivalence).

Requires Zig 0.17.0.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-offset-allocator#v0.1.0
```

and import its module in `build.zig`:

```zig
const offset_allocator = b.dependency("offset_allocator", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("offset_allocator", offset_allocator.module("offset_allocator"));
```

Sub-allocate a buffer:

```zig
const std = @import("std");
const offset_allocator = @import("offset_allocator");

pub fn example(gpa: std.mem.Allocator) !void {
    // A 64 MiB vertex buffer, at most 4096 nodes (live ranges plus free regions).
    var ranges = try offset_allocator.Allocator.init(gpa, 64 << 20, 4096);
    defer ranges.deinit(gpa);

    const mesh = try ranges.allocate(1337);
    // ... upload 1337 bytes at mesh.offset ...

    const report = ranges.storageReport();
    std.debug.assert(report.total_free_space == (64 << 20) - 1337);

    ranges.free(mesh);
}
```

The unit is the caller's: bytes, or elements of a buffer of fixed-size
structures.

## API

- `Allocator` uses 32-bit node indices; `Allocator16` uses 16-bit ones
  (the original's `USE_16_BIT_NODE_INDICES`), which halves the metadata and
  allows at most 65536 nodes. Both are `AllocatorOf(NodeIndex)` and can be
  used in one program.
- `init(gpa, size, max_allocs)` and `deinit(gpa)`. `max_allocs` is the node
  count, at least 2: each allocation and each free region uses one, and one
  is held back. `default_max_allocs` (128 * 1024) is the original's
  default.
- `allocate(size) error{NoSpace}!Allocation`. It fails when no free region's
  bin reaches the size rounded up to a bin, or when no node is left. It is
  an `inline` function, so that the result comes back in registers (see
  [Benchmark](#benchmark)); it cannot be taken as a function pointer.
- `free(allocation)`. Freeing twice is illegal (asserted, as in the
  original).
- `reset()` frees everything. An `Allocation` is valid until it is freed or
  the allocator is reset; the core does not check, as the original does
  not (`Ranges` does).
- `allocationSize(allocation)`; 0 for `Allocation.none`.
- `storageReport()`: the total free space and the largest free region,
  rounded down to its bin's size (a request of that size succeeds while a
  node is left); both 0 when out of nodes.
- `storageReportFull()`: the size and number of free regions of each of the
  256 bins.
- `Allocation { offset, metadata }`: `metadata` is the node index, which
  `free` and `allocationSize` read. `Allocation.none` is the original's
  default allocation.
- The allocator owns its node arrays: a copy of it shares them, so after
  copying one (Zig's counterpart of the original's move), use only the
  copy.
- `small_float`: the bin size conversions `uintToFloatRoundUp`,
  `uintToFloatRoundDown` and `floatToUint`.

The node arrays come from the `std.mem.Allocator` given to `init`, once:
nothing allocates after that, so allocate and free stay O(1) and cannot
fail for lack of memory. A caller-provided buffer was the other choice; an
allocator was kept because the two arrays have different types and sizes
for each node index width, which a single byte buffer would make the caller
compute, and because `std.heap.FixedBufferAllocator` gives the
caller-provided form anyway.

## Ranges: units and checked handles

`Ranges` is a thin layer over the core for GPU sub-allocation, in
`src/ranges.zig`. It adds two things the original does not have:

- **A unit.** Sizes and offsets are in bytes (u64); the core manages
  `size_bytes / unit` units, where `unit` is a power of two such as 256
  (Vulkan's uniform buffer offset alignment). Every offset is a multiple of
  the unit, every request is rounded up to whole units, and since the core
  counts units rather than bytes, the space reaches past 4 GiB (2^32 units
  of 256 bytes is 1 TiB).
- **Generation-checked handles.** Each node has a generation; a handle
  carries its node's generation when it was allocated, and `free` and
  `reset` move it on. A double free, or a free of a handle from before a
  `reset`, panics in safe builds (Debug, ReleaseSafe) with a message
  naming the handle, instead of corrupting the core's lists. In
  ReleaseFast the check compiles out, as the core's asserts do; the
  generations stay, so `isLive` and `reset`'s invalidation work in every
  mode and `Handle` has one layout whatever the mode.

It is a layer, and not a change to the core, so the core stays a proven
translation: the layer changes nothing in `src/offset_allocator.zig`, and
the differential tests keep checking the core against the original call
for call. The layer uses only the core's public API and reads its node
array.

```zig
var ranges = try offset_allocator.Ranges.init(gpa, 256 << 20, 4096, 256);
defer ranges.deinit(gpa);

const ubo = try ranges.allocate(200); // 256 bytes at a 256-byte-aligned offset
// ... write 200 bytes at ubo.offset ...
ranges.free(ubo);
std.debug.assert(!ranges.isLive(ubo)); // freeing it again would panic
```

- `Ranges` (over `Allocator`) and `Ranges16` (over `Allocator16`), both
  `RangesOf(Core)`.
- `init(gpa, size_bytes: u64, max_allocs, unit: u32)` and `deinit(gpa)`.
  `size_bytes / unit` must fit in u32; a trailing partial unit is not used.
  `unitBytes()` returns the unit.
- `allocate(size_bytes: u64) error{NoSpace}!Handle`: at least `size_bytes`,
  rounded up to whole units. A zero-size request behaves as the core's: it
  takes a node and must be freed, holds no bytes, and may share its offset
  with the next range.
- `free(handle)`: panics in safe builds if the handle is not live.
- `checkHandle(handle) HandleError!void`, the check `free` runs:
  `NodeOutOfRange`, `StaleGeneration` (freed already, or reset since), or
  `NodeNotInUse`. `isLive(handle) bool` is the same as a bool.
- `sizeOf(handle) u64`: the bytes the handle holds, the request rounded up
  to the unit.
- `reset()` frees everything and makes every outstanding handle stale.
- `storageReport()` and `storageReportFull()`: the core's reports in bytes.
- `Handle { offset: u64, node, generation: u32 }`.

A generation wraps after 2^32 frees of one node, so a handle that old would
read as live again; a handle from another `Ranges` whose node is in range is
not caught.

**Tests** (`test/ranges_test.zig`, run by `zig build test`): over random
sequences (4 seeds and 4 configurations from 1-byte to 4 KiB units, and
1000 fuzzed seeds with units from 1 byte to 2 GiB, both widths), every
offset is a multiple of the unit, no two live ranges share a byte (checked
against a model of the live ranges), and `sizeOf` is at least the request
and less than a unit more; a handle is not live after free or reset, a
reused node gets a new generation, a 1 TiB space in 1 MiB units hands out
ranges past 4 GiB, and requests past 2^32 - 1 units fail. Zig 0.17 cannot
catch a panic inside a test, so the panic is tested through `checkHandle`,
and by running `test/panic.zig`, which must abort with the message for a
double free and for a free after reset.

### Overhead

The layer costs 0.0 to 1.6 ns per call over the core in ReleaseFast, and
about 1 µs on a reset of 32768 nodes (the generations): the `Ranges`
column of the [benchmark](#benchmark), where the core and the layer get the
same requests, the core's already rounded to units, so the difference is
the layer's own work. Allocate pays most, for the generation it reads into
the handle.

## How the tests prove equivalence

`zig build test` builds the original C++ from `reference/` (test-only code,
never part of the package), twice: as shipped, and with
`USE_16_BIT_NODE_INDICES`. Both widths of the port run beside it. The
reference keeps the original's own asserts on (`-DDEBUG -UNDEBUG`: Zig
defines `NDEBUG` for C++ in release modes, which would turn them off), so a
call that breaks one of its invariants aborts the reference too.

- **Differential runs**: random sequences of allocates and frees, about 2
  million calls per width: 6 seeds over 7 configurations (space running out
  first, nodes running out first, the whole 32-bit range, a 100-unit space,
  a space that is not a bin size, the fewest nodes, an empty space), plus
  runs with the original's default 131,072 nodes and with all 65,536 16-bit
  nodes. Each run fills to exhaustion, frees everything back to one region,
  resets with allocations outstanding, and moves the allocator halfway.
  Sizes include zero, exact bin sizes and their neighbours. After every
  call, the results, both storage reports and the bin tables must be
  identical, and so must every node and the freelist (every call for the
  small node counts, periodically for the large ones).
- **Differential fuzzing**: 1000 seeds per width, each with its own space
  (empty, denorm, a bin's size or one off, up to 2^32 - 1), node count (2
  to 4096), requests (zero, the largest free region's bin size and one
  more, the whole space and one more, sizes that round up past the last
  bin) and calls, resets and moves at random, every node compared. A
  failure prints the seed and the configuration, as every random run does.
- **SmallFloat**: both roundings for every u32 against the original, and
  `floatToUint` over its whole defined domain.
- **Properties**, against an independent model of the space: no allocation
  overlaps another or runs past the end, `allocate` fails exactly when the
  bin rule says it must, every freed range merges with its free neighbours,
  and freeing everything leaves one region; fixed configurations and 1000
  fuzzed seeds per width.
- **Broken contracts** (`test/panic.zig`, one run per case in Debug and
  ReleaseSafe): a double free, a free of `Allocation.none` and 65537 16-bit
  nodes abort both the port and the original; a node index past the nodes,
  fewer than 2 nodes and stale `Ranges` handles abort the port.
- **The original's own tests**, translated, for both widths.

[`STATUS.md`](STATUS.md) maps every public function, option and build
switch of the original to its Zig counterpart, its state and the tests that
compare them, and gives the few deliberate differences with their reasons.

## Benchmark

`zig build bench` builds the original at `-O3` (`-std=c++20 -O3
-fno-exceptions -fno-rtti`, its asserts off) and the port in ReleaseFast,
both for the native CPU, and runs them and the `Ranges` layer on the same
requests. `zig build bench -- <runs> <workload>` sets the number of runs
(default 11) and can run one workload alone; `-Dbench-optimize=ReleaseSafe`
builds the port with its checks, and `-Dbench-cpu=2` pins the run to one CPU
with `taskset`.

Sizes are a GPU-like mix in 256-byte units: 70 percent 64 B to 16 KiB, 25
percent to 1 MiB, 5 percent to 16 MiB, in a 16 GiB space with 32768 nodes.

- **steady state**: 10,000 live, then 200 rounds of freeing 1000 at random
  and allocating 1000;
- **fill, free all**: 10,000 allocations, then all freed in random order, 20
  times;
- **churn**: 2000 resident, then 400 frames of 256 allocations of 64 KiB,
  freed in order;
- **reset**: 50 resets of an allocator of 32768 nodes;
- **storageReportFull**: 200 full reports over 5001 free regions.

Each side makes its calls from its own language, one call across per batch,
and neither compiler inlines allocate or free into the loop. Every side
runs once to warm up, then the runs rotate the order of the sides; the
handles every side returns are kept and must be the same, so no side can
skip work. Times are ns per call: the median of 11 runs with the
interquartile range, the best median of 10 invocations.

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (and its clang for the
original), 11 November 2026. **The machine was busy with other builds**
during these runs; the numbers will be taken again on a quiet machine
before a release.

ReleaseFast:

| workload | op | node index | original | port | port / original | Ranges | Ranges / port |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | u32 | 10.9 (10.9–11.0) | 9.2 (9.2–9.2) | 0.84 | 10.6 (10.6–10.7) | 1.15 |
| steady state | free | u32 | 13.7 (13.7–13.8) | 13.1 (13.1–13.2) | 0.96 | 13.8 (13.8–13.8) | 1.05 |
| steady state | allocate | u16 | 10.5 (10.5–10.6) | 8.4 (8.4–8.6) | 0.80 | 10.0 (10.0–10.1) | 1.19 |
| steady state | free | u16 | 13.0 (13.0–13.0) | 12.2 (12.2–12.3) | 0.94 | 12.9 (12.9–12.9) | 1.06 |
| fill, free all | allocate | u32 | 4.5 (4.5–4.5) | 4.3 (4.3–4.3) | 0.96 | 5.0 (5.0–5.1) | 1.16 |
| fill, free all | free | u32 | 8.1 (8.1–8.6) | 7.8 (7.8–8.2) | 0.96 | 8.6 (8.5–8.9) | 1.10 |
| fill, free all | allocate | u16 | 7.1 (7.1–7.1) | 5.0 (5.0–5.1) | 0.70 | 5.9 (5.9–5.9) | 1.18 |
| fill, free all | free | u16 | 7.1 (7.0–7.6) | 6.7 (6.7–7.2) | 0.94 | 7.2 (7.0–7.6) | 1.07 |
| churn | allocate | u32 | 3.8 (3.8–3.9) | 3.9 (3.9–3.9) | 1.03 | 4.7 (4.7–4.7) | 1.21 |
| churn | free | u32 | 5.0 (5.0–5.0) | 4.6 (4.6–4.6) | 0.92 | 4.6 (4.6–4.6) | 1.00 |
| churn | allocate | u16 | 7.1 (7.1–7.1) | 5.1 (5.0–5.2) | 0.72 | 5.5 (5.5–5.6) | 1.08 |
| churn | free | u16 | 5.7 (5.7–5.7) | 4.5 (4.5–4.5) | 0.79 | 4.7 (4.7–4.7) | 1.04 |
| reset | reset | u32 | 11949 (11938–11973) | 6020 (6000–6075) | 0.50 | 7090 (7077–7169) | 1.18 |
| reset | reset | u16 | 10938 (10911–10963) | 3193 (3163–3224) | 0.29 | 3893 (3856–3931) | 1.22 |
| storageReportFull | report | u32 | 13868 (13819–13922) | 13586 (13557–13627) | 0.98 | 13655 (13584–13826) | 1.01 |
| storageReportFull | report | u16 | 12175 (12162–12184) | 11879 (11842–11912) | 0.98 | 12176 (12170–12249) | 1.03 |

The port is faster than the original everywhere but churn allocate with
32-bit indices, 3.9 against 3.8 ns, within the run-to-run spread; the
port's loop also checks every allocation for `error.NoSpace`, where the
original's stores the result unchecked. `Ranges` adds 0.0 to 1.6 ns a call.

This performance pass, the port before and after (ReleaseFast; "before" was
measured in an earlier session on the same machine, whose original numbers
were within 3 percent of these):

| workload | op | node index | original | port before | port after | after / before |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| steady state | allocate | u32 | 10.9 | 11.5 | 9.2 | 0.80 |
| steady state | free | u32 | 13.7 | 13.7 | 13.1 | 0.96 |
| steady state | allocate | u16 | 10.5 | 11.0 | 8.4 | 0.76 |
| steady state | free | u16 | 13.0 | 12.7 | 12.2 | 0.96 |
| fill, free all | allocate | u32 | 4.5 | 6.5 | 4.3 | 0.66 |
| fill, free all | free | u32 | 8.1 | 8.2 | 7.8 | 0.95 |
| fill, free all | allocate | u16 | 7.1 | 7.4 | 5.0 | 0.68 |
| fill, free all | free | u16 | 7.1 | 7.3 | 6.7 | 0.92 |
| churn | allocate | u32 | 3.8 | 6.4 | 3.9 | 0.61 |
| churn | free | u32 | 5.0 | 4.8 | 4.6 | 0.96 |
| churn | allocate | u16 | 7.1 | 7.2 | 5.1 | 0.71 |
| churn | free | u16 | 5.7 | 5.4 | 4.5 | 0.83 |
| reset | reset | u32 | 11949 | 12088 | 6020 | 0.50 |
| reset | reset | u16 | 10938 | 10967 | 3193 | 0.29 |
| storageReportFull | report | u32 | 13868 | 13493 | 13586 | 1.01 |
| storageReportFull | report | u16 | 12175 | 11749 | 11879 | 1.01 |

What changed, each kept only for a gain the benchmark showed, with every
oracle test unchanged:

- **`allocate` returns in registers.** Zig returns the error union
  through memory, written as two 4-byte stores and read back as one 8-byte
  load, which stalls store forwarding. A private function returns the
  offset and node index packed in one integer (offset `no_space` on
  failure, which no allocation has), and `allocate` is an `inline` wrapper
  over it.
- **`reset` stores whole vectors**: the nodes 16 at a time from a block of
  default nodes (a node is 28 or 20 bytes, which no vector fits), and the
  freelist a vector of descending indices at a time.
- **The bin roundings have no branch**, where the original branches on
  denorms, and **a node's `used` flag sits before its four indices**, so a
  new node's indices are one vector store apart from its size, which the
  next `free` of a neighbour often reads back at once. With the original
  field order, LLVM put the size inside that vector store and 32-bit churn
  got slower (allocate 4.0 to 4.4 ns, free 4.7 to 5.6); with both changes
  every row is as fast or faster.
- **`Ranges.reset` moves the generations on a vector at a time**; the
  compiler left the plain loop scalar (32-bit: 9.3 to 7.1 µs, 16-bit: 6.4
  to 3.9 µs).

Tried and dropped for no clear gain: local copies of the node slice, and
scanning the leaf bins without testing the top bin's bit first.
`storageReportFull`, a walk of every bin's linked list bound by memory
latency, was not tuned.

ReleaseSafe (the port's asserts and bounds checks on, and the `Ranges`
check; the original still at `-O3` without its asserts), medians:

| workload | op | node index | original | port | port / original | Ranges | Ranges / port |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | u32 | 10.9 | 11.0 | 1.01 | 12.3 | 1.12 |
| steady state | free | u32 | 14.3 | 16.7 | 1.17 | 18.1 | 1.08 |
| steady state | allocate | u16 | 10.6 | 9.8 | 0.92 | 11.3 | 1.15 |
| steady state | free | u16 | 12.4 | 14.7 | 1.19 | 15.9 | 1.08 |
| fill, free all | allocate | u32 | 4.5 | 5.7 | 1.27 | 6.6 | 1.16 |
| fill, free all | free | u32 | 8.3 | 11.8 | 1.42 | 13.2 | 1.12 |
| fill, free all | allocate | u16 | 7.0 | 7.3 | 1.04 | 7.7 | 1.05 |
| fill, free all | free | u16 | 7.0 | 10.3 | 1.47 | 11.2 | 1.09 |
| churn | allocate | u32 | 3.9 | 5.6 | 1.44 | 6.4 | 1.14 |
| churn | free | u32 | 5.1 | 6.7 | 1.31 | 7.2 | 1.07 |
| churn | allocate | u16 | 7.0 | 7.4 | 1.06 | 7.4 | 1.00 |
| churn | free | u16 | 5.7 | 7.6 | 1.33 | 7.8 | 1.03 |
| reset | reset | u32 | 12032 | 6125 | 0.51 | 7189 | 1.17 |
| reset | reset | u16 | 10968 | 3804 | 0.35 | 4565 | 1.20 |
| storageReportFull | report | u32 | 14274 | 12857 | 0.90 | 12927 | 1.01 |
| storageReportFull | report | u16 | 12052 | 9859 | 0.82 | 9868 | 1.00 |

`storageReportFull` comes out faster in ReleaseSafe than in ReleaseFast on
this machine; the two modes lay out its list walk differently.

## Status

The original calls itself "an early one weekend prototype ... use at your
own risk". This port is held to a stricter bar than the original's own
tests:

- It is checked call for call against the original, about 2 million calls
  per node-index width and 1000 fuzzed configurations, with the original's
  asserts on.
- An independent model checks for overlaps, failures and coalescing after
  every call.
- Three bugs planted on purpose were each caught by the tests.
- The tests found edge cases where the original reads out of bounds: fewer
  than 2 nodes, and `allocationSize` of an empty allocation in 16-bit mode.
  The port guards them ([`STATUS.md`](STATUS.md)).

The algorithm also has users beyond its author: Patrick Walton's Rust port
is the allocator behind Bevy's mesh memory.

## Licence and credits

MIT, the original's licence ([`LICENSE`](LICENSE)); see [`NOTICE`](NOTICE).

- Translated from [OffsetAllocator](https://github.com/sebbbi/OffsetAllocator)
  by [Sebastian Aaltonen](https://github.com/sebbbi) (MIT), commit
  `3610a73`. Its design is described in the
  [original README](https://github.com/sebbbi/OffsetAllocator#readme); no
  longer write-up by the author was found.
- **The original's reference.** Its README describes it as similar to the
  two-level segregated fit (TLSF) algorithm, and cites
  [A comparison of memory allocators for real-time applications](https://www.researchgate.net/profile/Alfons-Crespo/publication/234785757_A_comparison_of_memory_allocators_for_real-time_applications/links/5421d8550cf2a39f4af765f4/A-comparison-of-memory-allocators-for-real-time-applications.pdf)
  (M. Masmano, I. Ripoll, A. Crespo, J. Real, JTRES 2006) for TLSF's
  performance and fragmentation.
- **Background reading:** TLSF itself is described in
  ["TLSF: a new dynamic memory allocator for real-time systems"](https://doi.org/10.1109/EMRTS.2004.1311009)
  by the same authors (ECRTS 2004). OffsetAllocator is not a translation of
  it: TLSF keeps its headers inside the memory it manages, and
  OffsetAllocator keeps all bookkeeping in separate node arrays, so it can
  manage memory the CPU cannot touch, such as GPU heaps.
- Patrick Walton's Rust port,
  [offset-allocator](https://github.com/pcwalton/offset-allocator), was
  consulted for its tests.

Made by Farhollow Games for the Loomwork Engine.
