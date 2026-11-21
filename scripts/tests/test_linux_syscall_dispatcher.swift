import Foundation

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    func read(offset: UInt64, length: Int) -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { return nil }
        return Data(bytes[Int(offset)..<Int(offset) + length])
    }

    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        return true
    }

    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { write(Data($0), offset: offset) }
    }

    func readUInt64(offset: UInt64) -> UInt64? {
        guard let data = read(offset: offset, length: 8) else { return nil }
        return data.enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << ($1.offset * 8)
        }
    }

    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset, length <= UInt64(Int.max) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset + length), with: repeatElement(0, count: Int(length)))
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
        let dispatcher = LinuxSyscallDispatcher(memory: memory)
        try dispatcher.configure(programBreak: 0x40000, stackBase: 0x3F0000)

        let initialBreak = dispatcher.dispatch(number: 12, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let initial) = initialBreak else { preconditionFailure() }
        precondition(initial == 0x40000)

        let grown = dispatcher.dispatch(number: 12, arguments: [0x42000, 0, 0, 0, 0, 0])!
        guard case .returned(let grownValue) = grown else { preconditionFailure() }
        precondition(grownValue == 0x42000)

        let shrunk = dispatcher.dispatch(number: 12, arguments: [0x41000, 0, 0, 0, 0, 0])!
        guard case .returned(let shrunkValue) = shrunk else { preconditionFailure() }
        precondition(shrunkValue == 0x41000)

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
        let nextHinted = dispatcher.dispatch(number: 9, arguments: [0x47000, 8192, 3, 0x22, UInt64.max, 0])!
        guard case .returned(let nextHintedAddress) = nextHinted else { preconditionFailure() }
        precondition(nextHintedAddress == 0x49000)

        precondition(memory.write(Data([4, 5, 6]), offset: mapped + 4096))
        let protection = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 1, 0, 0, 0])!
        guard case .returned(let protectionValue) = protection else { preconditionFailure() }
        precondition(protectionValue == 0)
        let advice = dispatcher.dispatch(number: 28, arguments: [mapped, 4096, 0, 0, 0, 0])!
        guard case .returned(let adviceValue) = advice else { preconditionFailure() }
        precondition(adviceValue == 0)

        let fixed = dispatcher.dispatch(number: 9, arguments: [mapped, 4096, 3, 0x32, UInt64.max, 0])!
        guard case .returned(let fixedAddress) = fixed else { preconditionFailure() }
        precondition(fixedAddress == mapped)
        precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: mapped + 4096, length: 3) == Data([4, 5, 6]))

        let noReplace = dispatcher.dispatch(number: 9, arguments: [mapped, 4096, 3, 0x100022, UInt64.max, 0])!
        guard case .returned(let noReplaceValue) = noReplace else { preconditionFailure() }
        precondition(noReplaceValue == UInt64(bitPattern: Int64(-17)))

        let unmap = dispatcher.dispatch(number: 11, arguments: [mapped, 8192, 0, 0, 0, 0])!
        guard case .returned(let unmapValue) = unmap else { preconditionFailure() }
        precondition(unmapValue == 0)
        precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))
        precondition(memory.read(offset: mapped + 4096, length: 3) == Data([0, 0, 0]))

        let protectionAfterUnmap = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 1, 0, 0, 0])!
        guard case .returned(let protectionAfterUnmapValue) = protectionAfterUnmap else { preconditionFailure() }
        precondition(protectionAfterUnmapValue == UInt64(bitPattern: Int64(-12)))

        let invalidMmapFD = dispatcher.dispatch(number: 9, arguments: [0, 4096, 3, 0x22, 0, 0])!
        guard case .returned(let invalidMmapFDValue) = invalidMmapFD else { preconditionFailure() }
        precondition(invalidMmapFDValue == UInt64(bitPattern: Int64(-22)))

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

        let random = dispatcher.dispatch(number: 318, arguments: [0x40800, 32, 0, 0, 0, 0])!
        guard case .returned(let randomValue) = random else { preconditionFailure() }
        precondition(randomValue == 32)

        let clock = dispatcher.dispatch(number: 228, arguments: [1, 0x1100, 0, 0, 0, 0])!
        guard case .returned(let clockValue) = clock else { preconditionFailure() }
        precondition(clockValue == 0)
        precondition(memory.readUInt64(offset: 0x1100) != nil)

        let badTimezone = dispatcher.dispatch(number: 96, arguments: [0x3F0000, UInt64.max, 0, 0, 0, 0])!
        guard case .returned(let badTimezoneValue) = badTimezone else { preconditionFailure() }
        precondition(badTimezoneValue == UInt64(bitPattern: Int64(-14)))

        let identity = dispatcher.dispatch(number: 39, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let pid) = identity else { preconditionFailure() }
        precondition(pid == 1)
        precondition(dispatcher.dispatch(number: 9999, arguments: [0, 0, 0, 0, 0, 0]) == nil)

        dispatcher.reset()
        precondition(memory.readUInt64(offset: 0x40800) == 0)
        precondition(memory.readUInt64(offset: mapped) == 0)
        precondition(memory.readUInt64(offset: hintedAddress) == 0)
        let resetBreak = dispatcher.dispatch(number: 12, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let resetValue) = resetBreak else { preconditionFailure() }
        precondition(resetValue == 0x40000)

        print("Linux x86-64 brk/mmap/munmap/mprotect/time/random/identity and reset tests passed")
    }
}
