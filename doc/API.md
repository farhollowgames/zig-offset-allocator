# API

The public API of zig-offset-allocator. The doc comments in `src/` give each
function's details. The README has a short example.

## Allocator

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
  [`BENCHMARKS.md`](BENCHMARKS.md#the-performance-pass)); it cannot be taken
  as a function pointer.
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

It is a layer, and not a change to the core, so the core stays the
translation the differential tests check: the layer changes nothing in `src/offset_allocator.zig`, and
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

`Ranges` costs 0.0 to 1.6 ns per call over the core; see
[`BENCHMARKS.md`](BENCHMARKS.md#the-ranges-layer). Its tests are described
in [`TESTING.md`](TESTING.md#tests-and-counts).
