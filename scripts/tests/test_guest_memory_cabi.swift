import Foundation

// The standalone dispatcher target only needs configure's error case; the app
// defines the complete GuestEngineError in GuestMachine.swift.
enum GuestEngineError: Error {
    case invalidState(String)
}

@main
struct GuestMemoryCABIIntegrationTests {
    private static func returned(_ outcome: LinuxSyscallDispatcher.Outcome?) -> UInt64 {
        guard case let .returned(value)? = outcome else {
            preconditionFailure("Expected a returned Linux syscall result.")
        }
        return value
    }

    static func main() throws {
        let page = GuestMemory.pageSize
        let memory = GuestMemory(size: page * 4)
        precondition(memory.isAvailable, "Production GuestMemory C ABI allocation failed.")
        precondition(memory.allocatedPageCount == 0)

        let zeroPage = Data(repeating: 0, count: 8)
        precondition(memory.read(offset: 0, length: zeroPage.count) == zeroPage,
                     "Sparse unmapped reads must return zero before permission enforcement.")

        // Populate guest bytes before enabling the address-space permission map.
        let entry = Data([0x90, 0x90, 0x90, 0xC3])
        let boundaryPrefix = Data([0x48, 0xB8])
        let boundarySuffix = Data([0x11, 0x22])
        precondition(memory.write(entry, offset: 0))
        precondition(memory.write(boundaryPrefix, offset: page - 2))
        precondition(memory.write(boundarySuffix, offset: page))
        precondition(memory.beginMapping())

        // ELF-like RX and RW pages plus an explicit PROT_NONE page.
        precondition(memory.map(offset: 0, length: page, permissions: 0x5))
        precondition(memory.map(offset: page, length: page, permissions: 0x3))
        precondition(memory.map(offset: page * 2, length: page, permissions: 0x0))
        precondition(memory.hasMappedPages(offset: 0, length: page * 3))
        precondition(memory.read(offset: 0, length: entry.count) == entry)
        precondition(memory.readExecuteByte(offset: 0) == 0x90)
        precondition(!memory.write(entry, offset: 0), "RX pages must reject guest writes.")
        precondition(!memory.readExecuteByte(offset: page), "RW pages must reject instruction fetch.")
        precondition(memory.read(offset: page, length: 2) == boundarySuffix)

        var instructionWindow = [UInt8](repeating: 0xA5, count: 4)
        let firstPrefix = memory.readPrefix(offset: page - 2, maximumLength: 4,
                                            into: &instructionWindow)
        precondition(firstPrefix == 2, "Execute fetch must stop at the RX/RW boundary.")
        precondition(instructionWindow == [0x48, 0xB8, 0xA5, 0xA5])

        // mprotect must update the same native permission map consumed by fetch.
        precondition(memory.protect(offset: page, length: page, permissions: 0x5))
        instructionWindow = [UInt8](repeating: 0xA5, count: 4)
        let completePrefix = memory.readPrefix(offset: page - 2, maximumLength: 4,
                                               into: &instructionWindow)
        precondition(completePrefix == 4)
        precondition(instructionWindow == [0x48, 0xB8, 0x11, 0x22])
        precondition(!memory.write(boundarySuffix, offset: page))

        // PROT_NONE denies all access paths through the production Swift wrapper.
        precondition(memory.read(offset: page * 2, length: 1) == nil)
        precondition(memory.readExecuteByte(offset: page * 2) == nil)
        precondition(!memory.writeByte(0x7F, offset: page * 2))

        // munmap is idempotent across holes and releases the old backing page.
        precondition(memory.unmap(offset: page, length: page))
        precondition(!memory.hasMappedPages(offset: page, length: page))
        precondition(memory.read(offset: page, length: 1) == nil)
        precondition(memory.unmap(offset: page * 3, length: page),
                     "munmap over an unmapped hole must succeed.")
        precondition(memory.map(offset: page, length: page, permissions: 0x3))
        precondition(memory.read(offset: page, length: 4) == Data(repeating: 0, count: 4),
                     "Remapping an unmapped page must not expose stale backing bytes.")
        precondition(memory.write(boundarySuffix, offset: page))
        precondition(memory.read(offset: page, length: 2) == boundarySuffix)

        // Invalid and overflowing ranges must fail without changing valid pages.
        precondition(!memory.map(offset: UInt64.max - page + 1, length: page,
                                 permissions: 0x3))
        precondition(!memory.protect(offset: page * 3, length: page, permissions: 0x5))
        precondition(memory.read(offset: page, length: 2) == boundarySuffix)

        // Exercise the production Linux syscall dispatcher against the same
        // Swift wrapper and native C++ page-permission implementation.
        let syscallMemory = GuestMemory(size: 16 * 1024 * 1024)
        precondition(syscallMemory.isAvailable)
        precondition(syscallMemory.beginMapping())
        let dispatcher = LinuxSyscallDispatcher(memory: syscallMemory)
        try dispatcher.configure(programBreak: 1 * 1024 * 1024,
                                 stackBase: 8 * 1024 * 1024)

        func syscall(_ number: UInt64,
                     _ arg0: UInt64 = 0, _ arg1: UInt64 = 0,
                     _ arg2: UInt64 = 0, _ arg3: UInt64 = 0,
                     _ arg4: UInt64 = 0, _ arg5: UInt64 = 0) -> UInt64 {
            Self.returned(dispatcher.dispatch(number: number,
                                              arguments: [arg0, arg1, arg2, arg3, arg4, arg5]))
        }

        let initialBreak: UInt64 = 1 * 1024 * 1024
        let expandedBreak: UInt64 = 7 * 1024 * 1024
        let shrinkBreak: UInt64 = 3 * 1024 * 1024 / 2
        let stackGuard: UInt64 = 8 * 1024 * 1024 - page
        precondition(syscall(12, expandedBreak) == expandedBreak,
                     "brk must grow to the stack guard when no mmap ranges exist.")
        precondition(syscallMemory.hasMappedPages(offset: initialBreak,
                                                  length: expandedBreak - initialBreak))

        // First mmap must start at or above the expanded break, and NOREPLACE
        // must fail atomically when the requested pages are already mapped.
        let firstMapping = syscall(9, 0, page, 0x3, 0x22, UInt64.max, 0)
        precondition(firstMapping >= expandedBreak && firstMapping < stackGuard)
        precondition(syscallMemory.hasMappedPages(offset: firstMapping, length: page))
        precondition(syscallMemory.writeByte(0xAB, offset: firstMapping))
        let noReplace = syscall(9, firstMapping, page, 0x3, 0x100022, UInt64.max, 0)
        precondition(noReplace == UInt64(bitPattern: Int64(-17)),
                     "MAP_FIXED_NOREPLACE must reject existing mappings with EEXIST.")

        // MAP_FIXED replaces the mapping and must not expose the previous bytes.
        let replacement = syscall(9, firstMapping, page, 0x3, 0x32, UInt64.max, 0)
        precondition(replacement == firstMapping)
        precondition(syscallMemory.read(offset: firstMapping, length: 1) == Data([0]))

        // brk may shrink below an existing mapping but must never grow into it.
        precondition(syscall(12, firstMapping + page) == expandedBreak)
        precondition(syscall(12, shrinkBreak) == shrinkBreak)
        let secondMapping = syscall(9, 0, page, 0x3, 0x22, UInt64.max, 0)
        precondition(secondMapping == shrinkBreak,
                     "After brk shrink, mmap should reuse the released range before later mappings.")
        precondition(syscall(11, secondMapping, page) == 0)
        precondition(syscall(11, firstMapping, page) == 0)
        precondition(!syscallMemory.hasMappedPages(offset: firstMapping, length: page))
        precondition(syscall(12, stackGuard) == stackGuard,
                     "brk must reach the stack guard again after all mmap ranges are removed.")

        print("Production Swift GuestMemory + NativeGuestMemory C ABI permission, execute-fetch, mmap/mprotect/munmap and remap integration passed.")
    }
}
