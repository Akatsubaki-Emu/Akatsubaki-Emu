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


#ifdef __cplusplus
extern "C" {
#endif
#define KENRAN_BUTO_AOT_ABI_VERSION 1u
enum {
 KENRAN_BUTO_AOT_EXIT_NONE=0, KENRAN_BUTO_AOT_EXIT_UNSUPPORTED_INSTRUCTION=1,
 KENRAN_BUTO_AOT_EXIT_TRUNCATED_INSTRUCTION=2, KENRAN_BUTO_AOT_EXIT_INPUT_LIMIT=3,
 KENRAN_BUTO_AOT_EXIT_INSTRUCTION_LIMIT=4, KENRAN_BUTO_AOT_EXIT_OUTPUT_LIMIT=5,
 KENRAN_BUTO_AOT_EXIT_END_OF_INPUT=6, KENRAN_BUTO_AOT_EXIT_MEMORY_READ_FAULT=7,
 KENRAN_BUTO_AOT_EXIT_MEMORY_WRITE_FAULT=8, KENRAN_BUTO_AOT_EXIT_INVALID_STATE=9
};
typedef bool (*KenranButoAOTMemoryReadCallback)(void *, uint64_t, void *, size_t);
typedef bool (*KenranButoAOTMemoryWriteCallback)(void *, uint64_t, const void *, size_t);
typedef struct KenranButoAOTMemoryCallbacks {
 uint32_t abi_version; uint32_t struct_size; void *context;
 KenranButoAOTMemoryReadCallback read_memory; KenranButoAOTMemoryWriteCallback write_memory;
} KenranButoAOTMemoryCallbacks;
typedef struct KenranButoAOTGuestState {
 uint32_t abi_version; uint32_t struct_size; uint64_t *gpr;
 uint64_t rip; uint64_t rflags; uint64_t fs_base; uint64_t gs_base;
 const KenranButoAOTMemoryCallbacks *memory; uint64_t instruction_budget;
 uint64_t instructions_executed; uint64_t exit_rip; uint64_t exit_address;
 uint32_t exit_reason; uint32_t reserved;
} KenranButoAOTGuestState;
typedef struct iSteamAOTExecutableRegion iSteamAOTExecutableRegion;
bool iSteamAOTExecutableMemoryIsAvailable(void);
iSteamAOTExecutableRegion *iSteamAOTExecutableMemoryCreate(const void *, size_t, char *, size_t);
bool iSteamAOTExecutableMemoryInvoke(iSteamAOTExecutableRegion *, KenranButoAOTGuestState *);
void iSteamAOTExecutableMemoryDestroy(iSteamAOTExecutableRegion *);
bool iSteamAOTGuestStateInitialize(KenranButoAOTGuestState *, uint64_t *, uint64_t, uint64_t,
 uint64_t, uint64_t, const KenranButoAOTMemoryCallbacks *, uint64_t);
bool iSteamAOTGuestStateIsValid(const KenranButoAOTGuestState *);
bool iSteamAOTGuestMemoryRead(KenranButoAOTGuestState *, uint64_t, void *, size_t);
bool iSteamAOTGuestMemoryWrite(KenranButoAOTGuestState *, uint64_t, const void *, size_t);
#ifdef __cplusplus
}
#endif

#endif
