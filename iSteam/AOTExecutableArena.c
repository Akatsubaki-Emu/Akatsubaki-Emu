#include "AOTExecutableArena.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct iSteamAOTExecutableFreeRange {
    size_t offset;
    size_t size;
    struct iSteamAOTExecutableFreeRange *next;
} iSteamAOTExecutableFreeRange;

typedef struct iSteamAOTExecutableAllocation {
    size_t offset;
    size_t size;
    struct iSteamAOTExecutableAllocation *next;
} iSteamAOTExecutableAllocation;

struct iSteamAOTExecutableArena {
    size_t capacity;
    iSteamAOTExecutableFreeRange *free_ranges;
    iSteamAOTExecutableAllocation *allocations;
    pthread_mutex_t lock;
};

static bool align_up(size_t value, size_t alignment, size_t *result) {
    if (!alignment || !result) return false;
    size_t remainder = value % alignment;
    size_t padding = remainder ? alignment - remainder : 0;
    if (value > SIZE_MAX - padding) return false;
    *result = value + padding;
    return true;
}

iSteamAOTExecutableArena *iSteamAOTExecutableArenaCreate(size_t capacity) {
    if (!capacity) return NULL;
    iSteamAOTExecutableArena *arena = calloc(1, sizeof(*arena));
    if (!arena) return NULL;
    iSteamAOTExecutableFreeRange *initial = calloc(1, sizeof(*initial));
    if (!initial) {
        free(arena);
        return NULL;
    }
    if (pthread_mutex_init(&arena->lock, NULL) != 0) {
        free(initial);
        free(arena);
        return NULL;
    }
    arena->capacity = capacity;
    initial->size = capacity;
    arena->free_ranges = initial;
    return arena;
}

bool iSteamAOTExecutableArenaAllocate(iSteamAOTExecutableArena *arena,
                                      size_t size,
                                      size_t alignment,
                                      size_t *offset) {
    if (!arena || !size || !alignment || !offset) return false;
    iSteamAOTExecutableAllocation *allocation = calloc(1, sizeof(*allocation));
    if (!allocation) return false;
    if (pthread_mutex_lock(&arena->lock) != 0) {
        free(allocation);
        return false;
    }

    iSteamAOTExecutableFreeRange **cursor = &arena->free_ranges;
    while (*cursor) {
        iSteamAOTExecutableFreeRange *range = *cursor;
        size_t start = 0;
        if (!align_up(range->offset, alignment, &start) || start < range->offset ||
            start > arena->capacity || size > arena->capacity - start) {
            cursor = &range->next;
            continue;
        }
        size_t range_end = range->offset + range->size;
        if (start > range_end || size > range_end - start) {
            cursor = &range->next;
            continue;
        }

        size_t prefix = start - range->offset;
        size_t allocated_end = start + size;
        size_t suffix = range_end - allocated_end;
        if (prefix && suffix) {
            iSteamAOTExecutableFreeRange *tail = calloc(1, sizeof(*tail));
            if (!tail) {
                pthread_mutex_unlock(&arena->lock);
                free(allocation);
                return false;
            }
            tail->offset = allocated_end;
            tail->size = suffix;
            tail->next = range->next;
            range->size = prefix;
            range->next = tail;
        } else if (prefix) {
            range->size = prefix;
        } else if (suffix) {
            range->offset = allocated_end;
            range->size = suffix;
        } else {
            *cursor = range->next;
            free(range);
        }
        allocation->offset = start;
        allocation->size = size;
        allocation->next = arena->allocations;
        arena->allocations = allocation;
        *offset = start;
        pthread_mutex_unlock(&arena->lock);
        return true;
    }

    pthread_mutex_unlock(&arena->lock);
    free(allocation);
    return false;
}

bool iSteamAOTExecutableArenaFree(iSteamAOTExecutableArena *arena,
                                  size_t offset,
                                  size_t size) {
    if (!arena || !size || offset > arena->capacity || size > arena->capacity - offset)
        return false;
    size_t end = offset + size;
    if (pthread_mutex_lock(&arena->lock) != 0) return false;

    /* Only an exact live allocation may be returned; partial and forged frees corrupt the arena. */
    iSteamAOTExecutableAllocation **allocation_cursor = &arena->allocations;
    while (*allocation_cursor &&
           ((*allocation_cursor)->offset != offset || (*allocation_cursor)->size != size)) {
        allocation_cursor = &(*allocation_cursor)->next;
    }
    if (!*allocation_cursor) {
        pthread_mutex_unlock(&arena->lock);
        return false;
    }

    iSteamAOTExecutableFreeRange **cursor = &arena->free_ranges;
    iSteamAOTExecutableFreeRange *previous = NULL;
    while (*cursor && (*cursor)->offset < offset) {
        previous = *cursor;
        cursor = &(*cursor)->next;
    }
    iSteamAOTExecutableFreeRange *next = *cursor;
    if ((previous && previous->size > offset - previous->offset) ||
        (next && end > next->offset)) {
        pthread_mutex_unlock(&arena->lock);
        return false;
    }

    iSteamAOTExecutableFreeRange *released = calloc(1, sizeof(*released));
    if (!released) {
        pthread_mutex_unlock(&arena->lock);
        return false;
    }
    released->offset = offset;
    released->size = size;
    released->next = next;
    *cursor = released;

    if (previous && previous->offset + previous->size == released->offset) {
        previous->size += released->size;
        previous->next = released->next;
        free(released);
        released = previous;
    }
    if (released->next && released->offset + released->size == released->next->offset) {
        iSteamAOTExecutableFreeRange *following = released->next;
        released->size += following->size;
        released->next = following->next;
        free(following);
    }

    iSteamAOTExecutableAllocation *allocation = *allocation_cursor;
    *allocation_cursor = allocation->next;
    free(allocation);
    pthread_mutex_unlock(&arena->lock);
    return true;
}

size_t iSteamAOTExecutableArenaFreeBytes(iSteamAOTExecutableArena *arena) {
    if (!arena || pthread_mutex_lock(&arena->lock) != 0) return 0;
    size_t total = 0;
    for (iSteamAOTExecutableFreeRange *range = arena->free_ranges; range; range = range->next) {
        if (range->size > SIZE_MAX - total) {
            total = SIZE_MAX;
            break;
        }
        total += range->size;
    }
    pthread_mutex_unlock(&arena->lock);
    return total;
}

void iSteamAOTExecutableArenaDestroy(iSteamAOTExecutableArena *arena) {
    if (!arena) return;
    iSteamAOTExecutableFreeRange *range = arena->free_ranges;
    while (range) {
        iSteamAOTExecutableFreeRange *next = range->next;
        free(range);
        range = next;
    }
    iSteamAOTExecutableAllocation *allocation = arena->allocations;
    while (allocation) {
        iSteamAOTExecutableAllocation *next = allocation->next;
        free(allocation);
        allocation = next;
    }
    pthread_mutex_destroy(&arena->lock);
    free(arena);
}
