#include "JIT26Protocol.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
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

static int iSteamJITHardwareTXMMode(const char *hardwareIdentifier, bool isIOS27OrNewer) {
    if (hardwareIdentifier == NULL || hardwareIdentifier[0] == '\0') {
        return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    }

    if (isIOS27OrNewer) {
        return strcmp(hardwareIdentifier, "iPad8,11") == 0
            || strcmp(hardwareIdentifier, "iPad8,12") == 0
            ? ISTEAM_JIT_PROTOCOL_STANDARD
            : ISTEAM_JIT_PROTOCOL_STIKDEBUG;
    }

    int major = 0;
    int minor = 0;
    if (sscanf(hardwareIdentifier, "iPhone%d,%d", &major, &minor) == 2) {
        return major > 14 || (major == 14 && minor >= 2)
            ? ISTEAM_JIT_PROTOCOL_STIKDEBUG
            : ISTEAM_JIT_PROTOCOL_STANDARD;
    }
    if (sscanf(hardwareIdentifier, "iPad%d,%d", &major, &minor) == 2) {
        return major > 14 || (major == 14 && minor >= 5)
            ? ISTEAM_JIT_PROTOCOL_STIKDEBUG
            : ISTEAM_JIT_PROTOCOL_STANDARD;
    }
    return ISTEAM_JIT_PROTOCOL_UNKNOWN;
}

int iSteamJITGetProtocolMode(void) {
    struct utsname systemInfo;
    if (__builtin_available(iOS 27.0, *)) {
        if (uname(&systemInfo) != 0) {
            return ISTEAM_JIT_PROTOCOL_UNKNOWN;
        }
        return iSteamJITHardwareTXMMode(systemInfo.machine, true);
    }
    if (__builtin_available(iOS 26.0, *)) {
        if (uname(&systemInfo) != 0) {
            return ISTEAM_JIT_PROTOCOL_UNKNOWN;
        }
        return iSteamJITHardwareTXMMode(systemInfo.machine, false);
    }
    return ISTEAM_JIT_PROTOCOL_STANDARD;
}

bool iSteamJITIsSupported(void) {
    return iSteamJITGetProtocolMode() == ISTEAM_JIT_PROTOCOL_STIKDEBUG;
}

static bool iSteamJITDebuggerIsAttached(void) {
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
        if (protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN) {
            return false;
        }
        if (protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG) {
            return iSteamJITDebuggerIsAttached();
        }
    }
    return true;
}
#else
bool iSteamJITHasGetTaskAllow(void) { return false; }
void iSteamJITDetach(void) {}
void *iSteamJITPrepareRegion(void *address, size_t length) {
    (void)address;
    (void)length;
    return NULL;
}
bool iSteamJITIsSupported(void) { return false; }
int iSteamJITGetProtocolMode(void) { return ISTEAM_JIT_PROTOCOL_UNKNOWN; }
bool iSteamJITIsReady(void) { return false; }
#endif
