# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The original

`reference/` holds `offsetAllocator.hpp` and `offsetAllocator.cpp` from
sebbbi/OffsetAllocator at commit `3610a73` (27 March 2023), copied
unmodified, and a C ABI shim written for the tests (see
[`reference/README.md`](../reference/README.md)). `zig build test` builds
the original twice with Zig's clang, as shipped and with
`USE_16_BIT_NODE_INDICES`, both as `-std=c++20 -fno-exceptions -fno-rtti`
with `-DDEBUG -UNDEBUG`: `DEBUG` turns the original's own asserts on, and
`-UNDEBUG` keeps them, since Zig defines `NDEBUG` for C++ in release modes.
A call that breaks one of the original's invariants aborts the reference
too. The shim reads the original's private state, so the tests can compare
it with the port's.

The allocator does no floating-point arithmetic, so every comparison is of
integers.

### Tests and counts

`zig build test` runs 36 tests (`test/differential.zig`,
`test/original_test.zig`, `test/property_test.zig` and
`test/ranges_test.zig`) and, in Debug and ReleaseSafe, 10 runs of the
contract program `test/panic.zig`.

- **Differential runs**: random sequences of allocates and frees, about
  2.07 million calls per node index width: 6 seeds over 7 configurations
  (space running out first, nodes running out first, the whole 32-bit
  range, a 100-unit space, a space that is not a bin size, the fewest
  nodes, an empty space), plus runs with the original's default 131,072
  nodes and with all 65,536 16-bit nodes. Each run fills to exhaustion,
  frees everything back to one region, resets with allocations
  outstanding, and moves the allocator halfway. Sizes include zero, exact
  bin sizes and their neighbours. After every call, the results, both
  storage reports and the bin tables must be identical, and so must every
  node and the freelist (after every call for the small node counts, and
  every few calls for the large ones).
- **Differential fuzzing**: 1,000 seeds per width. Each draws a space
  (empty, a denorm size, a bin's size or one off it, 2^32 - 1 or one or two
  less, or any), a node count from 2 to 4096, and 50 to 400 calls:
  allocates, frees, and at random resets and moves. Requests are 0, 1 to
  16, the largest free region's bin size or one off it, the space or one
  off it, above `0xf000_0000`, a bin's size or one off it, a small share of
  the space, or any size up to it. Every node is compared after every call
  up to 512 nodes, every 8 calls above, and always after a reset or a move.
- **SmallFloat**: both roundings against the original for every u32, and
  `floatToUint` over its whole defined domain (0 to 263).
- **Properties**, against an independent model of the space: no allocation
  overlaps another or runs past the end, `allocate` fails exactly when the
  bin rule says it must, every freed range merges with its free
  neighbours, and freeing everything leaves one region; fixed
  configurations (4 seeds) and 1,000 fuzzed seeds per width.
- **The original's own tests**, translated, for both widths
  (`test/original_test.zig`), and its README's bin size table.
- **`Ranges`**, which has no original: over 4 seeds and 4 configurations
  from 1-byte to 4 KiB units, and 1,000 fuzzed seeds with units from 1 byte
  to 2 GiB, both widths, every offset is a multiple of the unit, no two
  live ranges share a byte (checked against a model of the live ranges),
  and `sizeOf` is at least the request and less than a unit more. A handle
  is not live after a free or a reset, a reused node gets a new generation,
  a 1 TiB space in 1 MiB units hands out ranges past 4 GiB, and requests
  past 2^32 - 1 units fail.

[`STATUS.md`](../STATUS.md) names the tests for every function, option and
build switch of the original.

### Fuzzing

The fuzz seeds are fixed: `0xf022_0000` plus the case number for the
differential fuzzing, `0x9e37_0000` for the properties and `0x7a46_0000`
for `Ranges`, cases 0 to 999. A failure prints the seed and the
configuration of its run, as every random run does. This repository has no
`-Dfuzz-seed` option yet; other seeds need an edit of the test.

### Malformed input and contracts

The allocator takes no encoded input. Its contracts are checked by
`test/panic.zig`, which `zig build test` runs once per case in Debug and
ReleaseSafe, expecting the abort and its message:

- a double free, a free of `Allocation.none`, and 65,537 16-bit nodes abort
  both the port and the original;
- a node index past the nodes and fewer than 2 nodes abort the port, where
  the original's behaviour is undefined;
- a double free and a free after a reset of a `Ranges` handle abort with
  the handle's message.

Zig 0.17 cannot catch a panic inside a test, so `Ranges`' check is also
tested through `checkHandle`. `init` running out of memory is tested to
free what it took, for the core and for `Ranges`.

### Determinism

The library has no threads and no randomness; the differential tests
compare every result and every field of state after the same calls. The
SmallFloat sweep runs on 16 threads only to finish sooner.

### Bugs the tests found and caught

- Three bugs planted on purpose were each caught by the tests.
- The tests found two inputs where the original reads or writes out of
  bounds: fewer than 2 nodes, and `allocationSize` of an empty allocation
  in 16-bit mode with fewer than 65,536 nodes. The port guards them
  ([`STATUS.md`](../STATUS.md#differences-and-why)).

### Build modes

The tests run in ReleaseSafe by default, as CI does (`ubuntu-latest`,
x86-64, Zig 0.17.0), and also pass in Debug (`-Dtest-optimize=Debug`). The
contract program runs only in those two modes, since ReleaseFast removes
the asserts.

### State

`STATUS.md` marks each item as ported, oracle-tested or benchmarked. None is
marked reviewed yet: that state is set at a release, after the review
above.
