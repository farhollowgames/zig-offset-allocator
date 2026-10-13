# Reference sources (test-only)

The original allocator, built only by `zig build test` as the oracle for the
differential tests. Nothing here is part of the `offset_allocator` package
(see the `paths` in `build.zig.zon`). The original files are copied
unmodified.

| directory | source | version | licence |
| --- | --- | --- | --- |
| `offset_allocator/` | `offsetAllocator.{cpp,hpp}` from [sebbbi/OffsetAllocator](https://github.com/sebbbi/OffsetAllocator) | commit `3610a73` (27 March 2023) | MIT (`offset_allocator/LICENSE`) |
| `shim/` | a C ABI over the allocator, written for the tests | | Apache 2.0, as the repository |

The shim includes `offsetAllocator.cpp` instead of compiling it alone: the
`SmallFloat` functions are defined only there, and the tests read the
allocator's private state (with `#define private public`, test-only) to
compare every field with the port's after every call. `build.zig` compiles
the shim twice, once as shipped and once with `USE_16_BIT_NODE_INDICES`.

The 16-bit build needs `-Wno-c++11-narrowing`: the original narrows `uint32`
values into the 16-bit `NodeIndex` inside braced initializers
(`.metadata = Allocation::NO_SPACE`, `.metadata = nodeIndex`), which clang
rejects by default. The flag keeps C++'s conversion (truncation to 16 bits),
which is what the original means and what the port does.

Both builds define `DEBUG`, which turns on the original's own asserts, so a
sequence that breaks one of its invariants fails the reference as well.
