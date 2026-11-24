#include "AOTExecutableArena.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define KiB 1024u

static void test_alignment_fragmentation_and_coalescing(void) {
    const size_t capacity = 64u * KiB;
    iSteamAOTExecutableArena *arena = iSteamAOTExecutableArenaCreate(capacity);
    assert(arena);
    size_t a = 0, b = 0, c = 0, d = 0, ignored = 0;
    assert(iSteamAOTExecutableArenaAllocate(arena, 8u * KiB, 4u * KiB, &a) && a == 0);
    assert(iSteamAOTExecutableArenaAllocate(arena, 16u * KiB, 16u * KiB, &b) && b == 16u * KiB);
    assert(iSteamAOTExecutableArenaAllocate(arena, 8u * KiB, 4u * KiB, &c) && c == 8u * KiB);
    assert(iSteamAOTExecutableArenaAllocate(arena, 32u * KiB, 16u * KiB, &d) && d == 32u * KiB);
    assert(!iSteamAOTExecutableArenaAllocate(arena, 4u * KiB, 4u * KiB, &ignored));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == 0);
    assert(iSteamAOTExecutableArenaFree(arena, b, 16u * KiB));
    assert(iSteamAOTExecutableArenaFree(arena, a, 8u * KiB));
    assert(iSteamAOTExecutableArenaFree(arena, c, 8u * KiB));
    assert(iSteamAOTExecutableArenaFree(arena, d, 32u * KiB));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == capacity);
    assert(!iSteamAOTExecutableArenaFree(arena, d, 32u * KiB));
    assert(iSteamAOTExecutableArenaAllocate(arena, capacity, 16u * KiB, &ignored));
    assert(ignored == 0);
    assert(iSteamAOTExecutableArenaFree(arena, ignored, capacity));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == capacity);
    iSteamAOTExecutableArenaDestroy(arena);
}

typedef struct { iSteamAOTExecutableArena *arena; size_t *offsets; size_t start; size_t count; } ThreadArgs;
static void *allocate_many(void *raw) {
    ThreadArgs *args = raw;
    for (size_t i = 0; i < args->count; ++i) {
        size_t offset = SIZE_MAX;
        assert(iSteamAOTExecutableArenaAllocate(args->arena, 16u * KiB, 16u * KiB, &offset));
        args->offsets[args->start + i] = offset;
    }
    return NULL;
}
static int compare_size_t(const void *a, const void *b) {
    size_t x = *(const size_t *)a, y = *(const size_t *)b;
    return (x > y) - (x < y);
}
static void test_concurrent_allocations_do_not_overlap(void) {
    enum { THREADS = 4, PER_THREAD = 64 };
    const size_t total = THREADS * PER_THREAD;
    iSteamAOTExecutableArena *arena = iSteamAOTExecutableArenaCreate(total * 16u * KiB);
    assert(arena);
    size_t *offsets = calloc(total, sizeof(*offsets));
    assert(offsets);
    pthread_t threads[THREADS];
    ThreadArgs args[THREADS];
    for (size_t i = 0; i < THREADS; ++i) {
        args[i] = (ThreadArgs){arena, offsets, i * PER_THREAD, PER_THREAD};
        assert(pthread_create(&threads[i], NULL, allocate_many, &args[i]) == 0);
    }
    for (size_t i = 0; i < THREADS; ++i) assert(pthread_join(threads[i], NULL) == 0);
    qsort(offsets, total, sizeof(*offsets), compare_size_t);
    for (size_t i = 0; i < total; ++i) {
        assert(offsets[i] % (16u * KiB) == 0);
        if (i) assert(offsets[i] - offsets[i - 1] == 16u * KiB);
    }
    for (size_t i = 0; i < total; ++i)
        assert(iSteamAOTExecutableArenaFree(arena, offsets[i], 16u * KiB));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == total * 16u * KiB);
    free(offsets);
    iSteamAOTExecutableArenaDestroy(arena);
}

static void test_partial_and_wrong_size_frees_are_rejected(void) {
    iSteamAOTExecutableArena *arena = iSteamAOTExecutableArenaCreate(32u * KiB);
    assert(arena);
    size_t offset = 0;
    assert(!iSteamAOTExecutableArenaFree(arena, 0, 4u * KiB));
    assert(iSteamAOTExecutableArenaAllocate(arena, 8u * KiB, 4u * KiB, &offset));
    assert(!iSteamAOTExecutableArenaFree(arena, offset, 4u * KiB));
    assert(!iSteamAOTExecutableArenaFree(arena, offset + 4u * KiB, 4u * KiB));
    assert(!iSteamAOTExecutableArenaFree(arena, offset, 12u * KiB));
    assert(iSteamAOTExecutableArenaFree(arena, offset, 8u * KiB));
    assert(!iSteamAOTExecutableArenaFree(arena, offset, 8u * KiB));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == 32u * KiB);
    iSteamAOTExecutableArenaDestroy(arena);
}

static void test_invalid_and_overflow_requests_fail(void) {
    iSteamAOTExecutableArena *arena = iSteamAOTExecutableArenaCreate(32u * KiB);
    assert(arena);
    size_t offset = 0;
    assert(!iSteamAOTExecutableArenaAllocate(arena, 1, 0, &offset));
    assert(!iSteamAOTExecutableArenaAllocate(arena, 0, 1, &offset));
    assert(!iSteamAOTExecutableArenaAllocate(arena, 33u * KiB, 1, &offset));
    assert(!iSteamAOTExecutableArenaFree(arena, SIZE_MAX - 1, 8));
    assert(!iSteamAOTExecutableArenaFree(arena, 0, 33u * KiB));
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == 32u * KiB);
    iSteamAOTExecutableArenaDestroy(arena);
}

typedef struct {
    size_t offset;
    size_t size;
    bool active;
} AllocationSlot;

static uint32_t next_random(uint32_t *state) {
    uint32_t value = *state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

static void test_randomized_allocation_and_free_stress(void) {
    enum { SLOT_COUNT = 256, OPERATIONS = 20000 };
    const size_t capacity = 8u * 1024u * 1024u;
    iSteamAOTExecutableArena *arena = iSteamAOTExecutableArenaCreate(capacity);
    assert(arena);
    AllocationSlot slots[SLOT_COUNT] = {0};
    uint32_t random_state = 0x6b656e72u;

    for (size_t operation = 0; operation < OPERATIONS; ++operation) {
        size_t index = next_random(&random_state) % SLOT_COUNT;
        AllocationSlot *slot = &slots[index];
        if (slot->active) {
            assert(iSteamAOTExecutableArenaFree(arena, slot->offset, slot->size));
            slot->active = false;
        } else {
            size_t size = ((next_random(&random_state) % 8u) + 1u) * 4096u;
            size_t alignment = 4096u << (next_random(&random_state) % 3u);
            size_t offset = SIZE_MAX;
            if (iSteamAOTExecutableArenaAllocate(arena, size, alignment, &offset)) {
                assert(offset % alignment == 0);
                for (size_t other = 0; other < SLOT_COUNT; ++other) {
                    if (!slots[other].active) continue;
                    size_t other_end = slots[other].offset + slots[other].size;
                    size_t allocation_end = offset + size;
                    assert(allocation_end <= slots[other].offset || other_end <= offset);
                }
                *slot = (AllocationSlot){offset, size, true};
            }
        }
        assert(iSteamAOTExecutableArenaFreeBytes(arena) <= capacity);
    }

    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        if (slots[i].active)
            assert(iSteamAOTExecutableArenaFree(arena, slots[i].offset, slots[i].size));
    }
    assert(iSteamAOTExecutableArenaFreeBytes(arena) == capacity);
    iSteamAOTExecutableArenaDestroy(arena);
}

int main(void) {
    test_alignment_fragmentation_and_coalescing();
    test_concurrent_allocations_do_not_overlap();
    test_invalid_and_overflow_requests_fail();
    test_partial_and_wrong_size_frees_are_rejected();
    test_randomized_allocation_and_free_stress();
    puts("Kenran Butō executable arena allocator tests passed (5 suites, 20,000 stress operations)");
    return 0;
}
