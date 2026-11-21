#include "NativeGuestMemory.h"

#include <array>
#include <cassert>
#include <cstdint>
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

    // Range validation must reject overflow/out-of-bounds without mutation.
    assert(!isteam_guest_memory_read(memory, pageSize * 3, roundTrip.data(), 1));
    assert(!isteam_guest_memory_write(memory, pageSize * 3, payload.data(), 1));
    assert(!isteam_guest_memory_zero(memory, pageSize * 3, 1));
    assert(!isteam_guest_memory_read(memory, UINT64_MAX, roundTrip.data(), 2));

    isteam_guest_memory_clear(memory);
    assert(isteam_guest_memory_allocated_pages(memory) == 0);
    isteam_guest_memory_destroy(memory);
    assert(isteam_guest_memory_read(nullptr, 0, nullptr, 0) == false);
    return 0;
}
