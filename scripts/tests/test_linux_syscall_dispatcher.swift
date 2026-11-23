import Foundation

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]
    private let pageSize: UInt64 = 4096
    private var permissionsEnabled = false
    private var pagePermissions: [UInt64: UInt8] = [:]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    func beginMapping() -> Bool {
        pagePermissions.removeAll(keepingCapacity: true)
        permissionsEnabled = true
        return true
    }

    func map(offset: UInt64, length: UInt64, permissions: UInt8, merge: Bool = false) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0,
              length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last {
            let old = pagePermissions[page] ?? 0
            pagePermissions[page] = merge ? old | permissions : permissions
        }
        return true
    }

    func protect(offset: UInt64, length: UInt64, permissions: UInt8) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0,
              offset % pageSize == 0, length > 0,
              offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last where pagePermissions[page] == nil { return false }
        for page in first...last { pagePermissions[page] = permissions }
        return true
    }

    func unmap(offset: UInt64, length: UInt64) -> Bool {
        guard permissionsEnabled, offset % pageSize == 0, length > 0,
              offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last {
            pagePermissions.removeValue(forKey: page)
            let start = page * pageSize
            let end = min(size, start + pageSize)
            if start < end {
                bytes.replaceSubrange(Int(start)..<Int(end),
                                      with: repeatElement(0, count: Int(end - start)))
            }
        }
        return true
    }

    func permission(at offset: UInt64) -> UInt8? { pagePermissions[offset / pageSize] }

    func hasMappedPages(offset: UInt64, length: UInt64) -> Bool {
        guard length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        return (first...last).contains { pagePermissions[$0] != nil }
    }

    func read(offset: UInt64, length: Int) -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { return nil }
        return Data(bytes[Int(offset)..<Int(offset) + length])
    }

    func read(offset: UInt64, length: Int, into data: inout Data, destinationOffset: Int) -> Bool {
        guard length >= 0, destinationOffset >= 0, destinationOffset <= data.count,
              length <= data.count - destinationOffset, offset <= size,
              UInt64(length) <= size - offset else { return false }
        if length == 0 { return true }
        let start = Int(offset)
        data.replaceSubrange(destinationOffset..<(destinationOffset + length),
                             with: bytes[start..<(start + length)])
        return true
    }

    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        return true
    }

    func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 16 else { return false }
        let start = Int(offset)
        for index in 0..<8 {
            bytes[start + index] = UInt8(truncatingIfNeeded: first >> (index * 8))
            bytes[start + 8 + index] = UInt8(truncatingIfNeeded: second >> (index * 8))
        }
        return true
    }

    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { write(Data($0), offset: offset) }
    }

    func readUInt64(offset: UInt64) -> UInt64? {
        guard let data = read(offset: offset, length: 8) else { return nil }
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }

    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset, length <= UInt64(Int.max) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset + length),
                              with: repeatElement(0, count: Int(length)))
        return true
    }
}

final class EmulationLog {
    static let shared = EmulationLog()
    private(set) var messages: [String] = []
    func write(_ message: String) {
        messages.append(String(decoding: message.utf8.prefix(8192), as: UTF8.self))
    }
}

enum GuestEngineError: Error {
    case invalidState(String)
}

@main
struct LinuxSyscallDispatcherTests {
    static func main() throws {
        let memory = GuestMemory(size: 4 * 1024 * 1024)
        precondition(memory.beginMapping())
        precondition(memory.map(offset: 0x1000, length: 4096, permissions: 5))
        precondition(memory.map(offset: 0x2000, length: 4096, permissions: 3))
        precondition(memory.map(offset: 0x3F0000, length: 0x10000, permissions: 3))
        let dispatcher = LinuxSyscallDispatcher(memory: memory)
        try dispatcher.configure(programBreak: 0x40000, stackBase: 0x3F0000)

        let initialBreak = dispatcher.dispatch(number: 12, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let initial) = initialBreak else { preconditionFailure() }
        precondition(initial == 0x40000)

        let grown = dispatcher.dispatch(number: 12, arguments: [0x42000, 0, 0, 0, 0, 0])!
        guard case .returned(let grownValue) = grown else { preconditionFailure() }
        precondition(grownValue == 0x42000)
        precondition(memory.permission(at: 0x40000) == 3)
        precondition(memory.permission(at: 0x41000) == 3)

        let shrunk = dispatcher.dispatch(number: 12, arguments: [0x41000, 0, 0, 0, 0, 0])!
        guard case .returned(let shrunkValue) = shrunk else { preconditionFailure() }
        precondition(shrunkValue == 0x41000)
        precondition(memory.permission(at: 0x40000) == 3)
        precondition(memory.permission(at: 0x41000) == nil)

        precondition(memory.write(Data([0xAA, 0xBB]), offset: 0x40000))
        let heapUnmap = dispatcher.dispatch(number: 11, arguments: [0x40000, 4096, 0, 0, 0, 0])!
        guard case .returned(let heapUnmapValue) = heapUnmap else { preconditionFailure() }
        precondition(heapUnmapValue == UInt64(bitPattern: Int64(-22)))
        precondition(memory.read(offset: 0x40000, length: 2) == Data([0xAA, 0xBB]))

        let mapping = dispatcher.dispatch(number: 9, arguments: [0, 8192, 3, 0x22, UInt64.max, 0])!
        guard case .returned(let mapped) = mapping else { preconditionFailure() }
        precondition(mapped >= 0x10000 && mapped % 4096 == 0)
        precondition(memory.write(Data([1, 2, 3]), offset: mapped))
        let hinted = dispatcher.dispatch(number: 9, arguments: [0x48000, 4096, 3, 0x22, UInt64.max, 0])!
        guard case .returned(let hintedAddress) = hinted else { preconditionFailure() }
        precondition(hintedAddress == 0x48000)
        precondition(memory.write(Data([7, 8, 9]), offset: hintedAddress))
        let hintedProtection = dispatcher.dispatch(number: 10, arguments: [hintedAddress, 4096, 1, 0, 0, 0])!
        guard case .returned(let hintedProtectionValue) = hintedProtection else { preconditionFailure() }
        precondition(hintedProtectionValue == 0)
        precondition(memory.permission(at: hintedAddress) == 1)
        let restoredProtection = dispatcher.dispatch(number: 10, arguments: [hintedAddress, 4096, 3, 0, 0, 0])!
        guard case .returned(let restoredProtectionValue) = restoredProtection else { preconditionFailure() }
        precondition(restoredProtectionValue == 0)
        precondition(memory.permission(at: hintedAddress) == 3)
        let nextHinted = dispatcher.dispatch(number: 9, arguments: [0x47000, 8192, 3, 0x22, UInt64.max, 0])!
        guard case .returned(let nextHintedAddress) = nextHinted else { preconditionFailure() }
        precondition(nextHintedAddress == 0x49000)

        precondition(memory.write(Data([4, 5, 6]), offset: mapped + 4096))
        let protection = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 1, 0, 0, 0])!
        guard case .returned(let protectionValue) = protection else { preconditionFailure() }
        precondition(protectionValue == 0)
        precondition(memory.permission(at: mapped) == 1)
        let noAccess = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 0, 0, 0, 0])!
        guard case .returned(let noAccessValue) = noAccess else { preconditionFailure() }
        precondition(noAccessValue == 0)
        precondition(memory.permission(at: mapped) == 0)
        let executable = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 4, 0, 0, 0])!
        guard case .returned(let executableValue) = executable else { preconditionFailure() }
        precondition(executableValue == 0)
        precondition(memory.permission(at: mapped) == 5)
        let imageReadOnly = dispatcher.dispatch(number: 10, arguments: [0x2000, 4096, 1, 0, 0, 0])!
        guard case .returned(let imageReadOnlyValue) = imageReadOnly else { preconditionFailure() }
        precondition(imageReadOnlyValue == 0)
        precondition(memory.permission(at: 0x2000) == 1)
        let imageWritable = dispatcher.dispatch(number: 10, arguments: [0x2000, 4096, 3, 0, 0, 0])!
        guard case .returned(let imageWritableValue) = imageWritable else { preconditionFailure() }
        precondition(imageWritableValue == 0)
        precondition(memory.permission(at: 0x2000) == 3)
        let stackReadOnly = dispatcher.dispatch(number: 10, arguments: [0x3F0000, 4096, 1, 0, 0, 0])!
        guard case .returned(let stackReadOnlyValue) = stackReadOnly else { preconditionFailure() }
        precondition(stackReadOnlyValue == 0)
        precondition(memory.permission(at: 0x3F0000) == 1)
        let stackWritable = dispatcher.dispatch(number: 10, arguments: [0x3F0000, 4096, 3, 0, 0, 0])!
        guard case .returned(let stackWritableValue) = stackWritable else { preconditionFailure() }
        precondition(stackWritableValue == 0)
        precondition(memory.permission(at: 0x3F0000) == 3)
        let unmappedProtection = dispatcher.dispatch(number: 10, arguments: [0x8000, 4096, 1, 0, 0, 0])!
        guard case .returned(let unmappedProtectionValue) = unmappedProtection else { preconditionFailure() }
        precondition(unmappedProtectionValue == UInt64(bitPattern: Int64(-12)))
        let unalignedProtection = dispatcher.dispatch(number: 10, arguments: [0x2001, 4096, 1, 0, 0, 0])!
        guard case .returned(let unalignedProtectionValue) = unalignedProtection else { preconditionFailure() }
        precondition(unalignedProtectionValue == UInt64(bitPattern: Int64(-22)))

        let advice = dispatcher.dispatch(number: 28, arguments: [mapped, 4096, 0, 0, 0, 0])!
        guard case .returned(let adviceValue) = advice else { preconditionFailure() }
        precondition(adviceValue == 0)

        // MAP_FIXED_NOREPLACE must see every mapped page, not only anonymous
        // mmap ranges tracked by this syscall dispatcher (PT_LOAD, heap, stack).
        for (address, marker, expectedPermissions) in [
            (UInt64(0x1000), UInt8(0xA1), UInt8(5)),
            (UInt64(0x40000), UInt8(0xA2), UInt8(3)),
            (UInt64(0x3F0000), UInt8(0xA3), UInt8(3))
        ] {
            precondition(memory.write(Data([marker]), offset: address))
            let rejected = dispatcher.dispatch(
                number: 9, arguments: [address, 4096, 3, 0x100022, UInt64.max, 0]
            )!
            guard case .returned(let rejectedValue) = rejected else { preconditionFailure() }
            precondition(rejectedValue == UInt64(bitPattern: Int64(-17)))
            precondition(memory.read(offset: address, length: 1) == Data([marker]))
            precondition(memory.permission(at: address) == expectedPermissions)
        }

        // Linux MAP_FIXED replaces existing PT_LOAD, heap and stack mappings.
        // It must clear old contents/permissions and install the requested page.
        for (address, marker) in [
            (UInt64(0x1000), UInt8(0xB1)),
            (UInt64(0x40000), UInt8(0xB2)),
            (UInt64(0x3F0000), UInt8(0xB3))
        ] {
            precondition(memory.write(Data([marker]), offset: address))
            let replaced = dispatcher.dispatch(
                number: 9, arguments: [address, 4096, 1, 0x32, UInt64.max, 0]
            )!
            guard case .returned(let replacedAddress) = replaced else { preconditionFailure() }
            precondition(replacedAddress == address)
            precondition(memory.read(offset: address, length: 1) == Data([0]))
            precondition(memory.permission(at: address) == 1)
        }

        let fixed = dispatcher.dispatch(number: 9, arguments: [mapped, 4096, 3, 0x32, UInt64.max, 0])!
        guard case .returned(let fixedAddress) = fixed else { preconditionFailure() }
        precondition(fixedAddress == mapped)
        precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: mapped + 4096, length: 3) == Data([4, 5, 6]))

        let noReplace = dispatcher.dispatch(number: 9, arguments: [mapped, 4096, 3, 0x100022, UInt64.max, 0])!
        guard case .returned(let noReplaceValue) = noReplace else { preconditionFailure() }
        precondition(noReplaceValue == UInt64(bitPattern: Int64(-17)))

        precondition(memory.write(Data([10, 11, 12]), offset: 0x4B000))
        let unmap = dispatcher.dispatch(number: 11, arguments: [0x4B000, 0x6000, 0, 0, 0, 0])!
        guard case .returned(let unmapValue) = unmap else { preconditionFailure() }
        precondition(unmapValue == 0)
        precondition(memory.read(offset: 0x4B000, length: 3) == Data([10, 11, 12]))
        precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: mapped + 4096, length: 3) == Data([4, 5, 6]))

        let protectionAfterUnmap = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 1, 0, 0, 0])!
        guard case .returned(let protectionAfterUnmapValue) = protectionAfterUnmap else { preconditionFailure() }
        precondition(protectionAfterUnmapValue == UInt64(bitPattern: Int64(-12)))

        let unmapRemainder = dispatcher.dispatch(number: 11, arguments: [mapped + 4096, 4096, 0, 0, 0, 0])!
        guard case .returned(let unmapRemainderValue) = unmapRemainder else { preconditionFailure() }
        precondition(unmapRemainderValue == 0)
        precondition(memory.read(offset: mapped + 4096, length: 3) == Data([0, 0, 0]))

        let unsupportedMmapFlags = dispatcher.dispatch(number: 9, arguments: [0, 4096, 3, 0x4022, UInt64.max, 0])!
        guard case .returned(let unsupportedMmapFlagsValue) = unsupportedMmapFlags else { preconditionFailure() }
        precondition(unsupportedMmapFlagsValue == UInt64(bitPattern: Int64(-22)))
        let invalidProtection = dispatcher.dispatch(number: 9, arguments: [0, 4096, 8, 0x22, UInt64.max, 0])!
        guard case .returned(let invalidProtectionValue) = invalidProtection else { preconditionFailure() }
        precondition(invalidProtectionValue == UInt64(bitPattern: Int64(-22)))

        let invalidMmapFD = dispatcher.dispatch(number: 9, arguments: [0, 4096, 3, 0x22, 0, 0])!
        guard case .returned(let invalidMmapFDValue) = invalidMmapFD else { preconditionFailure() }
        precondition(invalidMmapFDValue == UInt64(bitPattern: Int64(-22)))

        precondition(memory.write(Data([0xCC, 0xDD, 0xEE]), offset: 0x47000))
        precondition(memory.write(Data([0x11, 0x22, 0x33]), offset: 0x49000))
        let partialFixed = dispatcher.dispatch(number: 9, arguments: [0x47000, 8192, 3, 0x32, UInt64.max, 0])!
        guard case .returned(let partialFixedAddress) = partialFixed else { preconditionFailure() }
        precondition(partialFixedAddress == 0x47000)
        precondition(memory.read(offset: 0x47000, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: 0x48000, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: 0x49000, length: 3) == Data([0x11, 0x22, 0x33]))
        let preservedSuffixProtection = dispatcher.dispatch(number: 10, arguments: [0x49000, 4096, 1, 0, 0, 0])!
        guard case .returned(let preservedSuffixResult) = preservedSuffixProtection else { preconditionFailure() }
        precondition(preservedSuffixResult == 0)
        precondition(memory.permission(at: 0x49000) == 1)

        let outputLog = EmulationLog()
        let outputDispatcher = LinuxSyscallDispatcher(memory: memory, log: outputLog)
        try outputDispatcher.configure(programBreak: 0x41000, stackBase: 0x3F0000)
        let output = String(repeating: "x", count: 12_000)
        precondition(memory.write(Data(output.utf8), offset: 0x3F1000))
        let write = outputDispatcher.dispatch(number: 1, arguments: [1, 0x3F1000, 12_000, 0, 0, 0])!
        guard case .returned(let written) = write else { preconditionFailure() }
        precondition(written == 12_000)
        precondition(outputLog.messages.map { $0.replacingOccurrences(of: "[guest stdout] ", with: "") }.joined() == output)

        let unicodeOutput = String(repeating: "🙂", count: 3_000)
        precondition(memory.write(Data(unicodeOutput.utf8), offset: 0x3F2000))
        let unicodeWrite = outputDispatcher.dispatch(number: 1, arguments: [1, 0x3F2000, UInt64(unicodeOutput.utf8.count), 0, 0, 0])!
        guard case .returned(let unicodeWritten) = unicodeWrite else { preconditionFailure() }
        precondition(unicodeWritten == UInt64(unicodeOutput.utf8.count))
        precondition(outputLog.messages.suffix(3).map { $0.replacingOccurrences(of: "[guest stdout] ", with: "") }.joined() == unicodeOutput)

        let stderrLog = EmulationLog()
        let stderrDispatcher = LinuxSyscallDispatcher(memory: memory, log: stderrLog)
        try stderrDispatcher.configure(programBreak: 0x41000, stackBase: 0x3F0000)
        let stderrOutput = Data("stderr output".utf8)
        precondition(memory.write(stderrOutput, offset: 0x3F3000))
        let stderrWrite = stderrDispatcher.dispatch(
            number: 1, arguments: [2, 0x3F3000, UInt64(stderrOutput.count), 0, 0, 0]
        )!
        guard case .returned(let stderrWritten) = stderrWrite else { preconditionFailure() }
        precondition(stderrWritten == UInt64(stderrOutput.count))
        precondition(stderrLog.messages == ["[guest stderr] stderr output"])


        // Linux writev (syscall 20) concatenates bounded guest iovecs without
        // exposing guest descriptors to the host filesystem.
        let vectorFirst = Data("hello ".utf8)
        let vectorSecond = Data("world".utf8)
        precondition(memory.write(vectorFirst, offset: 0x3F3000))
        precondition(memory.write(vectorSecond, offset: 0x3F4000))
        precondition(memory.writeUInt64(0x3F3000, offset: 0x3F2000))
        precondition(memory.writeUInt64(UInt64(vectorFirst.count), offset: 0x3F2008))
        precondition(memory.writeUInt64(0x3F4000, offset: 0x3F2010))
        precondition(memory.writeUInt64(UInt64(vectorSecond.count), offset: 0x3F2018))
        let vectorWrite = outputDispatcher.dispatch(
            number: 20, arg0: 1, arg1: 0x3F2000, arg2: 2, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let vectorBytes) = vectorWrite else { preconditionFailure() }
        precondition(vectorBytes == 11)
        precondition(outputLog.messages.last == "[guest stdout] hello world")

        // A UTF-8 scalar split across iovecs must be decoded after concatenation.
        let emojiBytes = Array("🙂".utf8)
        precondition(memory.write(Data(emojiBytes[0..<2]), offset: 0x3F3000))
        precondition(memory.write(Data(emojiBytes[2..<4]), offset: 0x3F4000))
        precondition(memory.writeUInt64(0x3F3000, offset: 0x3F2000))
        precondition(memory.writeUInt64(2, offset: 0x3F2008))
        precondition(memory.writeUInt64(0x3F4000, offset: 0x3F2010))
        precondition(memory.writeUInt64(2, offset: 0x3F2018))
        let splitUnicodeWrite = outputDispatcher.dispatch(
            number: 20, arg0: 2, arg1: 0x3F2000, arg2: 2, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let splitUnicodeBytes) = splitUnicodeWrite else { preconditionFailure() }
        precondition(splitUnicodeBytes == 4)
        precondition(outputLog.messages.last == "[guest stderr] 🙂")

        let invalidVector = outputDispatcher.dispatch(
            number: 20, arg0: 1, arg1: UInt64.max - 8, arg2: 1, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let invalidVectorValue) = invalidVector else { preconditionFailure() }
        precondition(invalidVectorValue == UInt64(bitPattern: Int64(-14)))

        let invalidVectorDescriptor = outputDispatcher.dispatch(
            number: 20, arg0: 3, arg1: 0x3F2000, arg2: 2, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let invalidVectorDescriptorValue) = invalidVectorDescriptor else { preconditionFailure() }
        precondition(invalidVectorDescriptorValue == UInt64(bitPattern: Int64(-9)))

        let tooManyVectors = outputDispatcher.dispatch(
            number: 20, arg0: 1, arg1: 0x3F2000, arg2: 1025, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let tooManyVectorsValue) = tooManyVectors else { preconditionFailure() }
        precondition(tooManyVectorsValue == UInt64(bitPattern: Int64(-22)))

        precondition(memory.writeUInt64(0x3F5000, offset: 0x3F2020))
        precondition(memory.writeUInt64(1_048_577, offset: 0x3F2028))
        let oversizedVector = outputDispatcher.dispatch(
            number: 20, arg0: 1, arg1: 0x3F2020, arg2: 1, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let oversizedVectorValue) = oversizedVector else { preconditionFailure() }
        precondition(oversizedVectorValue == UInt64(bitPattern: Int64(-22)))

        let noVectors = outputDispatcher.dispatch(
            number: 20, arg0: 1, arg1: UInt64.max, arg2: 0, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let noVectorsValue) = noVectors else { preconditionFailure() }
        precondition(noVectorsValue == 0)

        let closeStdout = outputDispatcher.dispatch(number: 3, arguments: [1, 0, 0, 0, 0, 0])!
        guard case .returned(let closeStdoutValue) = closeStdout else { preconditionFailure() }
        precondition(closeStdoutValue == 0)
        let closedStdoutWrite = outputDispatcher.dispatch(number: 1, arguments: [1, 0x3F3000, 1, 0, 0, 0])!
        guard case .returned(let closedStdoutValue) = closedStdoutWrite else { preconditionFailure() }
        precondition(closedStdoutValue == UInt64(bitPattern: Int64(-9)))
        let repeatedStdoutClose = outputDispatcher.dispatch(number: 3, arguments: [1, 0, 0, 0, 0, 0])!
        guard case .returned(let repeatedStdoutCloseValue) = repeatedStdoutClose else { preconditionFailure() }
        precondition(repeatedStdoutCloseValue == UInt64(bitPattern: Int64(-9)))

        let closeStderr = outputDispatcher.dispatch(number: 3, arguments: [2, 0, 0, 0, 0, 0])!
        guard case .returned(let closeStderrValue) = closeStderr else { preconditionFailure() }
        precondition(closeStderrValue == 0)
        let closedStderrWritev = outputDispatcher.dispatch(
            number: 20, arg0: 2, arg1: 0x3F2000, arg2: 2, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let closedStderrValue) = closedStderrWritev else { preconditionFailure() }
        precondition(closedStderrValue == UInt64(bitPattern: Int64(-9)))

        let invalidClose = outputDispatcher.dispatch(number: 3, arguments: [3, 0, 0, 0, 0, 0])!
        guard case .returned(let invalidCloseValue) = invalidClose else { preconditionFailure() }
        precondition(invalidCloseValue == UInt64(bitPattern: Int64(-9)))

        outputDispatcher.reset()
        let reopenedStdoutWrite = outputDispatcher.dispatch(number: 1, arguments: [1, 0x3F3000, 1, 0, 0, 0])!
        guard case .returned(let reopenedStdoutValue) = reopenedStdoutWrite else { preconditionFailure() }
        precondition(reopenedStdoutValue == 1)

        let invalidRandomFlags = dispatcher.dispatch(number: 318, arguments: [0x40800, 8, 8, 0, 0, 0])!
        guard case .returned(let invalidRandomFlagsValue) = invalidRandomFlags else { preconditionFailure() }
        precondition(invalidRandomFlagsValue == UInt64(bitPattern: Int64(-22)))

        let random = dispatcher.dispatch(number: 318, arguments: [0x40800, 32, 0, 0, 0, 0])!
        guard case .returned(let randomValue) = random else { preconditionFailure() }
        precondition(randomValue == 32)

        let clock = dispatcher.dispatch(number: 228, arguments: [1, 0x1100, 0, 0, 0, 0])!
        guard case .returned(let clockValue) = clock else { preconditionFailure() }
        precondition(clockValue == 0)
        precondition(memory.readUInt64(offset: 0x1100) != nil)
        precondition(memory.readUInt64(offset: 0x1108)! < 1_000_000_000)

        let timeval = dispatcher.dispatch(number: 96, arguments: [0x1200, 0, 0, 0, 0, 0])!
        guard case .returned(let timevalValue) = timeval else { preconditionFailure() }
        precondition(timevalValue == 0)
        precondition(memory.readUInt64(offset: 0x1200) != nil)
        precondition(memory.readUInt64(offset: 0x1208)! < 1_000_000)

        let badTimezone = dispatcher.dispatch(number: 96, arguments: [0x3F0000, UInt64.max, 0, 0, 0, 0])!
        guard case .returned(let badTimezoneValue) = badTimezone else { preconditionFailure() }
        precondition(badTimezoneValue == UInt64(bitPattern: Int64(-14)))

        let closeStdin = dispatcher.dispatch(number: 3, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let closeStdinValue) = closeStdin else { preconditionFailure() }
        precondition(closeStdinValue == 0)
        let closedStdinRead = dispatcher.dispatch(number: 0, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let closedStdinValue) = closedStdinRead else { preconditionFailure() }
        precondition(closedStdinValue == UInt64(bitPattern: Int64(-9)))

        let identity = dispatcher.dispatch(number: 39, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let pid) = identity else { preconditionFailure() }
        precondition(pid == 1)
        let scalarIdentity = dispatcher.dispatch(
            number: 39, arg0: 0, arg1: 0, arg2: 0, arg3: 0, arg4: 0, arg5: 0
        )!
        guard case .returned(let scalarPID) = scalarIdentity else { preconditionFailure() }
        precondition(scalarPID == 1)
        precondition(dispatcher.dispatch(number: 39, arguments: [0]) == nil)
        precondition(dispatcher.dispatch(number: 9999, arguments: [0, 0, 0, 0, 0, 0]) == nil)

        dispatcher.reset()
        precondition(memory.readUInt64(offset: 0x40800) == 0)
        precondition(memory.readUInt64(offset: mapped) == 0)
        precondition(memory.readUInt64(offset: hintedAddress) == 0)
        let resetBreak = dispatcher.dispatch(number: 12, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let resetValue) = resetBreak else { preconditionFailure() }
        precondition(resetValue == 0x40000)
        let reopenedStdinRead = dispatcher.dispatch(number: 0, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let reopenedStdinValue) = reopenedStdinRead else { preconditionFailure() }
        precondition(reopenedStdinValue == 0)

        print("Linux x86-64 brk/mmap/munmap/mprotect/writev/time/random/identity and reset tests passed")
    }
}
