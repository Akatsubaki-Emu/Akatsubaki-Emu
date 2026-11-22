#include "JIT26Protocol.h"
#include "JITHardwareModel.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>
#endif

#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
static atomic_bool g_txm_script_ready = ATOMIC_VAR_INIT(false);
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

bool iSteamJITHasGetTaskAllow(void) {
    typedef CFTypeRef (*SecTaskCreateFromSelfFunction)(CFAllocatorRef);
    typedef CFTypeRef (*SecTaskCopyValueForEntitlementFunction)(CFTypeRef, CFStringRef, CFErrorRef *);
    SecTaskCreateFromSelfFunction createTask =
        (SecTaskCreateFromSelfFunction)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    SecTaskCopyValueForEntitlementFunction copyEntitlement =
        (SecTaskCopyValueForEntitlementFunction)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (createTask == NULL || copyEntitlement == NULL) return false;

    CFTypeRef task = createTask(kCFAllocatorDefault);
    if (task == NULL) return false;
    CFTypeRef value = copyEntitlement(task, CFSTR("get-task-allow"), NULL);
    bool allowed = value == kCFBooleanTrue;
    if (value != NULL) CFRelease(value);
    CFRelease(task);
    return allowed;
}

static int iSteamJITHardwareTXMMode(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) != 0) return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    if (__builtin_available(iOS 27.0, *)) {
        return iSteamJITHardwareModelTXMModeForOS(systemInfo.machine, true, true);
    }
    if (__builtin_available(iOS 26.0, *)) {
        return iSteamJITHardwareModelTXMModeForOS(systemInfo.machine, false, true);
    }
    return ISTEAM_JIT_PROTOCOL_STANDARD;
}

int iSteamJITGetProtocolMode(void) {
    if (__builtin_available(iOS 26.0, *)) return iSteamJITHardwareTXMMode();
    return ISTEAM_JIT_PROTOCOL_STANDARD;
}

bool iSteamJITIsSupported(void) {
    return iSteamJITGetProtocolMode() == ISTEAM_JIT_PROTOCOL_STIKDEBUG;
}

bool iSteamJITIsDebuggerAttached(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    info.kp_proc.p_flag = 0;
    return sysctl(mib, 4, &info, &size, NULL, 0) == 0
        && size >= sizeof(info)
        && (info.kp_proc.p_flag & P_TRACED) != 0;
}

bool iSteamJITIsReady(void) {
    typedef int (*CSOpsFunction)(pid_t, unsigned int, void *, size_t);
    CSOpsFunction queryStatus = (CSOpsFunction)dlsym(RTLD_DEFAULT, "csops");
    uint32_t status = 0;
    bool hasDebuggedStatus = queryStatus != NULL
        && queryStatus(getpid(), 0, &status, sizeof(status)) == 0
        && (status & UINT32_C(0x10000000)) != 0;
    if (!hasDebuggedStatus) {
        return false;
    }

    if (__builtin_available(iOS 26.0, *)) {
        int protocolMode = iSteamJITGetProtocolMode();
        if (protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN) return false;
        if (protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG) {
            return iSteamJITIsDebuggerAttached()
                && atomic_load_explicit(&g_txm_script_ready, memory_order_acquire);
        }
    }
    return true;
}

void iSteamJITSetTXMScriptReady(bool ready) {
    atomic_store_explicit(&g_txm_script_ready, ready, memory_order_release);
}

void *iSteamJITPrepareRegionIfReady(void *address, size_t length) {
    if (iSteamJITGetProtocolMode() != ISTEAM_JIT_PROTOCOL_STIKDEBUG
        || !iSteamJITIsReady()) return NULL;
    return iSteamJITPrepareRegion(address, length);
}
#else
int iSteamJITGetProtocolMode(void) {
    return ISTEAM_JIT_PROTOCOL_UNKNOWN;
}
bool iSteamJITHasGetTaskAllow(void) { return false; }
void iSteamJITDetach(void) {}
void *iSteamJITPrepareRegion(void *address, size_t length) {
    (void)address;
    (void)length;
    return NULL;
}
bool iSteamJITIsSupported(void) { return false; }
bool iSteamJITIsReady(void) { return false; }
bool iSteamJITIsDebuggerAttached(void) { return false; }
void iSteamJITSetTXMScriptReady(bool ready) { (void)ready; }
void *iSteamJITPrepareRegionIfReady(void *address, size_t length) {
    (void)address;
    (void)length;
    return NULL;
}
#endif
