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
  interquartile range in brackets, the best median of 10 invocations of
  `zig build bench`.

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
original), 11 November 2026.

**The machine was busy with other builds** during these runs. The numbers
will be taken again on a quiet machine before a release.

## Results, ReleaseFast

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

The port takes less time than the original in every row but churn allocate
with 32-bit indices, 3.9 against 3.8 ns, within the run-to-run spread. The
port's loop also checks every allocation for `error.NoSpace`, where the
original's stores the result unchecked.

## The Ranges layer

The `Ranges` columns get the same requests as the core, the core's already
rounded to units, so the difference is the layer's own work. It costs 0.0
to 1.6 ns per call over the core, and about 1 µs on a reset of 32768 nodes
(the generations). Allocate pays most, for the generation it reads into the
handle.

## Results, ReleaseSafe

The port's asserts and bounds checks on, and the `Ranges` check; the
original still at `-O3` without its asserts. Medians:

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

## The performance pass

The port before and after its performance pass, ReleaseFast. "Before" was
measured in an earlier session on the same machine, whose original numbers
were within 3 percent of these:

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

- The machine was busy (above).
- The port checks every allocation for `error.NoSpace` and the original's
  loop does not, which counts against the port.
- The original runs without its asserts and the port in ReleaseFast without
  its own, so the main table compares unchecked builds; the ReleaseSafe
  table shows the port with its checks against the same unchecked original.
