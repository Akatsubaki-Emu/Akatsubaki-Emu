#ifndef AKATSUBAKI_AOT_EXECUTABLE_ARENA_H
#define AKATSUBAKI_AOT_EXECUTABLE_ARENA_H

#include <stdbool.h>
#include <stddef.h>

typedef struct iSteamAOTExecutableArena iSteamAOTExecutableArena;

iSteamAOTExecutableArena *iSteamAOTExecutableArenaCreate(size_t capacity);
bool iSteamAOTExecutableArenaAllocate(iSteamAOTExecutableArena *arena, size_t size, size_t alignment, size_t *offset);
bool iSteamAOTExecutableArenaFree(iSteamAOTExecutableArena *arena, size_t offset, size_t size);
size_t iSteamAOTExecutableArenaFreeBytes(iSteamAOTExecutableArena *arena);
void iSteamAOTExecutableArenaDestroy(iSteamAOTExecutableArena *arena);

#endif
