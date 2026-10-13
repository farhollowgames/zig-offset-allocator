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
