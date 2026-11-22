#include "JIT26Protocol.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
#include <IOKit/IOKitLib.h>
#endif
#endif

#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
/*
 * TXM executable mappings can lose RX permission when StikDebug detaches.
 * Keep the debugger session attached while generated code may still execute.
 * This exported hook remains a no-op for compatibility with existing QEMU
 * runtimes; process exit releases the debugger session.
 */
__attribute__((noinline))
void iSteamJITDetach(void) {
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
    io_registry_entry_t memoryMap = IORegistryEntryFromPath(
        kIOMainPortDefault, "IODeviceTree:/chosen/memory-map"
    );
    if (memoryMap == IO_OBJECT_NULL) return ISTEAM_JIT_PROTOCOL_UNKNOWN;

    CFTypeRef keysValue = IORegistryEntryCreateCFProperty(
        memoryMap, kIORegistryEntryPropertyKeysKey, kCFAllocatorDefault, 0
    );
    IOObjectRelease(memoryMap);
    if (keysValue == NULL || CFGetTypeID(keysValue) != CFArrayGetTypeID()) {
        if (keysValue != NULL) CFRelease(keysValue);
        return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    }

    CFArrayRef keys = (CFArrayRef)keysValue;
    CFIndex keyCount = CFArrayGetCount(keys);
    if (keyCount == 0) {
        CFRelease(keysValue);
        return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    }
    for (CFIndex index = 0; index < keyCount; index++) {
        CFTypeRef key = (CFTypeRef)CFArrayGetValueAtIndex(keys, index);
        if (key == NULL || CFGetTypeID(key) != CFStringGetTypeID()) {
            CFRelease(keysValue);
            return ISTEAM_JIT_PROTOCOL_UNKNOWN;
        }
    }

    bool hasTXM = CFArrayContainsValue(keys, CFRangeMake(0, keyCount), CFSTR("TXM"));
    CFRelease(keysValue);
    return hasTXM ? ISTEAM_JIT_PROTOCOL_STIKDEBUG : ISTEAM_JIT_PROTOCOL_STANDARD;
}

int iSteamJITGetProtocolMode(void) {
    if (__builtin_available(iOS 26.0, *)) return iSteamJITHardwareTXMMode();
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
        if (protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN) return false;
        if (protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG) return iSteamJITDebuggerIsAttached();
    }
    return true;
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
#endif
