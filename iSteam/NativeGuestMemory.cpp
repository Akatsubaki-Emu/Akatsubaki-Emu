#include "NativeGuestMemory.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <limits>
#include <mutex>
#include <new>
#include <unordered_map>
#include <vector>

namespace {
constexpr uint64_t pageSize = 4096;
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
    bool permissionsEnabled = false;
    std::vector<uint8_t> densePagePermissions;
    std::unordered_map<uint64_t, uint8_t> sparsePagePermissions;
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
constexpr uint8_t mappedFlag = 0x80;
constexpr uint8_t permissionMask = 0x07;
constexpr uint8_t permissionRead = 0x01;
constexpr uint8_t permissionWrite = 0x02;
constexpr uint8_t permissionExecute = 0x04;
constexpr uint64_t maximumSparseMappingPages = 1ULL << 20;

bool validMappingRange(const ISteamGuestMemory *memory, uint64_t offset, uint64_t length) {
    return memory && length > 0 && offset % pageSize == 0 && length % pageSize == 0
        && offset <= memory->size && length <= memory->size - offset;
}

uint8_t pagePermissionEntryLocked(const ISteamGuestMemory *memory, uint64_t pageIndex) {
    if (memory->usesDensePages) {
        if (pageIndex >= memory->densePagePermissions.size()) return 0;
        return memory->densePagePermissions[static_cast<size_t>(pageIndex)];
    }
    const auto found = memory->sparsePagePermissions.find(pageIndex);
    return found == memory->sparsePagePermissions.end() ? 0 : found->second;
}

bool hasPermissionLocked(const ISteamGuestMemory *memory, uint64_t pageIndex,
                         uint8_t requiredPermission) {
    if (!memory->permissionsEnabled) return true;
    const uint8_t entry = pagePermissionEntryLocked(memory, pageIndex);
    return (entry & mappedFlag) != 0 && (entry & requiredPermission) == requiredPermission;
}

bool rangeHasPermissionLocked(const ISteamGuestMemory *memory, uint64_t offset,
                              uint64_t length, uint8_t requiredPermission) {
    if (!memory->permissionsEnabled || length == 0) return true;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = (offset + length - 1) / pageSize;
    for (uint64_t pageIndex = firstPage; pageIndex <= lastPage; ++pageIndex) {
        if (!hasPermissionLocked(memory, pageIndex, requiredPermission)) return false;
    }
    return true;
}
}

extern "C" {

ISteamGuestMemory *isteam_guest_memory_create(uint64_t size) {
    try {
        auto memory = std::make_unique<ISteamGuestMemory>(size);
        const uint64_t pageCount = size / pageSize + (size % pageSize == 0 ? 0 : 1);
        if (pageCount <= densePageLimit) {
            memory->densePages.resize(static_cast<size_t>(pageCount));
            memory->densePagePermissions.resize(static_cast<size_t>(pageCount));
            memory->usesDensePages = true;
        }
        return memory.release();
    } catch (...) {
        return nullptr;
    }
}

void isteam_guest_memory_destroy(ISteamGuestMemory *memory) {
    delete memory;
}

uint64_t isteam_guest_memory_size(const ISteamGuestMemory *memory) {
    return memory ? memory->size : 0;
}


bool isteam_guest_memory_begin_mapping(ISteamGuestMemory *memory) {
    if (!memory) return false;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (memory->usesDensePages) {
            std::fill(memory->densePagePermissions.begin(), memory->densePagePermissions.end(), uint8_t{0});
        } else {
            memory->sparsePagePermissions.clear();
        }
        memory->permissionsEnabled = true;
        return true;
    } catch (...) {
        return false;
    }
}

bool isteam_guest_memory_map(ISteamGuestMemory *memory, uint64_t offset, uint64_t length,
                             uint8_t permissions, bool merge) {
    if (!validMappingRange(memory, offset, length) || (permissions & ~permissionMask) != 0) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t pageCount = length / pageSize;
    if (!memory->usesDensePages && pageCount > maximumSparseMappingPages) return false;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        if (memory->usesDensePages) {
            for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
                const uint8_t existing = memory->densePagePermissions[static_cast<size_t>(pageIndex)];
                if (!merge && (existing & mappedFlag) != 0) return false;
            }
            for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
                uint8_t &entry = memory->densePagePermissions[static_cast<size_t>(pageIndex)];
                entry = static_cast<uint8_t>(mappedFlag | ((merge ? entry : 0) & permissionMask) | permissions);
            }
            return true;
        }
        if (pageCount > static_cast<uint64_t>(std::numeric_limits<size_t>::max())
            - memory->sparsePagePermissions.size()) return false;
        if (!merge) {
            for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
                if (memory->sparsePagePermissions.find(pageIndex) != memory->sparsePagePermissions.end()) return false;
            }
        }
        std::vector<uint64_t> inserted;
        inserted.reserve(static_cast<size_t>(pageCount));
        memory->sparsePagePermissions.reserve(memory->sparsePagePermissions.size()
                                               + static_cast<size_t>(pageCount));
        try {
            for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
                if (memory->sparsePagePermissions.find(pageIndex) == memory->sparsePagePermissions.end()) {
                    memory->sparsePagePermissions.emplace(pageIndex, mappedFlag);
                    inserted.push_back(pageIndex);
                }
            }
        } catch (...) {
            for (uint64_t pageIndex : inserted) memory->sparsePagePermissions.erase(pageIndex);
            return false;
        }
        for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
            uint8_t &entry = memory->sparsePagePermissions.find(pageIndex)->second;
            entry = static_cast<uint8_t>(mappedFlag | ((merge ? entry : 0) & permissionMask) | permissions);
        }
        return true;
    } catch (...) {
        return false;
    }
}

bool isteam_guest_memory_protect(ISteamGuestMemory *memory, uint64_t offset, uint64_t length,
                                 uint8_t permissions) {
    if (!validMappingRange(memory, offset, length) || (permissions & ~permissionMask) != 0) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t pageCount = length / pageSize;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
            if ((pagePermissionEntryLocked(memory, pageIndex) & mappedFlag) == 0) return false;
        }
        for (uint64_t pageIndex = firstPage; pageIndex < firstPage + pageCount; ++pageIndex) {
            const uint8_t entry = static_cast<uint8_t>(mappedFlag | permissions);
            if (memory->usesDensePages) memory->densePagePermissions[static_cast<size_t>(pageIndex)] = entry;
            else memory->sparsePagePermissions.find(pageIndex)->second = entry;
        }
        return true;
    } catch (...) {
        return false;
    }
}

bool isteam_guest_memory_unmap(ISteamGuestMemory *memory, uint64_t offset, uint64_t length) {
    if (!validMappingRange(memory, offset, length)) return false;
    const uint64_t firstPage = offset / pageSize;
    const uint64_t lastPage = firstPage + length / pageSize - 1;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!memory->permissionsEnabled) return false;
        if (memory->usesDensePages) {
            for (uint64_t pageIndex = firstPage; pageIndex <= lastPage; ++pageIndex) {
                memory->densePagePermissions[static_cast<size_t>(pageIndex)] = 0;
                removeDensePage(memory, pageIndex);
            }
            return true;
        }
        for (auto it = memory->sparsePagePermissions.begin(); it != memory->sparsePagePermissions.end();) {
            if (it->first >= firstPage && it->first <= lastPage) it = memory->sparsePagePermissions.erase(it);
            else ++it;
        }
        for (auto it = memory->pages.begin(); it != memory->pages.end();) {
            if (it->first >= firstPage && it->first <= lastPage) it = memory->pages.erase(it);
            else ++it;
        }
        return true;
    } catch (...) {
        return false;
    }
}

bool isteam_guest_memory_read(ISteamGuestMemory *memory, uint64_t offset,
                              uint8_t *destination, size_t length) {
    if (!memory || (length && !destination)
        || offset > memory->size || length > memory->size - offset) {
        return false;
    }
    if (!length) return true;

    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!rangeHasPermissionLocked(memory, offset, length, permissionRead)) return false;
        const uint64_t lastAddress = offset + length - 1;
        if (memory->usesDensePages) {
            if (offset / pageSize == lastAddress / pageSize) {
                const size_t pageIndex = static_cast<size_t>(offset / pageSize);
                const size_t pageOffset = static_cast<size_t>(offset % pageSize);
                const Page *page = memory->densePages[pageIndex].get();
                if (!page) std::fill_n(destination, length, uint8_t{0});
                else std::copy_n(page->bytes.data() + pageOffset, length, destination);
                return true;
            }
            size_t completed = 0;
            while (completed < length) {
                const uint64_t address = offset + completed;
                const size_t pageIndex = static_cast<size_t>(address / pageSize);
                const size_t pageOffset = static_cast<size_t>(address % pageSize);
                const size_t amount = std::min(length - completed,
                                               static_cast<size_t>(pageSize) - pageOffset);
                const Page *page = memory->densePages[pageIndex].get();
                if (!page) std::fill_n(destination + completed, amount, uint8_t{0});
                else std::copy_n(page->bytes.data() + pageOffset, amount, destination + completed);
                completed += amount;
            }
            return true;
        }
        if (offset / pageSize == lastAddress / pageSize) {
            const size_t pageOffset = static_cast<size_t>(offset % pageSize);
            const auto found = memory->pages.find(offset / pageSize);
            if (found == memory->pages.end() || !found->second) {
                std::memset(destination, 0, length);
            } else {
                std::memcpy(destination, found->second->bytes.data() + pageOffset, length);
            }
            return true;
        }
        size_t completed = 0;
        while (completed < length) {
            const uint64_t address = offset + completed;
            const uint64_t pageIndex = address / pageSize;
            const size_t pageOffset = static_cast<size_t>(address % pageSize);
            const size_t amount = std::min(length - completed,
                                           static_cast<size_t>(pageSize) - pageOffset);
            const auto found = memory->pages.find(pageIndex);
            if (found == memory->pages.end() || !found->second) {
                std::memset(destination + completed, 0, amount);
            } else {
                std::memcpy(destination + completed,
                            found->second->bytes.data() + pageOffset, amount);
            }
            completed += amount;
        }
        return true;
    } catch (...) {
        return false;
    }
}

bool isteam_guest_memory_read_execute(ISteamGuestMemory *memory, uint64_t offset,
                              uint8_t *destination, size_t length) {
    if (!memory || (length && !destination)
        || offset > memory->size || length > memory->size - offset) {
        return false;
    }
    if (!length) return true;

    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!rangeHasPermissionLocked(memory, offset, length, permissionExecute)) return false;
        const uint64_t lastAddress = offset + length - 1;
        if (memory->usesDensePages) {
            if (offset / pageSize == lastAddress / pageSize) {
                const size_t pageIndex = static_cast<size_t>(offset / pageSize);
                const size_t pageOffset = static_cast<size_t>(offset % pageSize);
                const Page *page = memory->densePages[pageIndex].get();
                if (!page) std::fill_n(destination, length, uint8_t{0});
                else std::copy_n(page->bytes.data() + pageOffset, length, destination);
                return true;
            }
            size_t completed = 0;
            while (completed < length) {
                const uint64_t address = offset + completed;
                const size_t pageIndex = static_cast<size_t>(address / pageSize);
                const size_t pageOffset = static_cast<size_t>(address % pageSize);
                const size_t amount = std::min(length - completed,
                                               static_cast<size_t>(pageSize) - pageOffset);
                const Page *page = memory->densePages[pageIndex].get();
                if (!page) std::fill_n(destination + completed, amount, uint8_t{0});
                else std::copy_n(page->bytes.data() + pageOffset, amount, destination + completed);
                completed += amount;
            }
            return true;
        }
        if (offset / pageSize == lastAddress / pageSize) {
            const size_t pageOffset = static_cast<size_t>(offset % pageSize);
            const auto found = memory->pages.find(offset / pageSize);
            if (found == memory->pages.end() || !found->second) {
                std::memset(destination, 0, length);
            } else {
                std::memcpy(destination, found->second->bytes.data() + pageOffset, length);
            }
            return true;
        }
        size_t completed = 0;
        while (completed < length) {
            const uint64_t address = offset + completed;
            const uint64_t pageIndex = address / pageSize;
            const size_t pageOffset = static_cast<size_t>(address % pageSize);
            const size_t amount = std::min(length - completed,
                                           static_cast<size_t>(pageSize) - pageOffset);
            const auto found = memory->pages.find(pageIndex);
            if (found == memory->pages.end() || !found->second) {
                std::memset(destination + completed, 0, amount);
            } else {
                std::memcpy(destination + completed,
                            found->second->bytes.data() + pageOffset, amount);
            }
            completed += amount;
        }
        return true;
    } catch (...) {
        return false;
    }
}


size_t isteam_guest_memory_read_execute_prefix(ISteamGuestMemory *memory, uint64_t offset,
                                               uint8_t *destination, size_t maximumLength) {
    if (!memory || !destination || maximumLength == 0 || offset >= memory->size) return 0;
    const uint64_t pageRemaining = pageSize - (offset % pageSize);
    const uint64_t amount = std::min<uint64_t>(
        std::min<uint64_t>(static_cast<uint64_t>(maximumLength), pageRemaining),
        memory->size - offset);
    const size_t count = static_cast<size_t>(amount);
    return isteam_guest_memory_read_execute(memory, offset, destination, count) ? count : 0;
}

bool isteam_guest_memory_write(ISteamGuestMemory *memory, uint64_t offset,
                               const uint8_t *source, size_t length) {
    if (!memory || (length && !source)
        || offset > memory->size || length > memory->size - offset) {
        return false;
    }
    if (!length) return true;

    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!rangeHasPermissionLocked(memory, offset, length, permissionWrite)) return false;
        const uint64_t lastAddress = offset + length - 1;
        if (memory->usesDensePages) {
            if (offset / pageSize == lastAddress / pageSize) {
                const uint64_t pageIndex = offset / pageSize;
                const size_t pageOffset = static_cast<size_t>(offset % pageSize);
                Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
                if (!page) page = allocateDensePage(memory, pageIndex);
                if (!page) return false;
                std::memcpy(page->bytes.data() + pageOffset, source, length);
                return true;
            }
            size_t completed = 0;
            while (completed < length) {
                const uint64_t address = offset + completed;
                const uint64_t pageIndex = address / pageSize;
                const size_t pageOffset = static_cast<size_t>(address % pageSize);
                const size_t amount = std::min(length - completed,
                                               static_cast<size_t>(pageSize) - pageOffset);
                Page *page = memory->densePages[static_cast<size_t>(pageIndex)].get();
                if (!page) page = allocateDensePage(memory, pageIndex);
                if (!page) return false;
                std::memcpy(page->bytes.data() + pageOffset, source + completed, amount);
                completed += amount;
            }
            return true;
        }
        if (offset / pageSize == lastAddress / pageSize) {
            const uint64_t pageIndex = offset / pageSize;
            const size_t pageOffset = static_cast<size_t>(offset % pageSize);
            auto found = memory->pages.find(pageIndex);
            if (found == memory->pages.end()) {
                auto page = std::unique_ptr<Page>(new (std::nothrow) Page{});
                if (!page) return false;
                found = memory->pages.emplace(pageIndex, std::move(page)).first;
            }
            if (!found->second) return false;
            std::memcpy(found->second->bytes.data() + pageOffset, source, length);
            return true;
        }
        size_t completed = 0;
        while (completed < length) {
            const uint64_t address = offset + completed;
            const uint64_t pageIndex = address / pageSize;
            const size_t pageOffset = static_cast<size_t>(address % pageSize);
            const size_t amount = std::min(length - completed,
                                           static_cast<size_t>(pageSize) - pageOffset);

            auto found = memory->pages.find(pageIndex);
            if (found == memory->pages.end()) {
                // Allocate before inserting. The old operator[] path left a
                // null map entry on allocation failure and could throw from
                // unordered_map growth across this C ABI boundary.
                auto page = std::unique_ptr<Page>(new (std::nothrow) Page{});
                if (!page) return false;
                found = memory->pages.emplace(pageIndex, std::move(page)).first;
            }
            if (!found->second) return false;

            std::memcpy(found->second->bytes.data() + pageOffset,
                        source + completed, amount);
            completed += amount;
        }
        return true;
    } catch (...) {
        // No C++ allocation/locking exception may escape into Swift/C callers.
        return false;
    }
}

bool isteam_guest_memory_zero(ISteamGuestMemory *memory, uint64_t offset,
                              uint64_t length) {
    if (!memory || offset > memory->size || length > memory->size - offset) {
        return false;
    }
    if (!length) return true;

    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (!rangeHasPermissionLocked(memory, offset, length, permissionWrite)) return false;
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
                    if (pageStart >= end || pageEnd <= offset) {
                        ++index;
                        continue;
                    }
                    const uint64_t overlapStart = std::max(offset, pageStart);
                    const uint64_t overlapEnd = std::min(end, pageEnd);
                    const size_t pageOffset = static_cast<size_t>(overlapStart - pageStart);
                    const size_t amount = static_cast<size_t>(overlapEnd - overlapStart);
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) {
                        removeDensePage(memory, pageIndex);
                    } else {
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
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) {
                        removeDensePage(memory, pageIndex);
                    } else {
                        std::fill_n(page->bytes.data() + pageOffset, amount, uint8_t{0});
                    }
                }
            }
            return true;
        }
        if (rangePageCount > static_cast<uint64_t>(memory->pages.size())) {
            // Large sparse ranges are cheaper to clear by visiting allocated pages
            // than by hashing every page number in the requested address range.
            for (auto it = memory->pages.begin(); it != memory->pages.end();) {
                const uint64_t pageStart = it->first * pageSize;
                if (pageStart >= memory->size) {
                    it = memory->pages.erase(it);
                    continue;
                }
                const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                const uint64_t pageEnd = pageStart + pageLength;
                if (pageStart >= end || pageEnd <= offset) {
                    ++it;
                    continue;
                }
                if (!it->second) {
                    it = memory->pages.erase(it);
                    continue;
                }
                const uint64_t overlapStart = std::max(offset, pageStart);
                const uint64_t overlapEnd = std::min(end, pageEnd);
                const size_t pageOffset = static_cast<size_t>(overlapStart - pageStart);
                const size_t amount = static_cast<size_t>(overlapEnd - overlapStart);
                if (pageOffset == 0 && amount == pageLength) {
                    it = memory->pages.erase(it);
                } else {
                    std::memset(it->second->bytes.data() + pageOffset, 0, amount);
                    ++it;
                }
            }
        } else {
            for (uint64_t address = offset; address < end;) {
                const uint64_t pageIndex = address / pageSize;
                const size_t pageOffset = static_cast<size_t>(address % pageSize);
                const size_t amount = static_cast<size_t>(
                    std::min(end - address, pageSize - pageOffset));
                const auto found = memory->pages.find(pageIndex);
                if (found != memory->pages.end() && found->second) {
                    const uint64_t pageStart = pageIndex * pageSize;
                    const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);
                    if (pageOffset == 0 && static_cast<uint64_t>(amount) == pageLength) {
                        memory->pages.erase(found);
                    } else {
                        std::memset(found->second->bytes.data() + pageOffset, 0, amount);
                    }
                }
                address += amount;
            }
        }
        return true;
    } catch (...) {
        return false;
    }
}

void isteam_guest_memory_clear(ISteamGuestMemory *memory) {
    if (!memory) return;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        if (memory->usesDensePages) {
            for (uint64_t pageIndex : memory->denseAllocatedPageIndices) {
                memory->densePages[static_cast<size_t>(pageIndex)].reset();
            }
            memory->denseAllocatedPageIndices.clear();
        } else {
            memory->pages.clear();
        }
        if (memory->usesDensePages) {
            std::fill(memory->densePagePermissions.begin(), memory->densePagePermissions.end(), uint8_t{0});
        } else {
            memory->sparsePagePermissions.clear();
        }
        memory->permissionsEnabled = false;
    } catch (...) {
        // This void API has no error channel; keep exceptions inside C++.
    }
}

size_t isteam_guest_memory_allocated_pages(ISteamGuestMemory *memory) {
    if (!memory) return 0;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        return memory->usesDensePages
            ? memory->denseAllocatedPageIndices.size()
            : memory->pages.size();
    } catch (...) {
        return 0;
    }
}

}
