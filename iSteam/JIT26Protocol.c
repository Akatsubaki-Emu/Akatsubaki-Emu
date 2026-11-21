#include "JIT26Protocol.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
__attribute__((noinline, optnone, naked))
void iSteamJITDetach(void) {
    __asm__ volatile("mov x16, #0\n"
                     "brk #0xf00d\n"
                     "ret\n");
}
__attribute__((noinline, optnone, naked))
void *iSteamJITPrepareRegion(void *address, size_t length) {
    __asm__ volatile("mov x16, #1\n"
                     "brk #0xf00d\n"
                     "ret\n");
}
bool iSteamJITIsSupported(void) { return true; }

bool iSteamJITIsReady(void) {
    typedef int (*CSOpsFunction)(pid_t, unsigned int, void *, size_t);
    CSOpsFunction queryStatus = (CSOpsFunction)dlsym(RTLD_DEFAULT, "csops");
    uint32_t status = 0;
    return queryStatus != NULL
        && queryStatus(getpid(), 0, &status, sizeof(status)) == 0
        && (status & UINT32_C(0x10000000)) != 0;
}
#else
void iSteamJITDetach(void) {}
void *iSteamJITPrepareRegion(void *address, size_t length) {
    (void)address;
    (void)length;
    return NULL;
}
bool iSteamJITIsSupported(void) { return false; }
bool iSteamJITIsReady(void) { return false; }
#endif
