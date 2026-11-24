#ifndef NativeGuestMemory_h
#define NativeGuestMemory_h
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ISteamGuestMemory ISteamGuestMemory;
typedef enum ISteamGuestMemoryTransactionResult {
    ISTEAM_GUEST_MEMORY_TRANSACTION_SUCCESS = 0,
    ISTEAM_GUEST_MEMORY_TRANSACTION_INVALID = 1,
    ISTEAM_GUEST_MEMORY_TRANSACTION_ALREADY_MAPPED = 2,
    ISTEAM_GUEST_MEMORY_TRANSACTION_ALLOCATION_FAILED = 3
} ISteamGuestMemoryTransactionResult;
ISteamGuestMemory *isteam_guest_memory_create(uint64_t size);
void isteam_guest_memory_destroy(ISteamGuestMemory *memory);
uint64_t isteam_guest_memory_size(const ISteamGuestMemory *memory);
bool isteam_guest_memory_begin_mapping(ISteamGuestMemory *memory);
bool isteam_guest_memory_map(ISteamGuestMemory *memory, uint64_t offset, uint64_t length, uint8_t permissions, bool merge);
bool isteam_guest_memory_protect(ISteamGuestMemory *memory, uint64_t offset, uint64_t length, uint8_t permissions);
bool isteam_guest_memory_unmap(ISteamGuestMemory *memory, uint64_t offset, uint64_t length);
int isteam_guest_memory_map_transaction(ISteamGuestMemory *memory, uint64_t offset, uint64_t length, uint8_t permissions, bool replaceExisting);
int isteam_guest_memory_resize_break(ISteamGuestMemory *memory, uint64_t oldBreak, uint64_t newBreak);
bool isteam_guest_memory_has_mapped_pages(ISteamGuestMemory *memory, uint64_t offset, uint64_t length);
bool isteam_guest_memory_read_execute(ISteamGuestMemory *memory, uint64_t offset, uint8_t *destination, size_t length);
size_t isteam_guest_memory_read_execute_prefix(ISteamGuestMemory *memory, uint64_t offset, uint8_t *destination, size_t maximumLength);
bool isteam_guest_memory_read(ISteamGuestMemory *memory, uint64_t offset, uint8_t *destination, size_t length);
bool isteam_guest_memory_write(ISteamGuestMemory *memory, uint64_t offset, const uint8_t *source, size_t length);
bool isteam_guest_memory_zero(ISteamGuestMemory *memory, uint64_t offset, uint64_t length);
void isteam_guest_memory_clear(ISteamGuestMemory *memory);
size_t isteam_guest_memory_allocated_pages(ISteamGuestMemory *memory);
#ifdef ISTEAM_GUEST_MEMORY_TESTING
typedef void (*ISteamGuestMemoryReadExecuteTestHook)(void *context);
void isteam_guest_memory_set_read_execute_test_hook(ISteamGuestMemoryReadExecuteTestHook hook, void *context);
void isteam_guest_memory_set_allocation_failure_countdown(int64_t countdown);
#endif
#ifdef __cplusplus
}
#endif
#endif
