# Differences from the original

zig-offset-allocator gives the results OffsetAllocator gives, call for
call. [`STATUS.md`](../STATUS.md) lists every public function, type,
constant and build-time switch of the original with its counterpart, its
state and its tests. This file gives the reasons for each difference a
caller can see.

## Additions

- **`Allocator` and `Allocator16` in one build.** The original picks its
  node index width with `USE_16_BIT_NODE_INDICES`; the port has both, as
  `AllocatorOf(u32)` and `AllocatorOf(u16)`, and the tests run every
  differential test on both.
- **`max_max_allocs`**, the largest node count each width addresses.
- **`small_float` is public.** The original's SmallFloat functions live in
  its `.cpp` without a header declaration (its tests declare them
  `extern`).
- **`Ranges` and `Ranges16`** (`src/ranges.zig`), a layer over the core with
  byte sizes in a unit, spaces past 4 GiB and generation-checked handles. It
  has no counterpart in the original, so it has no oracle; it is built on
  the core's public API without changing the core, and its tests check it
  against a model of the live ranges.

## Changes to expect

- **Node arrays come from a `std.mem.Allocator` at `init`**, as the
  original's come from `new`, so `init` can fail with `error.OutOfMemory`
  and `deinit` takes the same allocator. `reset` reuses the arrays where the
  original frees and reallocates them; it resets every node to the default
  as `new Node[]` does, which the full state comparison after each reset
  checks. Nothing allocates after `init`.
- **`allocate` returns `error.NoSpace`** where the original returns an
  allocation holding `NO_SPACE`. Every failure is the same failure; Zig
  makes the caller handle it. `Allocation.none` keeps the original's default
  allocation for callers that store one. `allocate` is an `inline` function
  over a private one that returns the allocation in a register, so it
  cannot be taken as a function pointer.
- **`max_allocs` must be at least 2** (asserted). With 1 the original pops
  the freelist past its end on the first split (its free offset wraps to
  `0xffffffff`), and with 0 it writes out of bounds in `reset`.
- **`free` of `Allocation.none` is asserted in both widths.** The
  original's `ASSERT(metadata != NO_SPACE)` compares a 16-bit metadata with
  the 32-bit constant, which is always true, so in 16-bit mode it does not
  catch it. Freeing `none` is undefined in both.
- **`allocationSize(Allocation.none)` is 0 in both widths.** In 16-bit mode
  the same widened comparison never matches, and the original reads node
  65535: with 65536 nodes that node exists and is never used (the freelist
  slot holding the last node is never popped), so the original returns 0,
  which the differential test confirms; with fewer nodes it reads out of
  bounds. The port returns 0 without reading.
- **The moved-from state** of the C++ move constructor (null arrays, so
  `free` does nothing, `allocationSize` returns 0 and the reports return
  0, while `reset` and `storageReportFull` crash) has no Zig counterpart: a
  Zig value is copied, and the caller stops using the old copy.
- **The node's fields are in another order**: `used` comes before the four
  indices, which lets a new node's indices be stored as one vector apart
  from its size (see [`BENCHMARKS.md`](BENCHMARKS.md)). The tests compare nodes field
  by field, so the order is not visible to them or to callers.
- **The 16-bit reference needs `-Wno-c++11-narrowing`**: the original's
  braced initializers narrow `uint32` into the 16-bit `NodeIndex`, which
  clang rejects by default. The flag keeps C++'s truncation, which the port
  matches (`0xffff` for `NO_SPACE`).
