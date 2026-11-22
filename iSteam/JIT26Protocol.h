#ifndef JIT26Protocol_h
#define JIT26Protocol_h
#include <stdbool.h>
#include <stddef.h>
#define ISTEAM_JIT_PROTOCOL_UNKNOWN (-1)
#define ISTEAM_JIT_PROTOCOL_STANDARD 0
#define ISTEAM_JIT_PROTOCOL_STIKDEBUG 1
bool iSteamJITHasGetTaskAllow(void);
int iSteamJITGetProtocolMode(void);
void iSteamJITSetProtocolOverride(int protocolMode);
bool iSteamJITIsSupported(void);
bool iSteamJITIsReady(void);
void iSteamJITDetach(void);
void *iSteamJITPrepareRegion(void *address, size_t length);
#endif
