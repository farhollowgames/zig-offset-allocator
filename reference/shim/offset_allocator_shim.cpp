// Test-only: a C ABI over OffsetAllocator, the oracle for the Zig port.
//
// offsetAllocator.cpp is included, not compiled on its own, so that the
// SmallFloat functions (defined only in the .cpp) are reachable, and so that
// the allocator's private state can be read: the differential tests compare
// every field of both allocators after every call, not only the results.
//
// build.zig compiles this file twice: once as shipped (32-bit node indices,
// symbols prefixed oa32_), and once with USE_16_BIT_NODE_INDICES, the
// namespace renamed to OffsetAllocator16 and the symbols prefixed oa16_, so
// both builds link into one test binary.

#include <cstring>
#include <cstdint>
#include <new>
#include <utility>
#ifdef DEBUG
#include <assert.h>
#endif

// Test-only access to the allocator's private state. The original source is
// unmodified.
#define private public
#include "../offset_allocator/offsetAllocator.cpp"
#undef private

#ifndef OA_PREFIX
#define OA_PREFIX oa32_
#endif
#define OA_CAT2(a, b) a##b
#define OA_CAT(a, b) OA_CAT2(a, b)
#define OA(name) OA_CAT(OA_PREFIX, name)

using OffsetAllocator::Allocation;
using OffsetAllocator::Allocator;
using OffsetAllocator::NodeIndex;

static Allocation toAllocation(uint32_t offset, uint32_t metadata)
{
    Allocation a;
    a.offset = offset;
    a.metadata = (NodeIndex)metadata;
    return a;
}

extern "C" {

uint32_t OA(node_index_bytes)(void) { return sizeof(NodeIndex); }

uint32_t OA(uint_to_float_round_up)(uint32_t size) { return OffsetAllocator::SmallFloat::uintToFloatRoundUp(size); }
uint32_t OA(uint_to_float_round_down)(uint32_t size) { return OffsetAllocator::SmallFloat::uintToFloatRoundDown(size); }
uint32_t OA(float_to_uint)(uint32_t value) { return OffsetAllocator::SmallFloat::floatToUint(value); }

void *OA(create)(uint32_t size, uint32_t max_allocs) { return new Allocator(size, max_allocs); }

// The C++ default argument: maxAllocs = 128 * 1024.
void *OA(create_default)(uint32_t size) { return new Allocator(size); }

// Move-constructs a new allocator from `other` (the C++ move constructor)
// and returns it; `other` stays alive in its moved-from state.
void *OA(move)(void *other) { return new Allocator(std::move(*(Allocator *)other)); }

void OA(destroy)(void *a) { delete (Allocator *)a; }

void OA(reset)(void *a) { ((Allocator *)a)->reset(); }

void OA(allocate)(void *a, uint32_t size, uint32_t *offset, uint32_t *metadata)
{
    Allocation r = ((Allocator *)a)->allocate(size);
    *offset = r.offset;
    *metadata = r.metadata;
}

void OA(free)(void *a, uint32_t offset, uint32_t metadata) { ((Allocator *)a)->free(toAllocation(offset, metadata)); }

uint32_t OA(allocation_size)(void *a, uint32_t offset, uint32_t metadata)
{
    return ((Allocator *)a)->allocationSize(toAllocation(offset, metadata));
}

void OA(storage_report)(void *a, uint32_t out[2])
{
    OffsetAllocator::StorageReport r = ((Allocator *)a)->storageReport();
    out[0] = r.totalFreeSpace;
    out[1] = r.largestFreeRegion;
}

// out: NUM_LEAF_BINS pairs of (size, count).
void OA(storage_report_full)(void *a, uint32_t *out)
{
    OffsetAllocator::StorageReportFull r = ((Allocator *)a)->storageReportFull();
    for (uint32_t i = 0; i < OffsetAllocator::NUM_LEAF_BINS; i++)
    {
        out[2 * i] = r.freeRegions[i].size;
        out[2 * i + 1] = r.freeRegions[i].count;
    }
}

// The allocator's private scalar state and bin tables.
// scalars: size, maxAllocs, freeStorage, usedBinsTop, freeOffset.
void OA(state)(void *a, uint32_t scalars[5], uint8_t used_bins[32], uint32_t bin_indices[256])
{
    Allocator *al = (Allocator *)a;
    scalars[0] = al->m_size;
    scalars[1] = al->m_maxAllocs;
    scalars[2] = al->m_freeStorage;
    scalars[3] = al->m_usedBinsTop;
    scalars[4] = al->m_freeOffset;
    for (uint32_t i = 0; i < OffsetAllocator::NUM_TOP_BINS; i++) used_bins[i] = al->m_usedBins[i];
    for (uint32_t i = 0; i < OffsetAllocator::NUM_LEAF_BINS; i++) bin_indices[i] = al->m_binIndices[i];
}

// Node i: dataOffset, dataSize, binListPrev, binListNext, neighborPrev,
// neighborNext, used.
void OA(node)(void *a, uint32_t i, uint32_t out[7])
{
    const Allocator::Node &n = ((Allocator *)a)->m_nodes[i];
    out[0] = n.dataOffset;
    out[1] = n.dataSize;
    out[2] = n.binListPrev;
    out[3] = n.binListNext;
    out[4] = n.neighborPrev;
    out[5] = n.neighborNext;
    out[6] = n.used ? 1 : 0;
}

uint32_t OA(free_node)(void *a, uint32_t i) { return ((Allocator *)a)->m_freeNodes[i]; }

}
