import Foundation

@main
struct GuestMemoryCABIIntegrationTests {
    static func main() {
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

        print("Production Swift GuestMemory + NativeGuestMemory C ABI permission, execute-fetch, mmap/mprotect/munmap and remap integration passed.")
    }
}
