import Foundation

/// Exercises the production Swift GuestMemory wrapper against the real native
/// C++ implementation and C ABI. The syscall-dispatcher harness uses a Swift
/// test double; this target verifies the app's actual memory boundary.
@main
struct GuestMemoryNativeIntegrationTests {
    static func main() {
        let memory = GuestMemory(size: 64 * 1024)
        precondition(memory.isAvailable, "NativeGuestMemory C ABI did not create a guest memory object")
        precondition(memory.beginMapping(), "Could not enable guest page permissions")

        let page: UInt64 = 0x1000
        let length = GuestMemory.pageSize
        precondition(memory.map(offset: page, length: length, permissions: 3),
                     "Could not map a read/write guest page")
        precondition(memory.hasMappedPages(offset: page, length: length))
        precondition(memory.writeByte(0x90, offset: page))
        precondition(memory.readByte(offset: page) == 0x90)

        // A read/write page must not be fetchable as guest instructions.
        precondition(memory.readExecuteByte(offset: page) == nil)
        var instructionBytes = [UInt8](repeating: 0, count: 1)
        precondition(memory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == 0)

        // RX protection enables instruction fetch but rejects guest writes.
        precondition(memory.protect(offset: page, length: length, permissions: 5))
        precondition(memory.readExecuteByte(offset: page) == 0x90)
        instructionBytes[0] = 0
        precondition(memory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == 1)
        precondition(instructionBytes[0] == 0x90)
        precondition(!memory.writeByte(0xCC, offset: page))
        precondition(memory.readByte(offset: page) == 0x90)

        // Read-only protection keeps data readable while instruction fetch fails.
        precondition(memory.protect(offset: page, length: length, permissions: 1))
        precondition(memory.readByte(offset: page) == 0x90)
        precondition(memory.readExecuteByte(offset: page) == nil)
        instructionBytes[0] = 0
        precondition(memory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == 0)

        // Unmapping must remove both the permission metadata and backing page.
        precondition(memory.unmap(offset: page, length: length))
        precondition(!memory.hasMappedPages(offset: page, length: length))
        precondition(memory.readByte(offset: page) == nil)
        precondition(memory.readExecuteByte(offset: page) == nil)
        precondition(memory.allocatedPageCount == 0)

        memory.clear()
        print("Production Swift GuestMemory + NativeGuestMemory C++ permission/execute integration passed")
    }
}
