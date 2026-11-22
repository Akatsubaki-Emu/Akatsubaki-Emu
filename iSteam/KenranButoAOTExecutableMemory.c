#include "JIT26Protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
// iOS exposes the vm_* user-space API; use the same split-map
// operations as the existing QEMU StikDebug allocator.
#define iSteamMachAddress vm_address_t
#define iSteamMachSize vm_size_t
#define iSteamMachRemap vm_remap
#define iSteamMachProtect vm_protect
#define iSteamMachDeallocate vm_deallocate
#endif

#define ISTEAM_AOT_MAX_CODE_BYTES (1024U * 1024U)

struct iSteamAOTExecutableRegion {
    void *writeAddress;
    void *executeAddress;
    size_t mappedSize;
    bool splitMapping;
};

static void iSteamAOTSetError(char *error, size_t capacity, const char *message) {
    if (error == NULL || capacity == 0) return;
    (void)snprintf(error, capacity, "%s", message);
}

static bool iSteamAOTMappedSize(size_t length, size_t *mappedSize) {
    if (length == 0 || length > ISTEAM_AOT_MAX_CODE_BYTES || mappedSize == NULL) {
        return false;
    }
    long rawPageSize = sysconf(_SC_PAGESIZE);
    if (rawPageSize <= 0) return false;
    size_t pageSize = (size_t)rawPageSize;
    if ((pageSize & (pageSize - 1)) != 0 || length > SIZE_MAX - (pageSize - 1)) {
        return false;
    }
    *mappedSize = (length + pageSize - 1) & ~(pageSize - 1);
    return *mappedSize >= length;
}

bool iSteamAOTExecutableMemoryIsAvailable(void) {
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    if (!iSteamJITIsReady()) return false;
    int mode = iSteamJITGetProtocolMode();
    return mode == ISTEAM_JIT_PROTOCOL_STANDARD
        || mode == ISTEAM_JIT_PROTOCOL_STIKDEBUG;
#elif defined(__APPLE__) && (TARGET_OS_SIMULATOR || TARGET_OS_TV || TARGET_OS_MACCATALYST || (defined(TARGET_OS_VISION) && TARGET_OS_VISION))
    return false;
#elif defined(__APPLE__) && (defined(__arm64__) || defined(__aarch64__))
    // Used by the native ARM64 macOS execution harness. iOS simulator,
    // Catalyst, tvOS and visionOS are deliberately excluded above.
    return true;
#else
    return false;
#endif
}

iSteamAOTExecutableRegion *iSteamAOTExecutableMemoryCreate(
    const void *code, size_t length, char *error, size_t errorCapacity
) {
    if (code == NULL) {
        iSteamAOTSetError(error, errorCapacity, "AOT code buffer is null.");
        return NULL;
    }
    size_t mappedSize = 0;
    if (!iSteamAOTMappedSize(length, &mappedSize)) {
        iSteamAOTSetError(error, errorCapacity, "AOT code size is empty, oversized, or cannot be page-aligned.");
        return NULL;
    }
    if (!iSteamAOTExecutableMemoryIsAvailable()) {
        iSteamAOTSetError(error, errorCapacity, "Executable memory is unavailable; use the interpreter fallback.");
        return NULL;
    }

    iSteamAOTExecutableRegion *region = calloc(1, sizeof(*region));
    if (region == NULL) {
        iSteamAOTSetError(error, errorCapacity, "Unable to allocate AOT region metadata.");
        return NULL;
    }
    region->mappedSize = mappedSize;

#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    int protocolMode = iSteamJITGetProtocolMode();
    if (protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG) {
        // StikDebug/TXM supplies an executable mapping. Create a distinct
        // writable alias and keep the debugger session attached; detaching
        // here can revoke the executable mapping on supported iOS versions.
        void *executeAddress = iSteamJITPrepareRegion(NULL, mappedSize);
        if (executeAddress == NULL) {
            iSteamAOTSetError(error, errorCapacity, "StikDebug could not prepare an executable AOT region.");
            free(region);
            return NULL;
        }

        iSteamMachAddress writeAddress = 0;
        vm_prot_t currentProtection = VM_PROT_NONE;
        vm_prot_t maximumProtection = VM_PROT_NONE;
        kern_return_t status = iSteamMachRemap(
            mach_task_self(),
            &writeAddress,
            (iSteamMachSize)mappedSize,
            0,
            VM_FLAGS_ANYWHERE,
            mach_task_self(),
            (iSteamMachAddress)executeAddress,
            FALSE,
            &currentProtection,
            &maximumProtection,
            VM_INHERIT_NONE
        );
        if (status != KERN_SUCCESS || (maximumProtection & VM_PROT_WRITE) == 0) {
            (void)iSteamMachDeallocate(mach_task_self(),
                                       (iSteamMachAddress)executeAddress,
                                       (iSteamMachSize)mappedSize);
            iSteamAOTSetError(error, errorCapacity, "StikDebug executable region could not be remapped writable.");
            free(region);
            return NULL;
        }

        status = iSteamMachProtect(
            mach_task_self(),
            writeAddress,
            (iSteamMachSize)mappedSize,
            FALSE,
            VM_PROT_READ | VM_PROT_WRITE
        );
        if (status != KERN_SUCCESS) {
            (void)iSteamMachDeallocate(mach_task_self(), writeAddress, (iSteamMachSize)mappedSize);
            (void)iSteamMachDeallocate(mach_task_self(),
                                       (iSteamMachAddress)executeAddress,
                                       (iSteamMachSize)mappedSize);
            iSteamAOTSetError(error, errorCapacity, "StikDebug writable alias protection failed.");
            free(region);
            return NULL;
        }

        region->writeAddress = (void *)(uintptr_t)writeAddress;
        region->executeAddress = executeAddress;
        region->splitMapping = true;
    } else if (protocolMode == ISTEAM_JIT_PROTOCOL_STANDARD) {
        void *address = mmap(NULL, mappedSize, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANON, -1, 0);
        if (address == MAP_FAILED) {
            iSteamAOTSetError(error, errorCapacity, "Unable to allocate writable AOT pages.");
            free(region);
            return NULL;
        }
        region->writeAddress = address;
        region->executeAddress = address;
    } else {
        iSteamAOTSetError(error, errorCapacity, "The iOS JIT protocol is unknown.");
        free(region);
        return NULL;
    }
#else
    void *address = mmap(NULL, mappedSize, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    if (address == MAP_FAILED) {
        iSteamAOTSetError(error, errorCapacity, "Unable to allocate writable AOT pages.");
        free(region);
        return NULL;
    }
    region->writeAddress = address;
    region->executeAddress = address;
#endif

    memcpy(region->writeAddress, code, length);
#if defined(__APPLE__)
    sys_icache_invalidate(region->executeAddress, length);
#else
    __builtin___clear_cache((char *)region->executeAddress,
                            (char *)region->executeAddress + length);
#endif

    if (!region->splitMapping) {
        if (mprotect(region->executeAddress, mappedSize, PROT_READ | PROT_EXEC) != 0) {
            (void)munmap(region->writeAddress, mappedSize);
            iSteamAOTSetError(error, errorCapacity, "Unable to seal AOT pages read/execute.");
            free(region);
            return NULL;
        }
    }

    return region;
}

void *iSteamAOTExecutableMemoryEntry(iSteamAOTExecutableRegion *region) {
    return region == NULL ? NULL : region->executeAddress;
}

void iSteamAOTExecutableMemoryDestroy(iSteamAOTExecutableRegion *region) {
    if (region == NULL) return;
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    if (region->splitMapping) {
        (void)iSteamMachDeallocate(mach_task_self(),
                                   (iSteamMachAddress)region->writeAddress,
                                   (iSteamMachSize)region->mappedSize);
        (void)iSteamMachDeallocate(mach_task_self(),
                                   (iSteamMachAddress)region->executeAddress,
                                   (iSteamMachSize)region->mappedSize);
    } else if (region->writeAddress != NULL) {
        (void)munmap(region->writeAddress, region->mappedSize);
    }
#else
    if (region->writeAddress != NULL) {
        (void)munmap(region->writeAddress, region->mappedSize);
    }
#endif
    free(region);
}
