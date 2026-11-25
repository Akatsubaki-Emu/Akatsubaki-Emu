import Foundation

final class EmulationLog {
    static let shared = EmulationLog()
    func write(_ message: String) {}
}

enum GuestEngineError: Error {
    case invalidState(String)
}

/// Exercises the production Swift memory wrapper, native C ABI and Linux
/// syscall dispatcher together. The larger syscall suite still uses a test
/// double; this target verifies the real app memory boundary.
@main
struct GuestMemoryNativeIntegrationTests {
    static func main() throws {
        let permissionMemory = GuestMemory(size: 64 * 1024)
        precondition(permissionMemory.isAvailable, "NativeGuestMemory C ABI did not create a guest memory object")
        precondition(permissionMemory.beginMapping(), "Could not enable guest page permissions")

        let page: UInt64 = 0x1000
        let length = GuestMemory.pageSize
        precondition(permissionMemory.map(offset: page, length: length, permissions: 3),
                     "Could not map a read/write guest page")
        precondition(permissionMemory.hasMappedPages(offset: page, length: length))
        precondition(permissionMemory.writeByte(0x90, offset: page))
        precondition(permissionMemory.readByte(offset: page) == 0x90)

        // A read/write page must not be fetchable as guest instructions.
        precondition(permissionMemory.readExecuteByte(offset: page) == nil)
        var instructionBytes = [UInt8](repeating: 0, count: 1)
        precondition(permissionMemory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == nil)

        // RX protection enables instruction fetch but rejects guest writes.
        precondition(permissionMemory.protect(offset: page, length: length, permissions: 5))
        precondition(permissionMemory.readExecuteByte(offset: page) == 0x90)
        instructionBytes[0] = 0
        precondition(permissionMemory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == 1)
        precondition(instructionBytes[0] == 0x90)
        precondition(!permissionMemory.writeByte(0xCC, offset: page))
        precondition(permissionMemory.readByte(offset: page) == 0x90)

        // Read-only protection keeps data readable while instruction fetch fails.
        precondition(permissionMemory.protect(offset: page, length: length, permissions: 1))
        precondition(permissionMemory.readByte(offset: page) == 0x90)
        precondition(permissionMemory.readExecuteByte(offset: page) == nil)
        instructionBytes[0] = 0
        precondition(permissionMemory.readPrefix(offset: page, maximumLength: 1, into: &instructionBytes) == nil)

        precondition(permissionMemory.unmap(offset: page, length: length))
        precondition(!permissionMemory.hasMappedPages(offset: page, length: length))
        precondition(permissionMemory.readByte(offset: page) == nil)
        precondition(permissionMemory.readExecuteByte(offset: page) == nil)
        precondition(permissionMemory.allocatedPageCount == 0)

        // Exercise brk/mmap/mprotect/munmap through the production dispatcher
        // and the same NativeGuestMemory object that backs every operation.
        let memory = GuestMemory(size: 256 * 1024 * 1024)
        precondition(memory.isAvailable)
        precondition(memory.beginMapping())
        let dispatcher = LinuxSyscallDispatcher(memory: memory)
        try dispatcher.configure(programBreak: 4 * 1024 * 1024, stackBase: memory.size)

        let grow = dispatcher.dispatch(number: 12, arguments: [8 * 1024 * 1024, 0, 0, 0, 0, 0])!
        guard case .returned(let grownBreak) = grow else { preconditionFailure() }
        precondition(grownBreak == 8 * 1024 * 1024)
        precondition(memory.hasMappedPages(offset: 4 * 1024 * 1024, length: 4 * 1024 * 1024))

        // PROT_NONE mappings are present but cannot be read or written.
        let noAccess = dispatcher.dispatch(number: 9, arguments: [0, 4096, 0, 0x22, UInt64.max, 0])!
        guard case .returned(let noAccessAddress) = noAccess else { preconditionFailure() }
        precondition(noAccessAddress == grownBreak)
        precondition(memory.hasMappedPages(offset: noAccessAddress, length: 4096))
        precondition(memory.readByte(offset: noAccessAddress) == nil)
        precondition(!memory.writeByte(0xA5, offset: noAccessAddress))

        let enableReadWrite = dispatcher.dispatch(number: 10, arguments: [noAccessAddress, 4096, 3, 0, 0, 0])!
        guard case .returned(let enableReadWriteResult) = enableReadWrite else { preconditionFailure() }
        precondition(enableReadWriteResult == 0)
        precondition(memory.writeByte(0xA5, offset: noAccessAddress))
        precondition(memory.readByte(offset: noAccessAddress) == 0xA5)

        // Shrinking brk releases the gap below the still-live mapping and
        // rewinds mmap placement to the new break.
        let shrink = dispatcher.dispatch(number: 12, arguments: [5 * 1024 * 1024, 0, 0, 0, 0, 0])!
        guard case .returned(let shrunkBreak) = shrink else { preconditionFailure() }
        precondition(shrunkBreak == 5 * 1024 * 1024)
        precondition(!memory.hasMappedPages(offset: 5 * 1024 * 1024, length: 3 * 1024 * 1024))
        precondition(memory.readByte(offset: noAccessAddress) == 0xA5)

        let reusedGap = dispatcher.dispatch(number: 9, arguments: [0, 4096, 3, 0x22, UInt64.max, 0])!
        guard case .returned(let reusedAddress) = reusedGap else { preconditionFailure() }
        precondition(reusedAddress == shrunkBreak)
        precondition(memory.hasMappedPages(offset: reusedAddress, length: 4096))
        precondition(memory.writeByte(0x42, offset: reusedAddress))

        // brk may not grow through the first live mmap range.
        let blockedGrowth = dispatcher.dispatch(number: 12, arguments: [9 * 1024 * 1024, 0, 0, 0, 0, 0])!
        guard case .returned(let blockedBreak) = blockedGrowth else { preconditionFailure() }
        precondition(blockedBreak == shrunkBreak)

        let makeReadOnly = dispatcher.dispatch(number: 10, arguments: [reusedAddress, 4096, 1, 0, 0, 0])!
        guard case .returned(let makeReadOnlyResult) = makeReadOnly else { preconditionFailure() }
        precondition(makeReadOnlyResult == 0)
        precondition(memory.readByte(offset: reusedAddress) == 0x42)
        precondition(!memory.writeByte(0xCC, offset: reusedAddress))

        let unmap = dispatcher.dispatch(number: 11, arguments: [reusedAddress, 4096, 0, 0, 0, 0])!
        guard case .returned(let unmapResult) = unmap else { preconditionFailure() }
        precondition(unmapResult == 0)
        precondition(!memory.hasMappedPages(offset: reusedAddress, length: 4096))
        precondition(memory.readByte(offset: reusedAddress) == nil)
        precondition(memory.hasMappedPages(offset: noAccessAddress, length: 4096))


        let fixedMemory = GuestMemory(size: 64 * 1024 * 1024)
        precondition(fixedMemory.isAvailable && fixedMemory.beginMapping())
        precondition(fixedMemory.map(offset: 0x1000, length: 4096, permissions: 5))
        let fixedDispatcher = LinuxSyscallDispatcher(memory: fixedMemory)
        try fixedDispatcher.configure(programBreak: 4 * 1024 * 1024, stackBase: fixedMemory.size)
        let noReplace = fixedDispatcher.dispatch(number: 9, arguments: [0x1000, 4096, 3, 0x100022, UInt64.max, 0])!
        guard case .returned(let noReplaceResult) = noReplace else { preconditionFailure() }
        precondition(noReplaceResult == UInt64(bitPattern: -Int64(17)))
        precondition(fixedMemory.map(offset: 0x2000, length: 4096, permissions: 3))
        precondition(fixedMemory.writeByte(0xA5, offset: 0x2000))
        let replace = fixedDispatcher.dispatch(number: 9, arguments: [0x2000, 4096, 3, 0x32, UInt64.max, 0])!
        guard case .returned(let replacedAddress) = replace else { preconditionFailure() }
        precondition(replacedAddress == 0x2000 && fixedMemory.readByte(offset: 0x2000) == 0)
        fixedMemory.clear()

        let cursorMemory = GuestMemory(size: 64 * 1024 * 1024)
        precondition(cursorMemory.isAvailable && cursorMemory.beginMapping())
        let cursorDispatcher = LinuxSyscallDispatcher(memory: cursorMemory)
        try cursorDispatcher.configure(programBreak: 4 * 1024 * 1024, stackBase: cursorMemory.size)
        let cursorGrow = cursorDispatcher.dispatch(number: 12, arguments: [8 * 1024 * 1024, 0, 0, 0, 0, 0])!
        guard case .returned(let cursorBreak) = cursorGrow else { preconditionFailure() }
        let staleHint = cursorDispatcher.dispatch(number: 9, arguments: [4 * 1024 * 1024, 4096, 2, 0x22, UInt64.max, 0])!
        guard case .returned(let clampedAddress) = staleHint else { preconditionFailure() }
        precondition(clampedAddress >= cursorBreak)
        cursorMemory.clear()

        // Exercise the actual 256 MiB mmap-placement threshold. A 384 MiB
        // guest has its initial mmap hint at 256 MiB; brk must still grow
        // beyond that hint when no mapping is live, then move mmap above heap.
        let hintMemory = GuestMemory(size: 384 * 1024 * 1024)
        precondition(hintMemory.isAvailable && hintMemory.beginMapping())
        let hintDispatcher = LinuxSyscallDispatcher(memory: hintMemory)
        let initialHintBreak: UInt64 = 240 * 1024 * 1024
        let expandedHintBreak: UInt64 = 272 * 1024 * 1024
        let shrunkHintBreak: UInt64 = 244 * 1024 * 1024
        try hintDispatcher.configure(programBreak: initialHintBreak, stackBase: hintMemory.size)

        let crossHintGrow = hintDispatcher.dispatch(
            number: 12, arguments: [expandedHintBreak, 0, 0, 0, 0, 0]
        )!
        guard case .returned(let crossHintBreak) = crossHintGrow else { preconditionFailure() }
        precondition(crossHintBreak == expandedHintBreak)
        precondition(hintMemory.hasMappedPages(
            offset: initialHintBreak, length: expandedHintBreak - initialHintBreak
        ))

        let highMapping = hintDispatcher.dispatch(
            number: 9, arguments: [0, 4096, 3, 0x22, UInt64.max, 0]
        )!
        guard case .returned(let highMappingAddress) = highMapping else { preconditionFailure() }
        precondition(highMappingAddress == expandedHintBreak)

        let shrinkPastHint = hintDispatcher.dispatch(
            number: 12, arguments: [shrunkHintBreak, 0, 0, 0, 0, 0]
        )!
        guard case .returned(let shrunkPastHint) = shrinkPastHint else { preconditionFailure() }
        precondition(shrunkPastHint == shrunkHintBreak)
        precondition(!hintMemory.hasMappedPages(
            offset: shrunkHintBreak, length: expandedHintBreak - shrunkHintBreak
        ))

        let rewoundPastHint = hintDispatcher.dispatch(
            number: 9, arguments: [0, 4096, 3, 0x22, UInt64.max, 0]
        )!
        guard case .returned(let rewoundPastHintAddress) = rewoundPastHint else { preconditionFailure() }
        precondition(rewoundPastHintAddress == shrunkHintBreak)

        // The new live mapping is now the heap ceiling.
        let blockedTarget: UInt64 = 280 * 1024 * 1024
        let blockedPastHint = hintDispatcher.dispatch(
            number: 12, arguments: [blockedTarget, 0, 0, 0, 0, 0]
        )!
        guard case .returned(let blockedPastHintBreak) = blockedPastHint else { preconditionFailure() }
        precondition(blockedPastHintBreak == shrunkHintBreak)
        hintMemory.clear()

        memory.clear()
        print("Production GuestMemory C ABI, execute permissions and Linux brk/mmap/mprotect/munmap integration passed")
    }
}
