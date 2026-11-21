#include "NativeGuestMemory.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <random>
#include <vector>

int main() {
    constexpr uint64_t pageSize = 4096;
    ISteamGuestMemory *memory = isteam_guest_memory_create(pageSize * 3);
    assert(memory != nullptr);
    assert(isteam_guest_memory_size(memory) == pageSize * 3);
    assert(isteam_guest_memory_allocated_pages(memory) == 0);

    // Sparse reads must return zero without allocating backing pages.
    std::array<uint8_t, 16> zeros{};
    zeros.fill(0xA5);
    assert(isteam_guest_memory_read(memory, pageSize - 8, zeros.data(), zeros.size()));
    for (uint8_t value : zeros) assert(value == 0);
    assert(isteam_guest_memory_allocated_pages(memory) == 0);

    // A cross-page write allocates exactly the two pages it touches.
    const std::array<uint8_t, 20> payload{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
        10, 11, 12, 13, 14, 15, 16, 17, 18, 19
    };
    assert(isteam_guest_memory_write(memory, pageSize - 10,
                                    payload.data(), payload.size()));
    assert(isteam_guest_memory_allocated_pages(memory) == 2);

    std::array<uint8_t, 20> roundTrip{};
    assert(isteam_guest_memory_read(memory, pageSize - 10,
                                    roundTrip.data(), roundTrip.size()));
    assert(roundTrip == payload);

    // Zeroing a range preserves sparse allocation and clears only that range.
    assert(isteam_guest_memory_zero(memory, pageSize - 10, payload.size()));
    roundTrip.fill(0xA5);
    assert(isteam_guest_memory_read(memory, pageSize - 10,
                                    roundTrip.data(), roundTrip.size()));
    for (uint8_t value : roundTrip) assert(value == 0);
    assert(isteam_guest_memory_allocated_pages(memory) == 2);

    // Whole-page zeroing releases backing pages instead of retaining empty pages.
    assert(isteam_guest_memory_zero(memory, 0, pageSize));
    assert(isteam_guest_memory_allocated_pages(memory) == 1);
    std::array<uint8_t, 32> releasedPage{};
    releasedPage.fill(0xA5);
    assert(isteam_guest_memory_read(memory, 0, releasedPage.data(), releasedPage.size()));
    for (uint8_t value : releasedPage) assert(value == 0);
    assert(isteam_guest_memory_zero(memory, pageSize, pageSize));
    assert(isteam_guest_memory_allocated_pages(memory) == 0);

    // Range validation must reject overflow/out-of-bounds without mutation.
    assert(!isteam_guest_memory_read(memory, pageSize * 3, roundTrip.data(), 1));
    assert(!isteam_guest_memory_write(memory, pageSize * 3, payload.data(), 1));
    assert(!isteam_guest_memory_zero(memory, pageSize * 3, 1));
    assert(!isteam_guest_memory_read(memory, UINT64_MAX, roundTrip.data(), 2));

    std::vector<uint8_t> reference(pageSize * 3, 0);
    std::mt19937 random(0xA7A75u);
    for (int iteration = 0; iteration < 2000; ++iteration) {
        const size_t offset = random() % reference.size();
        const size_t length = random() % (reference.size() - offset + 1);
        if (iteration % 3 == 0) {
            std::vector<uint8_t> bytes(length);
            for (uint8_t &byte : bytes) byte = static_cast<uint8_t>(random());
            assert(isteam_guest_memory_write(memory, offset, bytes.data(), bytes.size()));
            std::copy(bytes.begin(), bytes.end(), reference.begin() + offset);
        } else if (iteration % 3 == 1) {
            assert(isteam_guest_memory_zero(memory, offset, length));
            std::fill(reference.begin() + offset, reference.begin() + offset + length, 0);
        } else {
            std::vector<uint8_t> actual(length);
            assert(isteam_guest_memory_read(memory, offset, actual.data(), actual.size()));
            assert(std::equal(actual.begin(), actual.end(), reference.begin() + offset));
        }
    }

    // Clearing the final partial page should release its backing allocation too.
    constexpr uint64_t partialSize = pageSize + 17;
    ISteamGuestMemory *partial = isteam_guest_memory_create(partialSize);
    assert(partial != nullptr);
    std::array<uint8_t, 17> partialPayload{};
    partialPayload.fill(0x5A);
    assert(isteam_guest_memory_write(partial, pageSize, partialPayload.data(), partialPayload.size()));
    assert(isteam_guest_memory_allocated_pages(partial) == 1);
    assert(isteam_guest_memory_zero(partial, pageSize, partialSize - pageSize));
    assert(isteam_guest_memory_allocated_pages(partial) == 0);
    isteam_guest_memory_destroy(partial);

    // Clearing a huge sparse address range should visit allocated pages, not every page in the range.
    constexpr uint64_t largeSize = 1ULL << 30;
    ISteamGuestMemory *sparse = isteam_guest_memory_create(largeSize);
    assert(sparse != nullptr);
    const std::array<uint8_t, 4> marker{1, 2, 3, 4};
    assert(isteam_guest_memory_write(sparse, pageSize * 2, marker.data(), marker.size()));
    assert(isteam_guest_memory_write(sparse, largeSize - marker.size(), marker.data(), marker.size()));
    assert(isteam_guest_memory_allocated_pages(sparse) == 2);
    assert(isteam_guest_memory_zero(sparse, 0, largeSize));
    assert(isteam_guest_memory_allocated_pages(sparse) == 0);
    isteam_guest_memory_destroy(sparse);

    isteam_guest_memory_clear(memory);
    assert(isteam_guest_memory_allocated_pages(memory) == 0);
    isteam_guest_memory_destroy(memory);
    assert(isteam_guest_memory_read(nullptr, 0, nullptr, 0) == false);
    return 0;
}
