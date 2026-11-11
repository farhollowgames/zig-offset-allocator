// The original's side of the benchmark: the batches of calls bench/bench.zig
// makes on the port, as C functions over the original allocator.
//
// Each function runs a whole batch, so bench.zig's timing pays one call
// across the language boundary per batch, as it does for the port.
// offsetAllocator.cpp is included rather than linked, so the compiler sees
// the original whole, as Zig sees the port; neither compiler inlines
// allocate or free into the loop.
//
// build.zig compiles this file twice, as it does the test shim: as shipped
// (symbols prefixed oa32_), and with USE_16_BIT_NODE_INDICES, the namespace
// renamed and the symbols prefixed oa16_.

#include <cstdint>

#include "../reference/offset_allocator/offsetAllocator.cpp"

#ifndef OA_PREFIX
#define OA_PREFIX oa32_
#endif
#define OA_CAT2(a, b) a##b
#define OA_CAT(a, b) OA_CAT2(a, b)
#define OA(name) OA_CAT(OA_PREFIX, name)

using OffsetAllocator::Allocation;
using OffsetAllocator::Allocator;
using OffsetAllocator::StorageReportFull;

// Makes the compiler assume that any memory reachable from outside may have
// been read or changed, so a call that repeats, or whose result is only
// stored, is still made each time.
static inline void clobberMemory() { asm volatile("" : : : "memory"); }

extern "C" {

Allocator *OA(create)(uint32_t size, uint32_t max_allocs)
{
    return new Allocator(size, max_allocs);
}

void OA(destroy)(Allocator *allocator) { delete allocator; }

// handles[i] = allocate(sizes[i]).
void OA(allocate_each)(
    Allocator *allocator, const uint32_t *sizes, uint32_t count, Allocation *handles)
{
    for (uint32_t i = 0; i < count; i++) handles[i] = allocator->allocate(sizes[i]);
}

// handles[slots[i]] = allocate(sizes[i]).
void OA(allocate_into)(
    Allocator *allocator,
    const uint32_t *sizes,
    const uint32_t *slots,
    uint32_t count,
    Allocation *handles)
{
    for (uint32_t i = 0; i < count; i++) handles[slots[i]] = allocator->allocate(sizes[i]);
}

// handles[i] = allocate(size).
void OA(allocate_same)(Allocator *allocator, uint32_t size, uint32_t count, Allocation *handles)
{
    for (uint32_t i = 0; i < count; i++) handles[i] = allocator->allocate(size);
}

// free(handles[i]), in order.
void OA(free_each)(Allocator *allocator, const Allocation *handles, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++) allocator->free(handles[i]);
}

// free(handles[slots[i]]).
void OA(free_from)(
    Allocator *allocator, const Allocation *handles, const uint32_t *slots, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++) allocator->free(handles[slots[i]]);
}

void OA(reset_times)(Allocator *allocator, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++)
    {
        allocator->reset();
        clobberMemory();
    }
}

void OA(report_full_times)(Allocator *allocator, uint32_t count, StorageReportFull *report)
{
    for (uint32_t i = 0; i < count; i++)
    {
        *report = allocator->storageReportFull();
        clobberMemory();
    }
}
}
