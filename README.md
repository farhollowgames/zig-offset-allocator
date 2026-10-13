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
  bin reaches the size rounded up to a bin, or when no node is left.
- `free(allocation)`. Freeing twice is illegal (asserted, as in the
  original).
- `reset()` frees everything.
- `allocationSize(allocation)`; 0 for `Allocation.none`.
- `storageReport()`: the total free space and the largest free region,
  rounded down to its bin's size (a request of that size succeeds while a
  node is left); both 0 when out of nodes.
- `storageReportFull()`: the size and number of free regions of each of the
  256 bins.
- `Allocation { offset, metadata }`: `metadata` is the node index, which
  `free` and `allocationSize` read. `Allocation.none` is the original's
  default allocation.
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
translation: `src/offset_allocator.zig` is untouched, and the differential
tests keep checking it against the original call for call. The layer uses
only the core's public API and reads its node array.

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
sequences (4 seeds, 4 configurations from 1-byte to 4 KiB units, both
widths), every offset is a multiple of the unit, no two live ranges share a
byte (checked against a model of the live ranges), and `sizeOf` is at least
the request and less than a unit more; a handle is not live after free or
reset, a reused node gets a new generation, a 1 TiB space in 1 MiB units
hands out ranges past 4 GiB, and requests past 2^32 - 1 units fail. Zig
0.17 cannot catch a panic inside a test, so the panic is tested through
`checkHandle`, and by running `test/ranges_panic.zig`, which must abort
with the message for a double free and for a free after reset.

### Overhead

`zig build bench` (ReleaseFast; `-Dbench-optimize=ReleaseSafe` for the
checked build, `-Dbench-cpu=2` to pin it with `taskset`) gives the core and
the layer the same requests, the core already rounded to units, so the
difference is the layer's own work. Sizes are a GPU-like mix: 70 percent 64
B to 16 KiB, 25 percent to 1 MiB, 5 percent to 16 MiB, in a 16 GiB space with
32768 nodes. Times are ns per call, the median of 11 runs.

- **steady state**: 10,000 live, then 200 rounds of freeing 1000 at random
  and allocating 1000;
- **fill, free all**: 10,000 allocations, then all freed in random order, 20
  times;
- **churn**: 2000 resident, then 400 frames of 256 allocations of 64 KiB,
  freed in order.

AMD Ryzen 9 9950X3D, pinned to CPU 2, Linux, 2026-10-12.

ReleaseFast (the check compiled out):

| workload | op | core u32 | Ranges | overhead | core u16 | Ranges16 | overhead |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | 12.5 | 13.7 | 10% | 12.0 | 13.0 | 8% |
| | free | 15.0 | 15.7 | 5% | 13.6 | 14.4 | 6% |
| fill, free all | allocate | 6.8 | 8.0 | 18% | 7.8 | 7.7 | -2% |
| | free | 7.5 | 8.1 | 8% | 6.8 | 6.9 | 1% |
| churn | allocate | 6.6 | 7.7 | 17% | 7.4 | 7.2 | -1% |
| | free | 4.8 | 5.0 | 5% | 5.5 | 5.3 | -4% |

ReleaseSafe (the check on, and the core's asserts):

| workload | op | core u32 | Ranges | overhead | core u16 | Ranges16 | overhead |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | 13.8 | 14.7 | 7% | 13.0 | 14.3 | 10% |
| | free | 17.8 | 19.3 | 8% | 16.6 | 17.7 | 7% |
| fill, free all | allocate | 7.4 | 8.5 | 15% | 8.2 | 8.5 | 4% |
| | free | 11.6 | 13.3 | 15% | 11.1 | 12.0 | 9% |
| churn | allocate | 7.0 | 7.8 | 11% | 7.7 | 7.6 | -1% |
| | free | 6.8 | 7.3 | 8% | 7.9 | 7.9 | 0% |

The layer costs at most about 1 ns per call in ReleaseFast and under 2 ns
with the check on. The percentages look large only where the core's call is 5 to 8
ns; the small negative figures are within run-to-run and code layout
noise (repeated runs move them by a few tenths of a ns).

## How the tests prove equivalence

`zig build test` builds the original C++ from `reference/` (test-only code,
never part of the package), twice: as shipped, and with
`USE_16_BIT_NODE_INDICES`. Both widths of the port run beside it.

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
  small node counts, periodically for the large ones). The reference is
  built with its own asserts on.
- **SmallFloat**: both roundings for every u32 against the original, and
  `floatToUint` over its whole defined domain.
- **Properties**, against an independent model of the space: no allocation
  overlaps another or runs past the end, `allocate` fails exactly when the
  bin rule says it must, every freed range merges with its free neighbours,
  and freeing everything leaves one region.
- **The original's own tests**, translated, for both widths.

[`doc/parity.md`](doc/parity.md) maps every public function, option and
build switch of the original to its Zig counterpart and the test that
compares them, and gives the few deliberate differences with their reasons.

## Status

The original calls itself "an early one weekend prototype ... use at your
own risk". This port is held to a stricter bar than the original's own
tests:

- It is checked call for call against the original, about 2 million calls
  per node-index width, with the original's asserts on (below).
- An independent model checks for overlaps, failures and coalescing after
  every call.
- Three bugs planted on purpose were each caught by the tests.
- The tests found edge cases where the original reads out of bounds: fewer
  than 2 nodes, and `allocationSize` of an empty allocation in 16-bit mode.
  The port guards them ([`doc/parity.md`](doc/parity.md)).

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
