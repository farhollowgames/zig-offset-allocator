# Status: feature parity with the original

zig-offset-allocator aims to do everything OffsetAllocator does, with
identical results. This file lists every public function, type, constant
and build-time switch of the original (sebbbi/OffsetAllocator at commit
`3610a73`, its header, source, README and tests; it has no releases), what
corresponds to it here, its state, and the tests that show they behave the
same. The tests are in `test/` and run with `zig build test`.

A state is one of: **not started**; **ported**; **oracle-tested** (tests
run the original from `reference/` on the same inputs and require identical
results); **benchmarked** (also measured against the original by
`zig build bench`, see `doc/BENCHMARKS.md`); **reviewed** (set at a release, after
the skeptic's review). Every state includes the ones before it.

A "differential" test runs the original C++ on the same calls and requires
identical results; `test/differential.zig` also compares every field of
both allocators' state (bin masks, bin heads, freelist and every node) after
every call, or every few calls for the larger node counts. The reference is
built with the original's asserts on, so a call that breaks one of its
invariants aborts the reference too.

## Allocator

| original | zig-offset-allocator | state | tests |
| --- | --- | --- | --- |
| `Allocator(size, maxAllocs)` | `Allocator.init(gpa, size, max_allocs)` | oracle-tested | differential: every run starts with a full state comparison; sizes 0, 100, 1000, 1,000,003, 2^20, 2^24, 2^28, 2^30 and 2^32 - 1 and 1000 fuzzed ones (below); node counts 2, 16, 48, 256, 512, 1024, 4096, 65536 and 131072, and 1000 fuzzed ones from 2 to 4096 |
| `maxAllocs = 128 * 1024` (default argument) | `default_max_allocs` (Zig has no default arguments) | oracle-tested | differential: the C++ default constructor's `m_maxAllocs` equals it, and a 200,000-step run with it |
| `~Allocator()` | `deinit(gpa)` | ported | every test frees through `std.testing.allocator`, which fails on leaks |
| `Allocator(Allocator&&)` | a Zig value copy (`const b = a;`), after which `a` is not used | oracle-tested | differential: every run moves the C++ allocator and copies the Zig one halfway through its first round, then continues comparing; the fuzzed runs move at random |
| `reset()` | `reset()` | benchmarked | differential: a reset with allocations outstanding in every run, then a full round more, and resets at random in the fuzzed runs, each followed by a full state comparison; unit: `allocationSize, Allocation.none and reset` |
| `allocate(size)` | `allocate(size)`, returning `error{NoSpace}!Allocation` | benchmarked | differential: about 2.07 million calls per node index width in the fixed runs, and the fuzzed runs; every offset and node index compared; unit: the original's suite |
| `allocate` failure: `{NO_SPACE, NO_SPACE}` | `error.NoSpace` | oracle-tested | differential: every failure of either side must be a failure of both, and the reference's failure must hold `NO_SPACE` in both fields (narrowed to `0xffff` for 16-bit) |
| out of nodes (`m_freeOffset == 0`) | `error.NoSpace` | oracle-tested | differential: 48 and 2 nodes, nodes run out first, and fuzzed node counts; unit: `NO_SPACE: out of nodes`; property: failure exactly when the model predicts it |
| out of space (no bin at or above the request's rounded-up bin) | `error.NoSpace` | oracle-tested | differential: fill to exhaustion in every run (until 64 requests in a row fail); the fuzzed requests include the largest free region's bin size and one more, the whole space and one more, and sizes above 0xf000_0000, which round up to bin 240; unit: `NO_SPACE: a free region too small for the request's bin`; property: failure exactly when the model predicts it |
| `free(allocation)` | `free(allocation)` | benchmarked | differential: random frees and freeing everything in random order; the final state must be one free region; property: free space and the per-bin region counts match a model in which free neighbours always merge |
| `ASSERT(node.used == true)` in `free` (double free) | `assert(node.used)` | oracle-tested | panic: a double free aborts the port (`free_twice`) and the reference (`original_free_twice`) |
| `ASSERT(metadata != NO_SPACE)` in `free` | `assert(metadata != unused)` | oracle-tested | panic: freeing `Allocation.none` aborts the port (`free_none`) and the 32-bit reference (`original_free_none`); see the 16-bit difference below |
| `free` of a node index past the nodes (undefined in the original) | a bounds-check panic in safe builds | ported | panic: `free_foreign` |
| `allocationSize(allocation)` | `allocationSize(allocation)` | oracle-tested | differential: every successful allocation, and every live allocation at each full comparison |
| `allocationSize` of a default or failed `Allocation` | `allocationSize(Allocation.none)`, 0 | oracle-tested | differential, both widths (see 16-bit below) |
| `storageReport()` | `storageReport()`, `StorageReport{ total_free_space, largest_free_region }` | oracle-tested | differential after every call; property: matches the model, and both 0 when out of nodes |
| `storageReportFull()` | `storageReportFull()`, `StorageReportFull{ free_regions: [256]Region{ size, count } }` | benchmarked | differential after every call, all 256 bins, including the wrapped sizes of bins 240 to 255 |
| `Allocation { offset, metadata }`, defaulting to `NO_SPACE` | `Allocation { offset, metadata }`; the default is `Allocation.none` | oracle-tested | its fields compared on every allocation |
| `Allocation::NO_SPACE` | `no_space` | oracle-tested | as above |
| `NUM_TOP_BINS`, `BINS_PER_LEAF`, `TOP_BINS_INDEX_SHIFT`, `LEAF_BINS_INDEX_MASK`, `NUM_LEAF_BINS` | `num_top_bins`, `bins_per_leaf`, `top_bins_index_shift`, `leaf_bins_index_mask`, `num_leaf_bins` | oracle-tested | the state comparison reads arrays of these sizes from both |
| `typedef uint8, uint16, uint32` | Zig's `u8`, `u16`, `u32` | ported | |

## Build-time switches

| original | zig-offset-allocator | state | tests |
| --- | --- | --- | --- |
| `NodeIndex = uint32` (default) | `Allocator` (`AllocatorOf(u32)`) | benchmarked | every differential and unit test |
| `#define USE_16_BIT_NODE_INDICES` (`NodeIndex = uint16`) | `Allocator16` (`AllocatorOf(u16)`), both in one build | benchmarked | a second reference build with the define; every differential test runs on both widths, including all 65536 nodes; the shim reports `sizeof(NodeIndex)` of each build |
| `ASSERT(maxAllocs <= 65536)` in 16-bit mode | `assert(max_allocs <= max_max_allocs)` | oracle-tested | panic: 65537 nodes abort the port (`init_16_too_many`) and the 16-bit reference (`original_init_16_too_many`) |
| `DEBUG` (turns `ASSERT` on) | Zig asserts on the same conditions (on in Debug and ReleaseSafe) | oracle-tested | the reference is built with `DEBUG` and `-UNDEBUG` (Zig defines `NDEBUG` for C++ in release modes, which would turn `assert` off), so its asserts run under the same calls, and the panic cases above abort it; the tests run in ReleaseSafe, and pass in Debug too |
| `DEBUG_VERBOSE` (prints freelist and free storage changes) | not ported | not started (left out) | debug printing only; it changes no result |
| `USE_16_BIT_OFFSETS` (commented out at the top of the header) | not ported | not started (left out) | never defined or read anywhere in the original |
| `_MSC_VER` (`_BitScanReverse`/`_BitScanForward` instead of `__builtin_clz`/`__builtin_ctz`) | `@clz`, `@ctz` | oracle-tested | same results; the SmallFloat sweep and the allocator runs cover them |

## SmallFloat

| original | zig-offset-allocator | state | tests |
| --- | --- | --- | --- |
| `SmallFloat::uintToFloatRoundUp` | `small_float.uintToFloatRoundUp` | oracle-tested | differential: every u32 (2^32 values, on 16 threads); unit: the original's cases |
| `SmallFloat::uintToFloatRoundDown` | `small_float.uintToFloatRoundDown` | oracle-tested | differential: every u32; unit: the original's cases |
| `SmallFloat::floatToUint` | `small_float.floatToUint` | oracle-tested | differential: 0 to 263, its whole defined domain (the original shifts by `exponent - 1`, undefined from 264 on; the port asserts below 264); bins 240 to 263 wrap past 32 bits in both; unit: the README's bin table |
| `MANTISSA_BITS`, `MANTISSA_VALUE`, `MANTISSA_MASK` | `small_float.mantissa_bits`, `mantissa_value`, `mantissa_mask` | ported | |
| `findLowestSetBitAfter` (internal) | private `findLowestSetBitAfter`, returning `?u5` for `NO_SPACE` | oracle-tested | through every allocate |

These live in the original's `.cpp` without a header declaration (its tests
declare them `extern`); the port makes them public as `small_float`. The
port computes both roundings without the original's branch on denorms; the
every-u32 sweep shows the results are the same.

## Fuzzing and malformed input

- **Differential fuzzing** (`test/differential.zig`): 1000 seeds per node
  index width. Each draws a space (empty, a denorm size, a bin's size or one
  off it, 2^32 - 1 or one or two less, or any), a node count from 2 to 4096
  (as many below 64 as above), and 50 to 400 calls: allocates, frees, and
  at random resets and moves. Requests are 0, 1 to 16, the largest free
  region's bin size or one off it, the space or one off it, above
  0xf000_0000, a bin's size or one off it, a small share of the space, or
  any size up to it. Every node is compared after every call up to 512
  nodes (every 8 calls above), and always after a reset or a move. A
  failure prints the seed and the configuration.
- **Properties and `Ranges`**: 1000 seeds per width each, over fuzzed
  spaces, node counts and (for `Ranges`) units from 1 byte to 2 GiB.
- **Malformed input** (`test/panic.zig`, run once per case by
  `zig build test` in Debug and ReleaseSafe, which expects the abort and its
  message): the contract breaks listed above, the port's own checks
  (`init_one_node`: fewer than 2 nodes), and stale `Ranges` handles.

## Left out

- `DEBUG_VERBOSE`: debug printing of freelist and free storage changes; it
  changes no result.
- `USE_16_BIT_OFFSETS`: commented out at the top of the header, and never
  defined or read anywhere in the original.

The rows above say the same in the build-time switches table.

## Differences, and why

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
  from its size (see `doc/BENCHMARKS.md`). The tests compare nodes field
  by field, so the order is not visible to them or to callers.
- **The 16-bit reference needs `-Wno-c++11-narrowing`**: the original's
  braced initializers narrow `uint32` into the 16-bit `NodeIndex`, which
  clang rejects by default. The flag keeps C++'s truncation, which the port
  matches (`0xffff` for `NO_SPACE`).

Added in zig-offset-allocator, beyond the original: `max_max_allocs` (the
largest node count each width addresses), and `Allocator16` beside
`Allocator` in one build.

## The Ranges layer

`Ranges` (`src/ranges.zig`: units, byte offsets and generation-checked
handles) has no counterpart in the original, so it has no oracle; it is
built on the core's public API without changing the core, so the
comparisons above still cover every line of the translation.

| zig-offset-allocator | state | tests |
| --- | --- | --- |
| `Ranges`, `Ranges16`, `RangesOf(Core)`; `init`, `deinit`, `unitBytes` | ported | `test/ranges_test.zig`: fixed configurations and 1000 fuzzed seeds per width, against a model of the live ranges |
| `allocate`, `free` | benchmarked | the same; every offset a multiple of the unit, no shared bytes, sizes rounded up to the unit; `doc/BENCHMARKS.md` measures the layer's cost over the core |
| `reset` | benchmarked | every outstanding handle goes stale |
| `checkHandle`, `isLive`, `HandleError` | ported | stale, foreign and never-allocated handles; panic: `ranges_free_twice`, `ranges_free_after_reset` |
| `sizeOf`, `storageReport`, `storageReportFull` | ported | in bytes, against the model |
