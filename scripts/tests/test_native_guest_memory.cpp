#include "NativeGuestMemory.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <cstdint>
#include <random>
#include <vector>

#ifdef ISTEAM_GUEST_MEMORY_TESTING
struct ReadExecuteBarrier {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false;
    bool release = false;
};

static void blockReadExecute(void *context) {
    auto *barrier = static_cast<ReadExecuteBarrier *>(context);
    std::unique_lock<std::mutex> lock(barrier->mutex);
    barrier->entered = true;
    barrier->condition.notify_all();
    barrier->condition.wait(lock, [&] { return barrier->release; });
}
#endif

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

    // Permission checks are opt-in so the loader can populate pages before
    // beginning the guest address-space mapping phase.
    ISteamGuestMemory *protectedMemory = isteam_guest_memory_create(pageSize * 3);
    assert(protectedMemory != nullptr);
    const std::array<uint8_t, 4> instruction{0x90, 0x90, 0x90, 0xC3};
    const std::array<uint8_t, 4> boundaryInstruction{0x48, 0xB8, 0x11, 0x22};
    assert(isteam_guest_memory_write(protectedMemory, 0, instruction.data(), instruction.size()));
    assert(isteam_guest_memory_write(protectedMemory, pageSize - 2,
                                    boundaryInstruction.data(), boundaryInstruction.size()));
    assert(isteam_guest_memory_begin_mapping(protectedMemory));
    assert(isteam_guest_memory_map(protectedMemory, 0, pageSize, 5, false)); // read + execute
    assert(isteam_guest_memory_map(protectedMemory, pageSize, pageSize, 3, false)); // read + write
    std::array<uint8_t, 4> protectedBytes{};
    assert(isteam_guest_memory_read(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(isteam_guest_memory_read_execute(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    std::array<uint8_t, 4> prefixBytes{};
    prefixBytes.fill(0xA5);
    assert(isteam_guest_memory_read_execute_prefix(
        protectedMemory, pageSize - 2, prefixBytes.data(), prefixBytes.size()) == 2);
    assert(prefixBytes[0] == boundaryInstruction[0]
           && prefixBytes[1] == boundaryInstruction[1]
           && prefixBytes[2] == 0xA5 && prefixBytes[3] == 0xA5);
    assert(isteam_guest_memory_protect(protectedMemory, pageSize, pageSize, 5));
    prefixBytes.fill(0xA5);
    assert(isteam_guest_memory_read_execute_prefix(
        protectedMemory, pageSize - 2, prefixBytes.data(), prefixBytes.size()) == 4);
    assert(std::equal(prefixBytes.begin(), prefixBytes.end(), boundaryInstruction.begin()));
    assert(isteam_guest_memory_protect(protectedMemory, pageSize, pageSize, 3));
    assert(!isteam_guest_memory_write(protectedMemory, 0, instruction.data(), instruction.size()));
    assert(!isteam_guest_memory_read_execute(protectedMemory, pageSize, protectedBytes.data(), protectedBytes.size()));
    assert(isteam_guest_memory_write(protectedMemory, pageSize, instruction.data(), instruction.size()));
    // Execute-only mappings are valid: PROT_EXEC does not imply PROT_READ.
    assert(isteam_guest_memory_protect(protectedMemory, 0, pageSize, 4));
    assert(isteam_guest_memory_read_execute(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(!isteam_guest_memory_read(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(!isteam_guest_memory_write(protectedMemory, 0, instruction.data(), instruction.size()));
    assert(isteam_guest_memory_protect(protectedMemory, 0, pageSize, 1)); // read-only, no execute
    assert(isteam_guest_memory_read(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(!isteam_guest_memory_read_execute(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(!isteam_guest_memory_write(protectedMemory, 0, instruction.data(), instruction.size()));
    assert(!isteam_guest_memory_protect(protectedMemory, pageSize * 2, pageSize, 0)); // unmapped
    assert(isteam_guest_memory_protect(protectedMemory, pageSize, pageSize, 0)); // PROT_NONE
    assert(!isteam_guest_memory_read(protectedMemory, pageSize, protectedBytes.data(), protectedBytes.size()));
    assert(!isteam_guest_memory_write(protectedMemory, pageSize, instruction.data(), instruction.size()));
    assert(isteam_guest_memory_map(protectedMemory, pageSize * 2, pageSize, 5, false));
    assert(isteam_guest_memory_map(protectedMemory, pageSize * 2, pageSize, 2, true)); // merge permissions
    assert(isteam_guest_memory_write(protectedMemory, pageSize * 2, instruction.data(), instruction.size()));
    assert(isteam_guest_memory_read_execute(protectedMemory, pageSize * 2, protectedBytes.data(), protectedBytes.size()));
    assert(isteam_guest_memory_unmap(protectedMemory, pageSize * 2, pageSize));
    assert(isteam_guest_memory_allocated_pages(protectedMemory) == 2);
    assert(!isteam_guest_memory_protect(protectedMemory, pageSize * 2, pageSize, 5));
    assert(!isteam_guest_memory_read_execute(protectedMemory, pageSize * 2, protectedBytes.data(), protectedBytes.size()));
    assert(isteam_guest_memory_map(protectedMemory, pageSize * 2, pageSize, 3, false));
    protectedBytes.fill(0xA5);
    assert(isteam_guest_memory_read(protectedMemory, pageSize * 2, protectedBytes.data(), protectedBytes.size()));
    for (uint8_t value : protectedBytes) assert(value == 0);
    // A range containing mapped pages and holes is safely unmapped in one pass.
    assert(isteam_guest_memory_unmap(protectedMemory, 0, pageSize * 3));
    assert(isteam_guest_memory_allocated_pages(protectedMemory) == 0);
    assert(isteam_guest_memory_unmap(protectedMemory, 0, pageSize * 3));
    assert(!isteam_guest_memory_map(protectedMemory, UINT64_MAX, 2, 3, false));
    isteam_guest_memory_clear(protectedMemory);
    assert(isteam_guest_memory_read(protectedMemory, 0, protectedBytes.data(), protectedBytes.size()));
    assert(isteam_guest_memory_write(protectedMemory, 0, instruction.data(), instruction.size()));
    isteam_guest_memory_destroy(protectedMemory);

#ifdef ISTEAM_GUEST_MEMORY_TESTING
    // Hold read_execute after permission validation. protect() must not be able
    // to revoke execute permission until the bytes have been copied.
    ISteamGuestMemory *atomicReadMemory = isteam_guest_memory_create(pageSize);
    assert(atomicReadMemory != nullptr);
    const std::array<uint8_t, 4> atomicInstruction{0x90, 0x90, 0x90, 0xC3};
    assert(isteam_guest_memory_write(atomicReadMemory, 0,
                                    atomicInstruction.data(), atomicInstruction.size()));
    assert(isteam_guest_memory_begin_mapping(atomicReadMemory));
    assert(isteam_guest_memory_map(atomicReadMemory, 0, pageSize, 5, false));

    ReadExecuteBarrier readBarrier;
    isteam_guest_memory_set_read_execute_test_hook(blockReadExecute, &readBarrier);
    std::atomic<bool> readSucceeded{false};
    std::atomic<bool> protectStarted{false};
    std::atomic<bool> protectSucceeded{false};
    std::thread reader([&] {
        std::array<uint8_t, 4> bytes{};
        readSucceeded.store(
            isteam_guest_memory_read_execute(atomicReadMemory, 0, bytes.data(), bytes.size()),
            std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(readBarrier.mutex);
        readBarrier.condition.wait(lock, [&] { return readBarrier.entered; });
    }
    std::thread protector([&] {
        protectStarted.store(true, std::memory_order_release);
        protectSucceeded.store(
            isteam_guest_memory_protect(atomicReadMemory, 0, pageSize, 3),
            std::memory_order_release);
    });
    while (!protectStarted.load(std::memory_order_acquire)) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    assert(!protectSucceeded.load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(readBarrier.mutex);
        readBarrier.release = true;
    }
    readBarrier.condition.notify_all();
    reader.join();
    protector.join();
    isteam_guest_memory_set_read_execute_test_hook(nullptr, nullptr);
    assert(readSucceeded.load(std::memory_order_acquire));
    assert(protectSucceeded.load(std::memory_order_acquire));
    std::array<uint8_t, 4> revokedBytes{};
    assert(!isteam_guest_memory_read_execute(
        atomicReadMemory, 0, revokedBytes.data(), revokedBytes.size()));
    isteam_guest_memory_destroy(atomicReadMemory);

    // MAP_FIXED replacement stages every permission node before touching old bytes.
    ISteamGuestMemory *transactional = isteam_guest_memory_create(pageSize * 4);
    assert(transactional != nullptr);
    assert(isteam_guest_memory_begin_mapping(transactional));
    assert(isteam_guest_memory_map(transactional, 0, pageSize, 3, false));
    const uint8_t originalByte = 0xA5;
    assert(isteam_guest_memory_write(transactional, 0, &originalByte, 1));
    // One old page and one new page: fail after the new permission node is staged,
    // but before destination metadata reserve/commit.
    isteam_guest_memory_set_allocation_failure_countdown(2);
    assert(isteam_guest_memory_map_transaction(
        transactional, 0, pageSize * 2, 5, true
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED);
    isteam_guest_memory_set_allocation_failure_countdown(-1);
    std::array<uint8_t, 1> preservedByte{};
    assert(isteam_guest_memory_read(transactional, 0, preservedByte.data(), 1));
    assert(preservedByte[0] == originalByte);
    assert(isteam_guest_memory_has_mapped_pages(transactional, 0, pageSize));
    assert(!isteam_guest_memory_has_mapped_pages(transactional, pageSize, pageSize));
    assert(isteam_guest_memory_map_transaction(
        transactional, 0, pageSize, 5, false
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_ALREADY_MAPPED);
    assert(isteam_guest_memory_map_transaction(
        transactional, 0, pageSize, 5, true
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS);
    preservedByte[0] = 0xA5;
    assert(isteam_guest_memory_read(transactional, 0, preservedByte.data(), 1));
    assert(preservedByte[0] == 0);
    assert(isteam_guest_memory_read_execute(transactional, 0, preservedByte.data(), 1));
    isteam_guest_memory_destroy(transactional);

    // brk growth stages all new pages first; an injected failure preserves the
    // old heap bytes and leaves every page beyond the old break unmapped.
    ISteamGuestMemory *heap = isteam_guest_memory_create(pageSize * 8);
    assert(heap != nullptr);
    assert(isteam_guest_memory_write(heap, 0, &originalByte, 1));
    assert(isteam_guest_memory_begin_mapping(heap));
    assert(isteam_guest_memory_map(heap, 0, pageSize, 3, false));
    isteam_guest_memory_set_allocation_failure_countdown(3);
    assert(isteam_guest_memory_resize_break(
        heap, pageSize, pageSize * 3
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED);
    isteam_guest_memory_set_allocation_failure_countdown(-1);
    preservedByte[0] = 0;
    assert(isteam_guest_memory_read(heap, 0, preservedByte.data(), 1));
    assert(preservedByte[0] == originalByte);
    assert(!isteam_guest_memory_has_mapped_pages(heap, pageSize, pageSize * 2));
    assert(isteam_guest_memory_resize_break(
        heap, pageSize, pageSize * 3
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS);
    assert(isteam_guest_memory_has_mapped_pages(heap, pageSize, pageSize * 2));
    const uint8_t heapMarker = 0x5A;
    assert(isteam_guest_memory_write(heap, pageSize + 128, &heapMarker, 1));
    assert(isteam_guest_memory_write(heap, pageSize * 2, &heapMarker, 1));
    assert(isteam_guest_memory_resize_break(
        heap, pageSize * 3, pageSize + 128
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS);
    preservedByte[0] = 0xA5;
    assert(isteam_guest_memory_read(heap, pageSize + 128, preservedByte.data(), 1));
    assert(preservedByte[0] == 0);
    assert(!isteam_guest_memory_has_mapped_pages(heap, pageSize * 2, pageSize));
    assert(isteam_guest_memory_resize_break(
        heap, pageSize + 128, pageSize * 3
    ) == ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS);
    assert(isteam_guest_memory_has_mapped_pages(heap, pageSize * 2, pageSize));
    isteam_guest_memory_destroy(heap);
    isteam_guest_memory_set_allocation_failure_countdown(-1);
#endif

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

    // Above the 1 GiB dense-table threshold, retain sparse-map storage.
    constexpr uint64_t sparseFallbackSize = largeSize + 1;
    ISteamGuestMemory *fallback = isteam_guest_memory_create(sparseFallbackSize);
    assert(fallback != nullptr);
    const uint8_t fallbackMarker = 0x7B;
    std::array<uint8_t, 1> fallbackValue{};
    assert(isteam_guest_memory_write(fallback, sparseFallbackSize - 1, &fallbackMarker, 1));
    assert(isteam_guest_memory_allocated_pages(fallback) == 1);
    assert(isteam_guest_memory_read(fallback, sparseFallbackSize - 1, fallbackValue.data(), 1));
    assert(fallbackValue[0] == fallbackMarker);
    assert(isteam_guest_memory_zero(fallback, largeSize, 1));
    assert(isteam_guest_memory_allocated_pages(fallback) == 0);
    isteam_guest_memory_destroy(fallback);

    // Extremely large logical memories must remain sparse and overflow-safe.
    ISteamGuestMemory *huge = isteam_guest_memory_create(UINT64_MAX);
    assert(huge != nullptr);
    assert(isteam_guest_memory_write(huge, UINT64_MAX - 1, &fallbackMarker, 1));
    fallbackValue[0] = 0;
    assert(isteam_guest_memory_read(huge, UINT64_MAX - 1, fallbackValue.data(), 1));
    assert(fallbackValue[0] == fallbackMarker);
    assert(isteam_guest_memory_begin_mapping(huge));
    const uint64_t finalPage = UINT64_MAX & ~uint64_t(4095);
    const uint64_t finalPageLength = UINT64_MAX - finalPage;
    assert(isteam_guest_memory_map(huge, finalPage, finalPageLength, 3, false));
    assert(isteam_guest_memory_write(huge, finalPage, &fallbackMarker, 1));
    // Range queries must also remain proportional to allocated pages, even
    // when the guest address space spans almost the entire uint64_t domain.
    assert(isteam_guest_memory_has_mapped_pages(huge, 0, UINT64_MAX));
    assert(!isteam_guest_memory_has_mapped_pages(huge, 0, pageSize));
    // A huge sparse unmap must visit allocated pages, not every virtual page.
    assert(isteam_guest_memory_unmap(huge, 0, UINT64_MAX));
    assert(isteam_guest_memory_allocated_pages(huge) == 0);
    assert(!isteam_guest_memory_read(huge, finalPage, fallbackValue.data(), 1));
    assert(isteam_guest_memory_zero(huge, 0, UINT64_MAX));
    assert(isteam_guest_memory_allocated_pages(huge) == 0);
    isteam_guest_memory_destroy(huge);


    // Permission-aware mappings distinguish data reads/writes from instruction fetches.
    ISteamGuestMemory *permissionMemory = isteam_guest_memory_create(pageSize * 3);
    assert(permissionMemory != nullptr);
    const std::array<uint8_t, 4> codeBytes{0x90, 0x90, 0xF4, 0xCC};
    const std::array<uint8_t, 4> dataBytes{0x11, 0x22, 0x33, 0x44};
    assert(isteam_guest_memory_write(permissionMemory, 0, codeBytes.data(), codeBytes.size()));
    assert(isteam_guest_memory_write(permissionMemory, pageSize, dataBytes.data(), dataBytes.size()));
    assert(isteam_guest_memory_begin_mapping(permissionMemory));
    assert(isteam_guest_memory_map(permissionMemory, 0, pageSize, 0x5, false)); // read + execute
    assert(isteam_guest_memory_map(permissionMemory, pageSize, pageSize, 0x3, false)); // read + write

    std::array<uint8_t, 4> executableBytes{};
    assert(isteam_guest_memory_read_execute(permissionMemory, 0, executableBytes.data(), executableBytes.size()));
    assert(executableBytes == codeBytes);
    assert(!isteam_guest_memory_write(permissionMemory, 0, dataBytes.data(), 1));
    assert(isteam_guest_memory_read(permissionMemory, pageSize, executableBytes.data(), 4));
    assert(!isteam_guest_memory_read_execute(permissionMemory, pageSize, executableBytes.data(), 4));

    std::array<uint8_t, 4> crossingFetch{};
    assert(isteam_guest_memory_read_execute_prefix(permissionMemory, pageSize - 2,
                                                    crossingFetch.data(), crossingFetch.size()) == 2);
    assert(isteam_guest_memory_protect(permissionMemory, pageSize, pageSize, 0x5));
    assert(isteam_guest_memory_read_execute_prefix(permissionMemory, pageSize - 2,
                                                    crossingFetch.data(), crossingFetch.size()) == 4);
    assert(isteam_guest_memory_protect(permissionMemory, pageSize, pageSize, 0x1));
    assert(!isteam_guest_memory_write(permissionMemory, pageSize, dataBytes.data(), 1));
    assert(isteam_guest_memory_protect(permissionMemory, 0, pageSize, 0x1));
    assert(!isteam_guest_memory_read_execute(permissionMemory, 0, executableBytes.data(), 1));
    assert(!isteam_guest_memory_protect(permissionMemory, pageSize * 2, pageSize, 0x1));

    // Permission merges support adjacent ELF PT_LOAD segments sharing a page.
    assert(isteam_guest_memory_map(permissionMemory, pageSize * 2, pageSize, 0x1, false));
    assert(isteam_guest_memory_map(permissionMemory, pageSize * 2, pageSize, 0x4, true));
    assert(isteam_guest_memory_read_execute(permissionMemory, pageSize * 2,
                                            executableBytes.data(), executableBytes.size()));
    assert(!isteam_guest_memory_write(permissionMemory, pageSize * 2, dataBytes.data(), 1));
    assert(isteam_guest_memory_map(permissionMemory, pageSize * 2, pageSize, 0x2, true));
    assert(isteam_guest_memory_write(permissionMemory, pageSize * 2, dataBytes.data(), 1));

    assert(isteam_guest_memory_unmap(permissionMemory, pageSize, pageSize));
    assert(!isteam_guest_memory_read(permissionMemory, pageSize, executableBytes.data(), 1));
    assert(!isteam_guest_memory_write(permissionMemory, pageSize, dataBytes.data(), 1));
    isteam_guest_memory_clear(permissionMemory);
    assert(isteam_guest_memory_read(permissionMemory, pageSize, executableBytes.data(), 1));
    assert(isteam_guest_memory_write(permissionMemory, pageSize, dataBytes.data(), 1));
    isteam_guest_memory_destroy(permissionMemory);

    // Execute-only and write-only mappings keep R/W/X permissions independent.
    ISteamGuestMemory *permissionModes = isteam_guest_memory_create(pageSize);
    assert(permissionModes != nullptr);
    const uint8_t permissionMarker = 0xC3;
    assert(isteam_guest_memory_write(permissionModes, 0, &permissionMarker, 1));
    assert(isteam_guest_memory_begin_mapping(permissionModes));
    assert(isteam_guest_memory_map(permissionModes, 0, pageSize, 0x4, false));
    std::array<uint8_t, 1> permissionValue{};
    assert(isteam_guest_memory_read_execute(permissionModes, 0, permissionValue.data(), 1));
    assert(!isteam_guest_memory_read(permissionModes, 0, permissionValue.data(), 1));
    assert(!isteam_guest_memory_write(permissionModes, 0, &permissionMarker, 1));
    assert(isteam_guest_memory_protect(permissionModes, 0, pageSize, 0x2));
    assert(!isteam_guest_memory_read_execute(permissionModes, 0, permissionValue.data(), 1));
    assert(!isteam_guest_memory_read(permissionModes, 0, permissionValue.data(), 1));
    assert(isteam_guest_memory_write(permissionModes, 0, &permissionMarker, 1));
    assert(isteam_guest_memory_protect(permissionModes, 0, pageSize, 0x1));
    assert(isteam_guest_memory_read(permissionModes, 0, permissionValue.data(), 1));
    assert(!isteam_guest_memory_read_execute(permissionModes, 0, permissionValue.data(), 1));
    assert(!isteam_guest_memory_write(permissionModes, 0, &permissionMarker, 1));
    isteam_guest_memory_destroy(permissionModes);

    isteam_guest_memory_clear(memory);
    assert(isteam_guest_memory_allocated_pages(memory) == 0);
    isteam_guest_memory_destroy(memory);
    assert(isteam_guest_memory_read(nullptr, 0, nullptr, 0) == false);
    return 0;
}
