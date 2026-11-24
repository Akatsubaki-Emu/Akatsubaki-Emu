#include "NativeGuestMemory.h"

#include <algorithm>
#ifdef ISTEAM_GUEST_MEMORY_TESTING
#include <atomic>
#endif
#include <array>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <unordered_map>
#include <vector>

namespace {
constexpr uint64_t pageSize = 4096;
constexpr uint8_t permissionRead = 1;
constexpr uint8_t permissionWrite = 2;
constexpr uint8_t permissionExecute = 4;
#ifdef ISTEAM_GUEST_MEMORY_TESTING
std::atomic<ISteamGuestMemoryReadExecuteTestHook> readExecuteTestHook{nullptr};
std::atomic<void *> readExecuteTestContext{nullptr};
std::atomic<int64_t> allocationFailureCountdown{-1};
#endif

bool allocationFailurePoint() {
#ifdef ISTEAM_GUEST_MEMORY_TESTING
    int64_t remaining = allocationFailureCountdown.load(std::memory_order_acquire);
    while (remaining >= 0) {
        if (remaining == 0) return true;
        if (allocationFailureCountdown.compare_exchange_weak(
                remaining, remaining - 1, std::memory_order_acq_rel,
                std::memory_order_acquire)) return false;
    }
#endif
    return false;
}
constexpr uint64_t densePageLimit = (1ULL << 30) / pageSize;
struct Page {
    std::array<uint8_t, pageSize> bytes{};
    size_t allocatedIndex = 0;
};
}

struct ISteamGuestMemory {
    explicit ISteamGuestMemory(uint64_t byteCount) : size(byteCount) {}
    uint64_t size;
    bool usesDensePages = false;
    std::vector<std::unique_ptr<Page>> densePages;
    std::vector<uint64_t> denseAllocatedPageIndices;
    std::unordered_map<uint64_t, std::unique_ptr<Page>> pages;
    std::unordered_map<uint64_t, uint8_t> pagePermissions;
    bool permissionsEnabled = false;
    mutable std::mutex mutex;
};

namespace {
Page *allocateDensePage(ISteamGuestMemory *memory, uint64_t pageIndex) {
    auto page = std::unique_ptr<Page>(new (std::nothrow) Page{});
    if (!page) return nullptr;
    page->allocatedIndex = memory->denseAllocatedPageIndices.size();
    try {
        memory->denseAllocatedPageIndices.push_back(pageIndex);
    } catch (...) {
        return nullptr;
    }
    Page *result = page.get();
    memory->densePages[static_cast<size_t>(pageIndex)] = std::move(page);
    return result;
}

void removeDensePage(ISteamGuestMemory *memory, uint64_t pageIndex) {
    Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
    if (!page) return;
    const size_t allocatedIndex = page->allocatedIndex;
    const uint64_t movedPageIndex = memory->denseAllocatedPageIndices.back();
    memory->denseAllocatedPageIndices[allocatedIndex] = movedPageIndex;
    memory->denseAllocatedPageIndices.pop_back();
    memory->densePages[static_cast<size_t>(pageIndex)].reset();
    if (movedPageIndex != pageIndex) {
        memory->densePages[static_cast<size_t>(movedPageIndex)]->allocatedIndex = allocatedIndex;
    }
}

bool validRange(const ISteamGuestMemory *memory, uint64_t offset, uint64_t length) {
    return memory && offset <= memory->size && length <= memory->size - offset;
}

bool hasPermissionLocked(const ISteamGuestMemory *memory, uint64_t offset,
                         size_t length, uint8_t required) {
    if (!memory->permissionsEnabled || length == 0) return true;
    const uint64_t lastAddress = offset + static_cast<uint64_t>(length) - 1;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = lastAddress / pageSize;
    for (uint64_t pageIndex = firstPage; pageIndex <= lastPage; ++pageIndex) {
        const auto found = memory->pagePermissions.find(pageIndex);
        if (found == memory->pagePermissions.end()
            || (found->second & required) != required) return false;
    }
    return true;
}

// Caller holds memory->mutex. Missing pages read as zero.
bool pageIsMappedLocked(const ISteamGuestMemory *memory, uint64_t pageIndex) {
    if (memory->pagePermissions.find(pageIndex) != memory->pagePermissions.end()) return true;
    if (memory->usesDensePages) {
        return pageIndex < memory->densePages.size()
            && memory->densePages[static_cast<size_t>(pageIndex)] != nullptr;
    }
    const auto found = memory->pages.find(pageIndex);
    return found != memory->pages.end() && found->second != nullptr;
}

void eraseBackingPagesLocked(ISteamGuestMemory *memory, uint64_t firstPage,
                             uint64_t lastPage) {
    if (lastPage < firstPage) return;
    if (memory->usesDensePages) {
        if (memory->densePages.empty() || firstPage >= memory->densePages.size()) return;
        const uint64_t finalPage = std::min<uint64_t>(lastPage, memory->densePages.size() - 1);
        for (uint64_t page = firstPage; page <= finalPage; ++page) {
            removeDensePage(memory, page);
        }
        return;
    }
    for (auto it = memory->pages.begin(); it != memory->pages.end();) {
        if (it->first >= firstPage && it->first <= lastPage) it = memory->pages.erase(it);
        else ++it;
    }
}

void erasePermissionPagesLocked(ISteamGuestMemory *memory, uint64_t firstPage,
                                uint64_t lastPage) {
    if (lastPage < firstPage) return;
    for (auto it = memory->pagePermissions.begin(); it != memory->pagePermissions.end();) {
        if (it->first >= firstPage && it->first <= lastPage) it = memory->pagePermissions.erase(it);
        else ++it;
    }
}

void zeroAllocatedRangeLocked(ISteamGuestMemory *memory, uint64_t offset,
                              uint64_t length) {
    if (!length) return;
    const uint64_t end = offset + length;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = (end - 1) / pageSize;
    if (memory->usesDensePages) {
        if (memory->densePages.empty() || firstPage >= memory->densePages.size()) return;
        const uint64_t finalPage = std::min<uint64_t>(lastPage, memory->densePages.size() - 1);
        for (uint64_t pageIndex = firstPage; pageIndex <= finalPage; ++pageIndex) {
            Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
            if (!page) continue;
            const uint64_t pageStart = pageIndex * pageSize;
            const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
            const uint64_t overlapStart = std::max(offset, pageStart);
            const uint64_t overlapEnd = std::min(end, pageStart + pageLength);
            if (overlapEnd > overlapStart) {
                std::memset(page->bytes.data() + static_cast<size_t>(overlapStart - pageStart),
                            0, static_cast<size_t>(overlapEnd - overlapStart));
            }
        }
        return;
    }
    for (auto it = memory->pages.begin(); it != memory->pages.end(); ++it) {
        if (!it->second) continue;
        const uint64_t pageStart = it->first * pageSize;
        if (pageStart >= end || pageStart >= memory->size) continue;
        const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
        const uint64_t pageEnd = pageStart + pageLength;
        if (pageEnd <= offset) continue;
        const uint64_t overlapStart = std::max(offset, pageStart);
        const uint64_t overlapEnd = std::min(end, pageEnd);
        if (overlapEnd > overlapStart) {
            std::memset(it->second->bytes.data() + static_cast<size_t>(overlapStart - pageStart),
                        0, static_cast<size_t>(overlapEnd - overlapStart));
        }
    }
}

uint64_t pageBoundaryAtOrAfter(uint64_t address, uint64_t limit) {
    const uint64_t remainder = address % pageSize;
    if (remainder == 0) return address;
    const uint64_t delta = pageSize - remainder;
    return delta > limit - address ? limit : address + delta;
}

int stagePermissionEntriesLocked(
    ISteamGuestMemory *memory, uint64_t firstPage, uint64_t lastPage,
    uint8_t permissions, std::unordered_map<uint64_t, uint8_t> &staged) {
    if (lastPage < firstPage) return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
    const uint64_t pageCount = lastPage - firstPage + 1;
    if (pageCount > static_cast<uint64_t>(SIZE_MAX)
        || allocationFailurePoint()) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED;
    }
    staged.reserve(static_cast<size_t>(pageCount));
    for (uint64_t page = firstPage; page <= lastPage; ++page) {
        if (memory->pagePermissions.find(page) != memory->pagePermissions.end()) continue;
        if (allocationFailurePoint()) {
            return ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED;
        }
        staged.emplace(page, permissions);
    }
    if (staged.size() > memory->pagePermissions.max_size() - memory->pagePermissions.size()
        || allocationFailurePoint()) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED;
    }
    // Reserve all destination buckets before the transaction mutates bytes or permissions.
    memory->pagePermissions.reserve(memory->pagePermissions.size() + staged.size());
    return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
}

bool copyReadLocked(ISteamGuestMemory *memory, uint64_t offset,
                    uint8_t *destination, size_t length) {
    if (length == 0) return true;
    size_t completed = 0;
    while (completed < length) {
        const uint64_t address = offset + static_cast<uint64_t>(completed);
        const uint64_t pageIndex = address / pageSize;
        const size_t pageOffset = static_cast<size_t>(address % pageSize);
        const size_t amount = std::min(length - completed,
                                       static_cast<size_t>(pageSize) - pageOffset);
        const Page *page = nullptr;
        if (memory->usesDensePages) {
            page = memory->densePages[static_cast<size_t>(pageIndex)].get();
        } else {
            const auto found = memory->pages.find(pageIndex);
            if (found != memory->pages.end()) page = found->second.get();
        }
        if (!page) std::memset(destination + completed, 0, amount);
        else std::memcpy(destination + completed, page->bytes.data() + pageOffset, amount);
        completed += amount;
    }
    return true;
}

Page *getOrAllocatePageLocked(ISteamGuestMemory *memory, uint64_t pageIndex) {
    if (memory->usesDensePages) {
        Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
        return page ? page : allocateDensePage(memory, pageIndex);
    }
    auto found = memory->pages.find(pageIndex);
    if (found == memory->pages.end()) {
        auto page = std::unique_ptr<Page>(new (std::nothrow) Page{});
        if (!page) return nullptr;
        found = memory->pages.emplace(pageIndex, std::move(page)).first;
    }
    return found->second.get();
}
}

extern "C" {

ISteamGuestMemory *isteam_guest_memory_create(uint64_t size) {
    try {
        auto memory = std::make_unique<ISteamGuestMemory>(size);
        const uint64_t pageCount = size / pageSize + (size % pageSize == 0 ? 0 : 1);
        if (pageCount <= densePageLimit) {
            memory->densePages.resize(static_cast<size_t>(pageCount));
            memory->usesDensePages = true;
        }
        return memory.release();
    } catch (...) {
        return nullptr;
    }
}

void isteam_guest_memory_destroy(ISteamGuestMemory *memory) { delete memory; }
uint64_t isteam_guest_memory_size(const ISteamGuestMemory *memory) { return memory ? memory->size : 0; }

bool isteam_guest_memory_begin_mapping(ISteamGuestMemory *memory) {
    if (!memory) return false;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        memory->pagePermissions.clear();
        memory->permissionsEnabled = true;
        return true;
    } catch (...) { return false; }
}

bool isteam_guest_memory_map(ISteamGuestMemory *memory, uint64_t offset,
                             uint64_t length, uint8_t permissions, bool merge) {
    if (!validRange(memory, offset, length) || length == 0 || offset % pageSize != 0
        || (permissions & ~uint8_t{7}) != 0) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = (offset + length - 1) / pageSize;
    const uint64_t pageCount = lastPage - firstPage + 1;
    if (pageCount > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) return false;
    struct PreviousPermission { uint64_t page; bool existed; uint8_t value; };
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        std::vector<PreviousPermission> previous;
        previous.reserve(static_cast<size_t>(pageCount));
        try {
            for (uint64_t page = firstPage; page <= lastPage; ++page) {
                const auto found = memory->pagePermissions.find(page);
                const bool existed = found != memory->pagePermissions.end();
                const uint8_t oldValue = existed ? found->second : 0;
                previous.push_back({page, existed, oldValue});
                memory->pagePermissions[page] = merge
                    ? static_cast<uint8_t>(oldValue | permissions) : permissions;
            }
        } catch (...) {
            for (const auto &entry : previous) {
                if (entry.existed) memory->pagePermissions[entry.page] = entry.value;
                else memory->pagePermissions.erase(entry.page);
            }
            return false;
        }
        return true;
    } catch (...) { return false; }
}

bool isteam_guest_memory_protect(ISteamGuestMemory *memory, uint64_t offset,
                                 uint64_t length, uint8_t permissions) {
    if (!validRange(memory, offset, length) || length == 0 || offset % pageSize != 0
        || (permissions & ~uint8_t{7}) != 0) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = (offset + length - 1) / pageSize;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        for (uint64_t page = firstPage; page <= lastPage; ++page) {
            if (memory->pagePermissions.find(page) == memory->pagePermissions.end()) return false;
        }
        for (uint64_t page = firstPage; page <= lastPage; ++page) memory->pagePermissions[page] = permissions;
        return true;
    } catch (...) { return false; }
}

bool isteam_guest_memory_unmap(ISteamGuestMemory *memory, uint64_t offset, uint64_t length) {
    if (!validRange(memory, offset, length) || length == 0 || offset % pageSize != 0) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = (offset + length - 1) / pageSize;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        if (memory->usesDensePages) {
            size_t index = 0;
            while (index < memory->denseAllocatedPageIndices.size()) {
                const uint64_t page = memory->denseAllocatedPageIndices[index];
                if (page >= firstPage && page <= lastPage) removeDensePage(memory, page);
                else ++index;
            }
        } else {
            for (auto it = memory->pages.begin(); it != memory->pages.end();) {
                if (it->first >= firstPage && it->first <= lastPage) it = memory->pages.erase(it);
                else ++it;
            }
        }
        for (auto it = memory->pagePermissions.begin(); it != memory->pagePermissions.end();) {
            if (it->first >= firstPage && it->first <= lastPage) it = memory->pagePermissions.erase(it);
            else ++it;
        }
        return true;
    } catch (...) { return false; }
}

bool isteam_guest_memory_read_execute(ISteamGuestMemory *memory, uint64_t offset,
                                      uint8_t *destination, size_t length) {
    if (!memory || (length && !destination) || !validRange(memory, offset, static_cast<uint64_t>(length))) return false;
    if (length == 0) return true;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!hasPermissionLocked(memory, offset, length, permissionExecute)) return false;
#ifdef ISTEAM_GUEST_MEMORY_TESTING
        if (auto hook = readExecuteTestHook.load(std::memory_order_acquire)) {
            hook(readExecuteTestContext.load(std::memory_order_acquire));
        }
#endif
        return copyReadLocked(memory, offset, destination, length);
    } catch (...) { return false; }
}

size_t isteam_guest_memory_read_execute_prefix(ISteamGuestMemory *memory, uint64_t offset,
                                               uint8_t *destination, size_t maximumLength) {
    if (!memory || (maximumLength && !destination) || offset > memory->size || maximumLength == 0) return 0;
    const uint64_t available = memory->size - offset;
    const size_t count = available < static_cast<uint64_t>(maximumLength)
        ? static_cast<size_t>(available) : maximumLength;
    if (count == 0) return 0;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return copyReadLocked(memory, offset, destination, count) ? count : 0;
        size_t completed = 0;
        while (completed < count) {
            const uint64_t address = offset + static_cast<uint64_t>(completed);
            const auto found = memory->pagePermissions.find(address / pageSize);
            if (found == memory->pagePermissions.end() || (found->second & permissionExecute) == 0) break;
            const size_t pageRemaining = static_cast<size_t>(pageSize - (address % pageSize));
            const size_t amount = std::min(count - completed, pageRemaining);
            if (!copyReadLocked(memory, address, destination + completed, amount)) break;
            completed += amount;
        }
        return completed;
    } catch (...) { return 0; }
}

bool isteam_guest_memory_read(ISteamGuestMemory *memory, uint64_t offset,
                              uint8_t *destination, size_t length) {
    if (!memory || (length && !destination) || !validRange(memory, offset, static_cast<uint64_t>(length))) return false;
    if (length == 0) return true;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!hasPermissionLocked(memory, offset, length, 0x1)) return false;
        return copyReadLocked(memory, offset, destination, length);
    } catch (...) { return false; }
}

bool isteam_guest_memory_write(ISteamGuestMemory *memory, uint64_t offset,
                               const uint8_t *source, size_t length) {
    if (!memory || (length && !source) || !validRange(memory, offset, static_cast<uint64_t>(length))) return false;
    if (length == 0) return true;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!hasPermissionLocked(memory, offset, length, 0x2)) return false;
        size_t completed = 0;
        while (completed < length) {
            const uint64_t address = offset + static_cast<uint64_t>(completed);
            const uint64_t pageIndex = address / pageSize;
            const size_t pageOffset = static_cast<size_t>(address % pageSize);
            const size_t amount = std::min(length - completed, static_cast<size_t>(pageSize) - pageOffset);
            Page *page = getOrAllocatePageLocked(memory, pageIndex);
            if (!page) return false;
            std::memcpy(page->bytes.data() + pageOffset, source + completed, amount);
            completed += amount;
        }
        return true;
    } catch (...) { return false; }
}

bool isteam_guest_memory_zero(ISteamGuestMemory *memory, uint64_t offset, uint64_t length) {
    if (!validRange(memory, offset, length)) return false;
    if (length == 0) return true;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        const uint64_t end = offset + length;
        const uint64_t firstPage = offset / pageSize;
        const uint64_t lastPage = (end - 1) / pageSize;
        const uint64_t rangePageCount = lastPage - firstPage + 1;
        if (memory->usesDensePages) {
            if (rangePageCount > static_cast<uint64_t>(memory->denseAllocatedPageIndices.size())) {
                size_t index = 0;
                while (index < memory->denseAllocatedPageIndices.size()) {
                    const uint64_t pageIndex = memory->denseAllocatedPageIndices[index];
                    const uint64_t pageStart = pageIndex * pageSize;
                    const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                    const uint64_t pageEnd = pageStart + pageLength;
                    if (pageStart >= end || pageEnd <= offset) { ++index; continue; }
                    const uint64_t overlapStart = std::max(offset, pageStart);
                    const uint64_t overlapEnd = std::min(end, pageEnd);
                    const size_t pageOffset = static_cast<size_t>(overlapStart - pageStart);
                    const size_t amount = static_cast<size_t>(overlapEnd - overlapStart);
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) removeDensePage(memory, pageIndex);
                    else {
                        Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
                        std::fill_n(page->bytes.data() + pageOffset, amount, uint8_t{0});
                        ++index;
                    }
                }
            } else {
                for (uint64_t pageIndex = firstPage; pageIndex <= lastPage; ++pageIndex) {
                    const uint64_t pageStart = pageIndex * pageSize;
                    const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                    const uint64_t pageEnd = pageStart + pageLength;
                    const uint64_t overlapStart = std::max(offset, pageStart);
                    const uint64_t overlapEnd = std::min(end, pageEnd);
                    const size_t pageOffset = static_cast<size_t>(overlapStart - pageStart);
                    const size_t amount = static_cast<size_t>(overlapEnd - overlapStart);
                    Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
                    if (!page) continue;
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) removeDensePage(memory, pageIndex);
                    else std::fill_n(page->bytes.data() + pageOffset, amount, uint8_t{0});
                }
            }
            return true;
        }
        if (rangePageCount > static_cast<uint64_t>(memory->pages.size())) {
            for (auto it = memory->pages.begin(); it != memory->pages.end();) {
                const uint64_t pageStart = it->first * pageSize;
                if (pageStart >= memory->size) { it = memory->pages.erase(it); continue; }
                const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                const uint64_t pageEnd = pageStart + pageLength;
                if (pageStart >= end || pageEnd <= offset) { ++it; continue; }
                const uint64_t overlapStart = std::max(offset, pageStart);
                const uint64_t overlapEnd = std::min(end, pageEnd);
                const size_t pageOffset = static_cast<size_t>(overlapStart - pageStart);
                const size_t amount = static_cast<size_t>(overlapEnd - overlapStart);
                if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) it = memory->pages.erase(it);
                else {
                    if (it->second) std::memset(it->second->bytes.data() + pageOffset, 0, amount);
                    ++it;
                }
            }
        } else {
            for (uint64_t address = offset; address < end;) {
                const uint64_t pageIndex = address / pageSize;
                const size_t pageOffset = static_cast<size_t>(address % pageSize);
                const size_t amount = static_cast<size_t>(std::min(end - address, pageSize - pageOffset));
                const auto found = memory->pages.find(pageIndex);
                if (found != memory->pages.end() && found->second) {
                    const uint64_t pageStart = pageIndex * pageSize;
                    const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) memory->pages.erase(found);
                    else std::memset(found->second->bytes.data() + pageOffset, 0, amount);
                }
                address += amount;
            }
        }
        return true;
    } catch (...) { return false; }
}

int isteam_guest_memory_map_transaction(ISteamGuestMemory *memory, uint64_t offset,
                                         uint64_t length, uint8_t permissions,
                                         bool replaceExisting) {
    if (!memory || (permissions & static_cast<uint8_t>(~7u))
        || offset % pageSize != 0 || offset > memory->size
        || !length || length > memory->size - offset) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_INVALID;
    }
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return ISTEAM_GUEST_MEMORY_TRANSACTION_INVALID;
        const uint64_t firstPage = offset / pageSize;
        const uint64_t lastPage = (offset + length - 1) / pageSize;
        if (!replaceExisting) {
            for (uint64_t page = firstPage; page <= lastPage; ++page) {
                if (pageIsMappedLocked(memory, page)) {
                    return ISTEAM_GUEST_MEMORY_TRANSACTION_ALREADY_MAPPED;
                }
            }
        }

        std::unordered_map<uint64_t, uint8_t> staged;
        const int stagedResult = stagePermissionEntriesLocked(
            memory, firstPage, lastPage, permissions, staged);
        if (stagedResult != ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS) return stagedResult;

        // All potentially throwing allocations have completed. The remaining
        // operations are erases, scalar permission updates, and node transfers.
        if (replaceExisting) eraseBackingPagesLocked(memory, firstPage, lastPage);
        for (uint64_t page = firstPage; page <= lastPage; ++page) {
            auto found = memory->pagePermissions.find(page);
            if (found != memory->pagePermissions.end()) found->second = permissions;
        }
        memory->pagePermissions.merge(staged);
        return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
    } catch (...) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED;
    }
}

int isteam_guest_memory_resize_break(ISteamGuestMemory *memory, uint64_t oldBreak,
                                     uint64_t newBreak) {
    if (!memory || oldBreak > memory->size || newBreak > memory->size) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_INVALID;
    }
    if (oldBreak == newBreak) return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) {
            const uint64_t start = std::min(oldBreak, newBreak);
            zeroAllocatedRangeLocked(memory, start,
                                     std::max(oldBreak, newBreak) - start);
            return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
        }

        const uint64_t oldPageEnd = pageBoundaryAtOrAfter(oldBreak, memory->size);
        const uint64_t newPageEnd = pageBoundaryAtOrAfter(newBreak, memory->size);
        if (newBreak > oldBreak) {
            std::unordered_map<uint64_t, uint8_t> staged;
            if (newPageEnd > oldPageEnd) {
                const uint64_t firstPage = oldPageEnd / pageSize;
                const uint64_t lastPage = (newPageEnd - 1) / pageSize;
                for (uint64_t page = firstPage; page <= lastPage; ++page) {
                    if (pageIsMappedLocked(memory, page)) {
                        return ISTEAM_GUEST_MEMORY_TRANSACTION_ALREADY_MAPPED;
                    }
                }
                const int stagedResult = stagePermissionEntriesLocked(
                    memory, firstPage, lastPage, 3, staged);
                if (stagedResult != ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS) return stagedResult;
            }
            // Only the tail of the old partial page can contain stale bytes.
            // Newly exposed whole pages are absent and therefore already zero-filled.
            const uint64_t zeroEnd = std::min(newBreak, oldPageEnd);
            if (zeroEnd > oldBreak) {
                zeroAllocatedRangeLocked(memory, oldBreak, zeroEnd - oldBreak);
            }
            memory->pagePermissions.merge(staged);
            return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
        }

        // Shrink has no allocation path: clear the retained partial page, then
        // release complete pages and their permission nodes under the same lock.
        const uint64_t zeroEnd = std::min(oldBreak, newPageEnd);
        if (zeroEnd > newBreak) {
            zeroAllocatedRangeLocked(memory, newBreak, zeroEnd - newBreak);
        }
        if (oldPageEnd > newPageEnd) {
            const uint64_t firstPage = newPageEnd / pageSize;
            const uint64_t lastPage = (oldPageEnd - 1) / pageSize;
            eraseBackingPagesLocked(memory, firstPage, lastPage);
            erasePermissionPagesLocked(memory, firstPage, lastPage);
        }
        return ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS;
    } catch (...) {
        return ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED;
    }
}

bool isteam_guest_memory_has_mapped_pages(ISteamGuestMemory *memory, uint64_t offset,
                                              uint64_t length) {
    if (!memory || !length || offset > memory->size || length > memory->size - offset) return false;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        const uint64_t firstPage = offset / pageSize;
        const uint64_t lastPage = (offset + length - 1) / pageSize;
        for (uint64_t page = firstPage; page <= lastPage; ++page) {
            if (pageIsMappedLocked(memory, page)) return true;
        }
        return false;
    } catch (...) {
        return true;
    }
}

void isteam_guest_memory_clear(ISteamGuestMemory *memory) {
    if (!memory) return;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        memory->pagePermissions.clear();
        memory->permissionsEnabled = false;
        if (memory->usesDensePages) {
            for (uint64_t pageIndex : memory->denseAllocatedPageIndices) memory->densePages[static_cast<size_t>(pageIndex)].reset();
            memory->denseAllocatedPageIndices.clear();
        } else memory->pages.clear();
    } catch (...) { }
}

#ifdef ISTEAM_GUEST_MEMORY_TESTING
void isteam_guest_memory_set_read_execute_test_hook(
    ISteamGuestMemoryReadExecuteTestHook hook, void *context) {
    readExecuteTestContext.store(context, std::memory_order_release);
    readExecuteTestHook.store(hook, std::memory_order_release);
}
void isteam_guest_memory_set_allocation_failure_countdown(int64_t countdown) {
    allocationFailureCountdown.store(countdown, std::memory_order_release);
}
#endif

size_t isteam_guest_memory_allocated_pages(ISteamGuestMemory *memory) {
    if (!memory) return 0;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        return memory->usesDensePages ? memory->denseAllocatedPageIndices.size() : memory->pages.size();
    } catch (...) { return 0; }
}

}
