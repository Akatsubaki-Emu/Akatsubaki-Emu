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
    func write(_ message: String) { messages.append(message) }
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

        let unmap = dispatcher.dispatch(number: 11, arguments: [mapped, 8192, 0, 0, 0, 0])!
        guard case .returned(let unmapValue) = unmap else { preconditionFailure() }
        precondition(unmapValue == 0)
        precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))

        let protection = dispatcher.dispatch(number: 10, arguments: [mapped, 4096, 1, 0, 0, 0])!
        guard case .returned(let protectionValue) = protection else { preconditionFailure() }
        precondition(protectionValue == 0)

        let random = dispatcher.dispatch(number: 318, arguments: [0x40800, 32, 0, 0, 0, 0])!
        guard case .returned(let randomValue) = random else { preconditionFailure() }
        precondition(randomValue == 32)

        let clock = dispatcher.dispatch(number: 228, arguments: [1, 0x1100, 0, 0, 0, 0])!
        guard case .returned(let clockValue) = clock else { preconditionFailure() }
        precondition(clockValue == 0)
        precondition(memory.readUInt64(offset: 0x1100) != nil)

        let identity = dispatcher.dispatch(number: 39, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let pid) = identity else { preconditionFailure() }
        precondition(pid == 1)
        precondition(dispatcher.dispatch(number: 9999, arguments: [0, 0, 0, 0, 0, 0]) == nil)

        dispatcher.reset()
        precondition(memory.readUInt64(offset: 0x40800) == 0)
        precondition(memory.readUInt64(offset: mapped) == 0)
        let resetBreak = dispatcher.dispatch(number: 12, arguments: [0, 0, 0, 0, 0, 0])!
        guard case .returned(let resetValue) = resetBreak else { preconditionFailure() }
        precondition(resetValue == 0x40000)

        print("Linux x86-64 brk/mmap/munmap/mprotect/time/random/identity and reset tests passed")
    }
}
