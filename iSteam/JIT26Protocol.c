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

static bool iSteamJITHardwareSupportsTXM(const char *hardwareIdentifier, bool isIOS27OrNewer) {
    if (hardwareIdentifier == NULL || hardwareIdentifier[0] == '\0') {
        return false;
    }

    if (isIOS27OrNewer) {
        return strcmp(hardwareIdentifier, "iPad8,11") != 0
            && strcmp(hardwareIdentifier, "iPad8,12") != 0;
    }

    int major = 0;
    int minor = 0;
    if (sscanf(hardwareIdentifier, "iPhone%d,%d", &major, &minor) == 2) {
        return major > 14 || (major == 14 && minor >= 2);
    }
    if (sscanf(hardwareIdentifier, "iPad%d,%d", &major, &minor) == 2) {
        return major > 14 || (major == 14 && minor >= 5);
    }
    return false;
}

bool iSteamJITIsSupported(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) != 0) {
        return false;
    }

    if (__builtin_available(iOS 27.0, *)) {
        return iSteamJITHardwareSupportsTXM(systemInfo.machine, true);
    }
    if (__builtin_available(iOS 26.0, *)) {
        return iSteamJITHardwareSupportsTXM(systemInfo.machine, false);
    }
    return false;
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

    if (__builtin_available(iOS 26.0, *) && iSteamJITIsSupported()) {
        return iSteamJITDebuggerIsAttached();
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
bool iSteamJITIsReady(void) { return false; }
#endif
