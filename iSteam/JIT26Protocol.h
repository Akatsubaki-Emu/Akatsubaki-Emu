#ifndef JIT26Protocol_h
#define JIT26Protocol_h
#include <stdbool.h>
#include <stddef.h>
#define ISTEAM_JIT_PROTOCOL_UNKNOWN (-1)
#define ISTEAM_JIT_PROTOCOL_STANDARD 0
#define ISTEAM_JIT_PROTOCOL_STIKDEBUG 1
bool iSteamJITHasGetTaskAllow(void);
int iSteamJITGetProtocolMode(void);
bool iSteamJITIsSupported(void);
bool iSteamJITIsReady(void);
void iSteamJITDetach(void);
void *iSteamJITPrepareRegion(void *address, size_t length);

// Bounded executable storage for Kenran Butō AOT blocks. The implementation
// enforces the platform's JIT/TXM protocol and never exposes a writable
// executable mapping to callers.
typedef struct iSteamAOTExecutableRegion iSteamAOTExecutableRegion;
bool iSteamAOTExecutableMemoryIsAvailable(void);
iSteamAOTExecutableRegion *iSteamAOTExecutableMemoryCreate(
    const void *code, size_t length, char *error, size_t errorCapacity
);
void *iSteamAOTExecutableMemoryEntry(iSteamAOTExecutableRegion *region);
void iSteamAOTExecutableMemoryDestroy(iSteamAOTExecutableRegion *region);
#endif
