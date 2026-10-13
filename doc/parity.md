# Feature parity with the original

zig-offset-allocator aims to do everything OffsetAllocator does, with
identical results. This file lists every public function, type, constant
and build-time switch of the original (sebbbi/OffsetAllocator at commit
`3610a73`), what corresponds to it here, and the test that shows they
behave the same. The tests are in `test/` and run with `zig build test`. A
"differential" test runs the original C++ from `reference/` on the same
calls and requires identical results; `test/differential.zig` also compares
every field of both allocators' state (bin masks, bin heads, freelist and
every node) after every call, or every few calls for the larger node counts.

## Allocator

| original | zig-offset-allocator | test |
| --- | --- | --- |
| `Allocator(size, maxAllocs)` | `Allocator.init(gpa, size, max_allocs)` | differential: every run starts with a full state comparison; sizes 0, 100, 1000, 1,000,003, 2^20, 2^24, 2^28, 2^30 and 2^32 - 1; node counts 2, 16, 48, 256, 512, 1024, 4096, 65536 and 131072 |
| `maxAllocs = 128 * 1024` (default argument) | `default_max_allocs` (Zig has no default arguments) | differential: the C++ default constructor's `m_maxAllocs` equals it, and a 200,000-step run with it |
| `~Allocator()` | `deinit(gpa)` | every test frees through `std.testing.allocator`, which fails on leaks |
| `Allocator(Allocator&&)` | a Zig value copy (`const b = a;`), after which `a` is not used | differential: every run moves the C++ allocator and copies the Zig one halfway through its first round, then continues comparing |
| `reset()` | `reset()` | differential: a reset with allocations outstanding in every run, then a full round more; unit: `allocationSize, Allocation.none and reset` |
| `allocate(size)` | `allocate(size)`, returning `error{NoSpace}!Allocation` | differential: about 2.07 million calls per node index width, every offset and node index compared; unit: the original's suite |
| `allocate` failure: `{NO_SPACE, NO_SPACE}` | `error.NoSpace` | differential: every failure of either side must be a failure of both, and the reference's failure must hold `NO_SPACE` in both fields (narrowed to `0xffff` for 16-bit) |
| out of nodes (`m_freeOffset == 0`) | `error.NoSpace` | differential: 48 and 2 nodes, nodes run out first; unit: `NO_SPACE: out of nodes`; property: failure exactly when the model predicts it |
| out of space (no bin at or above the request's rounded-up bin) | `error.NoSpace` | differential: fill to exhaustion in every run (until 64 requests in a row fail); unit: `NO_SPACE: a free region too small for the request's bin`; property: failure exactly when the model predicts it |
| `free(allocation)` | `free(allocation)` | differential: random frees and freeing everything in random order; the final state must be one free region; property: free space and the per-bin region counts match a model in which free neighbours always merge |
| `allocationSize(allocation)` | `allocationSize(allocation)` | differential: every successful allocation, and every live allocation at each full comparison |
| `allocationSize` of a default or failed `Allocation` | `allocationSize(Allocation.none)`, 0 | differential, both widths (see 16-bit below) |
| `storageReport()` | `storageReport()`, `StorageReport{ total_free_space, largest_free_region }` | differential after every call; property: matches the model, and both 0 when out of nodes |
| `storageReportFull()` | `storageReportFull()`, `StorageReportFull{ free_regions: [256]Region{ size, count } }` | differential after every call, all 256 bins, including the wrapped sizes of bins 240 to 255 |
| `Allocation { offset, metadata }`, defaulting to `NO_SPACE` | `Allocation { offset, metadata }`; the default is `Allocation.none` | its fields compared on every allocation |
| `Allocation::NO_SPACE` | `no_space` | as above |
| `NUM_TOP_BINS`, `BINS_PER_LEAF`, `TOP_BINS_INDEX_SHIFT`, `LEAF_BINS_INDEX_MASK`, `NUM_LEAF_BINS` | `num_top_bins`, `bins_per_leaf`, `top_bins_index_shift`, `leaf_bins_index_mask`, `num_leaf_bins` | the state comparison reads arrays of these sizes from both |
| `typedef uint8, uint16, uint32` | Zig's `u8`, `u16`, `u32` | |

## Build-time switches

| original | zig-offset-allocator | test |
| --- | --- | --- |
| `NodeIndex = uint32` (default) | `Allocator` (`AllocatorOf(u32)`) | every differential and unit test |
| `#define USE_16_BIT_NODE_INDICES` (`NodeIndex = uint16`) | `Allocator16` (`AllocatorOf(u16)`), both in one build | a second reference build with the define; every differential test runs on both widths, including all 65536 nodes; the shim reports `sizeof(NodeIndex)` of each build |
| `ASSERT(maxAllocs <= 65536)` in 16-bit mode | `assert(max_allocs <= max_max_allocs)` | contract, as in the original |
| `DEBUG` (turns `ASSERT` on) | Zig asserts on the same conditions (on in Debug and ReleaseSafe) | the reference is built with `DEBUG`, so its asserts run under the same calls; the tests run in ReleaseSafe, and pass in Debug too |
| `DEBUG_VERBOSE` (prints freelist and free storage changes) | not ported | debug printing only; it changes no result |
| `USE_16_BIT_OFFSETS` (commented out at the top of the header) | not ported | never defined or read anywhere in the original |
| `_MSC_VER` (`_BitScanReverse`/`_BitScanForward` instead of `__builtin_clz`/`__builtin_ctz`) | `@clz`, `@ctz` | same results; the SmallFloat sweep and the allocator runs cover them |

## SmallFloat

| original | zig-offset-allocator | test |
| --- | --- | --- |
| `SmallFloat::uintToFloatRoundUp` | `small_float.uintToFloatRoundUp` | differential: every u32 (2^32 values, on 16 threads); unit: the original's cases |
| `SmallFloat::uintToFloatRoundDown` | `small_float.uintToFloatRoundDown` | differential: every u32; unit: the original's cases |
| `SmallFloat::floatToUint` | `small_float.floatToUint` | differential: 0 to 263, its whole defined domain (the original shifts by `exponent - 1`, undefined from 264 on; the port asserts below 264); bins 240 to 263 wrap past 32 bits in both; unit: the README's bin table |
| `MANTISSA_BITS`, `MANTISSA_VALUE`, `MANTISSA_MASK` | `small_float.mantissa_bits`, `mantissa_value`, `mantissa_mask` | |
| `findLowestSetBitAfter` (internal) | private `findLowestSetBitAfter`, returning `?u5` for `NO_SPACE` | through every allocate |

These live in the original's `.cpp` without a header declaration (its tests
declare them `extern`); the port makes them public as `small_float`.

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
  allocation for callers that store one.
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
- **The 16-bit reference needs `-Wno-c++11-narrowing`**: the original's
  braced initializers narrow `uint32` into the 16-bit `NodeIndex`, which
  clang rejects by default. The flag keeps C++'s truncation, which the port
  matches (`0xffff` for `NO_SPACE`).

Added in zig-offset-allocator, beyond the original: `max_max_allocs` (the
largest node count each width addresses), and `Allocator16` beside
`Allocator` in one build.

The `Ranges` layer (`src/ranges.zig`: units, byte offsets and
generation-checked handles) is outside the parity scope: it has no
counterpart in the original, and it is built on the core without changing
it, so the comparisons above still cover every line of the translation. Its
own tests are in `test/ranges_test.zig`.
