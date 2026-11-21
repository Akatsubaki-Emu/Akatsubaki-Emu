#include "NativeGuestMemory.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <unordered_map>

namespace {
constexpr uint64_t pageSize = 4096;
using Page = std::array<uint8_t, pageSize>;
}

struct ISteamGuestMemory {
    explicit ISteamGuestMemory(uint64_t byteCount) : size(byteCount) {}

    uint64_t size;
    std::unordered_map<uint64_t, std::unique_ptr<Page>> pages;
    mutable std::mutex mutex;
};

extern "C" {

ISteamGuestMemory *isteam_guest_memory_create(uint64_t size) {
    try {
        return new ISteamGuestMemory(size);
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

bool isteam_guest_memory_read(ISteamGuestMemory *memory, uint64_t offset,
                              uint8_t *destination, size_t length) {
    if (!memory || (length && !destination)
        || offset > memory->size || length > memory->size - offset) {
        return false;
    }
    if (!length) return true;

    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        const uint64_t lastAddress = offset + length - 1;
        if (offset / pageSize == lastAddress / pageSize) {
            const size_t pageOffset = static_cast<size_t>(offset % pageSize);
            const auto found = memory->pages.find(offset / pageSize);
            if (found == memory->pages.end() || !found->second) {
                std::memset(destination, 0, length);
            } else {
                std::memcpy(destination, found->second->data() + pageOffset, length);
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
                            found->second->data() + pageOffset, amount);
            }
            completed += amount;
        }
        return true;
    } catch (...) {
        return false;
    }
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
        const uint64_t lastAddress = offset + length - 1;
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
            std::memcpy(found->second->data() + pageOffset, source, length);
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

            std::memcpy(found->second->data() + pageOffset,
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
        const uint64_t end = offset + length;
        for (uint64_t address = offset; address < end;) {
            const uint64_t pageIndex = address / pageSize;
            const size_t pageOffset = static_cast<size_t>(address % pageSize);
            const size_t amount = static_cast<size_t>(
                std::min(end - address, pageSize - pageOffset));
            const auto found = memory->pages.find(pageIndex);
            if (found != memory->pages.end() && found->second) {
                if (pageOffset == 0 && amount == pageSize) {
                    memory->pages.erase(found);
                } else {
                    std::memset(found->second->data() + pageOffset, 0, amount);
                }
            }
            address += amount;
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
        memory->pages.clear();
    } catch (...) {
        // This void API has no error channel; keep exceptions inside C++.
    }
}

size_t isteam_guest_memory_allocated_pages(ISteamGuestMemory *memory) {
    if (!memory) return 0;
    try {
        std::lock_guard<std::mutex> guard(memory->mutex);
        return memory->pages.size();
    } catch (...) {
        return 0;
    }
}

}
