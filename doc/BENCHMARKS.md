# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

## Method

`zig build bench` runs the original, the port and the `Ranges` layer on the
same requests.

- **The port**: ReleaseFast, for the native CPU, unless
  `-Dbench-optimize` says otherwise.
- **The original**: Zig's clang, `-std=c++20 -O3 -fno-exceptions
  -fno-rtti`, for the same CPU, with its asserts off.
- **Calls**: each side makes its calls from its own language, one call
  across per batch, and neither compiler inlines allocate or free into the
  loop. The handles every side returns are kept and must be the same, so no
  side can skip work.
- **Runs**: every side runs once to warm up, then the runs rotate the order
  of the sides. Times are ns per call: the median of 11 runs with the
  interquartile range in brackets.
- **Invocations**: `zig build bench` ran three times for each table. Each
  row is from the invocation with the median port / original ratio, and
  the "3 runs" column gives the three invocations' ratios, lowest to
  highest.

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

## Command

```sh
zig build bench                        # 11 runs of every workload
zig build bench -- <runs> <workload>   # workload: steady, fill_free, churn,
                                       # reset or report_full
zig build bench -Dbench-optimize=ReleaseSafe
zig build bench -Dbench-cpu=2          # pin to one CPU with taskset (Linux)
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (and its clang for the
original), 11 November 2026, at commit `bb82860`. The one-minute load
average was 2.8 during the runs, on 32 hardware threads.

## Results, ReleaseFast

| workload | op | node index | original | port | port / original | 3 runs | Ranges | Ranges / port |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | u32 | 11.0 (10.9–11.1) | 9.3 (9.2–9.3) | 0.84 | 0.84–0.84 | 10.7 (10.6–10.7) | 1.15 |
| steady state | free | u32 | 13.7 (13.7–13.7) | 13.1 (13.0–13.1) | 0.96 | 0.95–0.96 | 13.7 (13.7–13.7) | 1.05 |
| steady state | allocate | u16 | 10.8 (10.8–10.8) | 8.5 (8.5–8.6) | 0.79 | 0.79–0.79 | 10.1 (10.1–10.1) | 1.18 |
| steady state | free | u16 | 13.0 (13.0–13.1) | 12.2 (12.2–12.2) | 0.94 | 0.94–0.94 | 12.9 (12.9–13.0) | 1.06 |
| fill, free all | allocate | u32 | 4.5 (4.5–4.5) | 4.3 (4.3–4.3) | 0.95 | 0.95–0.96 | 5.0 (5.0–5.0) | 1.17 |
| fill, free all | free | u32 | 8.2 (8.1–8.6) | 7.8 (7.8–8.2) | 0.96 | 0.96–0.96 | 8.7 (8.5–9.0) | 1.11 |
| fill, free all | allocate | u16 | 7.1 (7.1–7.1) | 5.0 (5.0–5.1) | 0.71 | 0.71–0.71 | 5.9 (5.9–5.9) | 1.17 |
| fill, free all | free | u16 | 7.1 (7.0–7.6) | 6.8 (6.7–7.1) | 0.96 | 0.95–0.97 | 7.2 (7.1–7.6) | 1.06 |
| churn | allocate | u32 | 3.9 (3.8–3.9) | 4.0 (4.0–4.0) | 1.04 | 1.04–1.04 | 4.8 (4.7–4.8) | 1.18 |
| churn | free | u32 | 5.0 (5.0–5.1) | 4.6 (4.6–4.6) | 0.91 | 0.91–0.92 | 4.6 (4.6–4.6) | 1.01 |
| churn | allocate | u16 | 7.1 (7.1–7.1) | 5.1 (5.0–5.1) | 0.71 | 0.71–0.72 | 5.6 (5.5–5.6) | 1.10 |
| churn | free | u16 | 5.7 (5.7–5.7) | 4.5 (4.5–4.5) | 0.79 | 0.79–0.80 | 4.7 (4.7–4.7) | 1.03 |
| reset | reset | u32 | 12014 (11974–12050) | 6092 (6072–6209) | 0.51 | 0.51–0.51 | 7151 (7140–7240) | 1.17 |
| reset | reset | u16 | 10975 (10941–11025) | 3270 (3251–3316) | 0.30 | 0.30–0.30 | 4274 (4255–4318) | 1.31 |
| storageReportFull | report | u32 | 14301 (14178–14397) | 13620 (13579–13645) | 0.95 | 0.95–0.95 | 13692 (13650–13725) | 1.01 |
| storageReportFull | report | u16 | 12207 (12119–12266) | 11861 (11764–11882) | 0.97 | 0.97–0.97 | 12385 (12329–12516) | 1.04 |

The port takes less time than the original in every row but churn allocate
with 32-bit indices, 4.0 against 3.9 ns (1.04 in all three invocations).
The port's loop also checks every allocation for `error.NoSpace`, where
the original's stores the result unchecked.

## The Ranges layer

The `Ranges` columns get the same requests as the core, the core's already
rounded to units, so the difference is the layer's own work. It costs 0.0
to 1.6 ns per call over the core, and about 1 µs on a reset of 32768 nodes
(the generations). Allocate pays most, for the generation it reads into the
handle.

The 16-bit `Ranges` reset moved the most between invocations, from 4.0 to
5.0 µs, against 3.3 µs for the core's; earlier runs had it at 3.9 µs.

## Results, ReleaseSafe

The port's asserts and bounds checks on, and the `Ranges` check; the
original still at `-O3` without its asserts. Medians:

| workload | op | node index | original | port | port / original | 3 runs | Ranges | Ranges / port |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| steady state | allocate | u32 | 10.9 | 11.0 | 1.00 | 1.00–1.01 | 12.3 | 1.12 |
| steady state | free | u32 | 14.3 | 16.7 | 1.17 | 1.17–1.17 | 18.0 | 1.08 |
| steady state | allocate | u16 | 10.7 | 9.9 | 0.92 | 0.92–0.92 | 11.4 | 1.15 |
| steady state | free | u16 | 12.4 | 14.8 | 1.19 | 1.19–1.19 | 16.0 | 1.09 |
| fill, free all | allocate | u32 | 4.5 | 5.6 | 1.25 | 1.25–1.27 | 6.6 | 1.17 |
| fill, free all | free | u32 | 8.5 | 11.9 | 1.40 | 1.30–1.40 | 13.3 | 1.12 |
| fill, free all | allocate | u16 | 7.1 | 7.4 | 1.04 | 1.04–1.04 | 7.8 | 1.05 |
| fill, free all | free | u16 | 7.2 | 10.5 | 1.47 | 1.44–1.48 | 11.4 | 1.08 |
| churn | allocate | u32 | 3.9 | 5.8 | 1.49 | 1.44–1.50 | 6.4 | 1.12 |
| churn | free | u32 | 5.1 | 6.7 | 1.32 | 1.32–1.38 | 7.2 | 1.07 |
| churn | allocate | u16 | 7.0 | 7.4 | 1.04 | 1.04–1.04 | 7.5 | 1.02 |
| churn | free | u16 | 5.8 | 7.7 | 1.34 | 1.32–1.35 | 7.9 | 1.03 |
| reset | reset | u32 | 12239 | 6485 | 0.53 | 0.51–0.54 | 7588 | 1.17 |
| reset | reset | u16 | 11011 | 3825 | 0.35 | 0.35–0.36 | 4723 | 1.24 |
| storageReportFull | report | u32 | 14108 | 12705 | 0.90 | 0.90–0.91 | 12811 | 1.01 |
| storageReportFull | report | u16 | 12175 | 9822 | 0.81 | 0.80–0.81 | 9984 | 1.02 |

`storageReportFull` comes out faster in ReleaseSafe than in ReleaseFast on
this machine; the two modes lay out its list walk differently.

## The performance pass

The port before and after its performance pass, ReleaseFast, measured
during the pass, before the tables above. "Before" was measured in an
earlier session on the same machine, whose original numbers were within 3
percent of the "after" session's:

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

## Known biases

- The port checks every allocation for `error.NoSpace` and the original's
  loop does not, which counts against the port.
- The original runs without its asserts and the port in ReleaseFast without
  its own, so the main table compares unchecked builds; the ReleaseSafe
  table shows the port with its checks against the same unchecked original.
