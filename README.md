# zig-offset-allocator

Ported from OffsetAllocator (`3610a73`) · Zig 0.17.0 · [status](STATUS.md)

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## What it is

A Zig port of OffsetAllocator, Sebastian Aaltonen's O(1) allocator that
hands out ranges of a contiguous space, such as a GPU heap, a vertex buffer
or an array, and returns offsets into it. It never touches the space
itself. It is pure Zig, with no dependencies beyond the standard library,
and links no libc or libc++. The original is listed under
[References](#references).

## Features

- Allocate and free in O(1): free ranges are kept in 256 bins whose sizes
  follow an 8-bit float (3-bit mantissa, 5-bit exponent), and a two-level
  bitmask finds the first bin that fits with two bit scans. An allocation
  wastes at most 12.5 percent of its bin.
- A freed range merges with its free neighbours at once.
- All bookkeeping lives in node arrays apart from the space, which are
  allocated once at `init`; nothing allocates after that.
- 32-bit (`Allocator`) or 16-bit (`Allocator16`) node indices.
- Storage reports: total free space and the largest free region, or the
  free regions of every bin.
- `Ranges`, a layer over the core with byte sizes, a unit such as 256, and
  generation-checked handles.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-offset-allocator#v0.1.0
```

`v0.1.0` is the latest release. The package needs Zig 0.17.0.

In `build.zig`:

```zig
const offset_allocator = b.dependency("offset_allocator", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("offset_allocator", offset_allocator.module("offset_allocator"));
```

## Use

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
structures. [`doc/API.md`](doc/API.md) describes the allocator and the
`Ranges` layer.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md).

*Additions*:

- `Allocator` and `Allocator16` in one build; the original picks its width with `USE_16_BIT_NODE_INDICES`.
- `max_max_allocs`, the largest node count of each width.
- `small_float` is public; the original's SmallFloat functions have no header declaration.
- `Ranges` and `Ranges16`: byte sizes in a unit, spaces past 4 GiB, and generation-checked handles.

*Changes to expect*:

- `init` takes a `std.mem.Allocator` and can return `error.OutOfMemory`; `deinit` takes the same allocator.
- `allocate` returns `error{NoSpace}!Allocation`, not an allocation holding `NO_SPACE`; `Allocation.none` is the original's default allocation.
- `allocate` is a `pub inline fn`, so it cannot be taken as a function pointer.
- `Node` is an `extern struct` with `used` before its four indices, a different field order from the original's.
- `max_allocs` must be at least 2 (asserted); the original's behaviour with 0 or 1 is undefined.
- Freeing `Allocation.none` is asserted in both widths; the original's check never fires in 16-bit mode.
- `allocationSize(Allocation.none)` is 0 in both widths; the original's 16-bit build can read out of bounds.
- `reset` reuses the node arrays, where the original frees and reallocates them.
- A move is a Zig value copy, after which the old copy is not used; there is no moved-from state.

## Left out

The parts of the original that are left out, each with its reason, are
listed in [`STATUS.md`](STATUS.md#left-out). In short:

- `DEBUG_VERBOSE`, debug printing of freelist and free storage changes,
  which changes no result.
- `USE_16_BIT_OFFSETS`, commented out in the original's header and never
  read.

## Tests

`zig build test` runs 36 tests and 10 runs of a contract program. The
differential tests run the original, built from `reference/` with its own
asserts on, beside both widths of the port, about 2.07 million calls and
1,000 fuzzed configurations per width, and compare every result and every
field of the allocator's state after each call.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/parity.md`](doc/parity.md): where the port differs from the
  original, and why.

## Speed

Port time per call against original time, 32-bit node indices, on a
GPU-like mix of sizes:

| feature | time, port / original | port vs original |
| --- | ---: | ---: |
| steady state, allocate | 0.84 | 16% faster |
| steady state, free | 0.96 | 4% faster |
| churn, allocate | 1.04 | 4% slower |
| reset | 0.51 | 49% faster |
| storageReportFull | 0.95 | 5% faster |

Churn allocate with 32-bit indices is the one row of the full table where
the port takes more time than the original; its loop also checks every
allocation for `error.NoSpace`, where the original's stores the result
unchecked.

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 ReleaseFast against
Zig's clang `-O3`, at commit `bb82860`; each row from the invocation with
the median ratio of three, each the median of 11 runs; a load average of
2.8 on 32 hardware threads.

- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every row, both widths,
  ReleaseSafe, the `Ranges` layer, the flags and the command.

## Licence

MIT License, the original's ([`LICENSE`](LICENSE)). zig-offset-allocator is
an altered version of OffsetAllocator: the code is rewritten in Zig, with
its own interface. The original's notice, "Copyright (c) 2023 Sebastian
Aaltonen", is kept in `LICENSE` as it is, beside "Copyright 2026 Farhollow
Games". [`NOTICE`](NOTICE) says what was translated from where.

## References

- [OffsetAllocator](https://github.com/sebbbi/OffsetAllocator), the
  original, by [Sebastian Aaltonen](https://github.com/sebbbi), commit
  `3610a73`, copied into `reference/` for the tests and the benchmark only.
  Its design is described in its
  [README](https://github.com/sebbbi/OffsetAllocator#readme).
- The original's README compares it with the two-level segregated fit
  (TLSF) algorithm and cites
  [A comparison of memory allocators for real-time applications](https://www.researchgate.net/profile/Alfons-Crespo/publication/234785757_A_comparison_of_memory_allocators_for_real-time_applications/links/5421d8550cf2a39f4af765f4/A-comparison-of-memory-allocators-for-real-time-applications.pdf)
  (M. Masmano, I. Ripoll, A. Crespo, J. Real, JTRES 2006).
- TLSF itself is described in
  ["TLSF: a new dynamic memory allocator for real-time systems"](https://doi.org/10.1109/EMRTS.2004.1311009)
  by the same authors (ECRTS 2004). OffsetAllocator is not a translation of
  it: TLSF keeps its headers inside the memory it manages, and
  OffsetAllocator keeps all bookkeeping in separate node arrays.
- Patrick Walton's Rust port,
  [offset-allocator](https://github.com/pcwalton/offset-allocator), was
  consulted for its tests.

Made by Farhollow Games for the Loomwork Engine.
