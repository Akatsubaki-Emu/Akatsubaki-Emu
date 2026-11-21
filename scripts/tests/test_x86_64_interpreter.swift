import Foundation

struct VMConfiguration {
    enum Architecture: String { case x86_64 }
}

protocol GuestCPUBackend {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func requestStop()
    func resume()
    func run(maxInstructions: UInt64) throws -> GuestCPUExit
}

enum GuestCPUExit: Equatable {
    case halted, instructionLimit, interrupted
    case memoryFault(address: UInt64)
    case unsupportedInstruction(address: UInt64)
    case backendUnavailable(String)
}

enum GuestEngineError: Error {
    case backendNotInstalled(VMConfiguration.Architecture)
    case invalidInstructionBudget
}

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    func readByte(offset: UInt64) -> UInt8? {
        guard offset < size else { return nil }
        return bytes[Int(offset)]
    }

    func readUInt32(offset: UInt64) -> UInt32? {
        guard offset <= size, size - offset >= 4 else { return nil }
        let index = Int(offset)
        return UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    func readUInt64(offset: UInt64) -> UInt64? {
        guard offset <= size, size - offset >= 8 else { return nil }
        let index = Int(offset)
        var value: UInt64 = 0
        for shift in 0..<8 {
            value |= UInt64(bytes[index + shift]) << (shift * 8)
        }
        return value
    }

    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 8 else { return false }
        let index = Int(offset)
        for shift in 0..<8 {
            bytes[index + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8))
        }
        return true
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
}

final class EmulationLog {
    static let shared = EmulationLog()
    private(set) var messages: [String] = []
    func write(_ message: String) { messages.append(message) }
}

@main
struct InterpreterTests {
    static func main() throws {
        let memory = GuestMemory(size: 4096)
        let program: [UInt8] = [
            0x48, 0xB8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xB8, 0x01, 0x00, 0x00, 0x00,
            0xBF, 0x01, 0x00, 0x00, 0x00,
            0xBE, 0x80, 0x00, 0x00, 0x00,
            0xBA, 0x0C, 0x00, 0x00, 0x00,
            0x0F, 0x05,
            0xB8, 0x3C, 0x00, 0x00, 0x00,
            0x31, 0xFF,
            0x0F, 0x05
        ]
        precondition(memory.write(Data(program), offset: 0))
        precondition(memory.write(Data("hello world\n".utf8), offset: 0x80))
        let interpreter = X86_64Interpreter(memory: memory)
        try interpreter.reset(entryPoint: 0)
        let interpreterExit = try interpreter.run(maxInstructions: 32)
        precondition(interpreterExit == .halted)
        precondition(interpreter.instructionCount == 9)
        precondition(EmulationLog.shared.messages.contains("[guest stdout] hello world\n"))

        let budgetMemory = GuestMemory(size: 32)
        precondition(budgetMemory.write(Data([0x90, 0x90]), offset: 0))
        let budget = X86_64Interpreter(memory: budgetMemory)
        try budget.reset(entryPoint: 0)
        let budgetExit = try budget.run(maxInstructions: 1)
        precondition(budgetExit == .instructionLimit)
        budget.requestStop()
        let interruptedExit = try budget.run(maxInstructions: 1)
        precondition(interruptedExit == .interrupted)
        budget.resume()
        let resumedExit = try budget.run(maxInstructions: 1)
        precondition(resumedExit == .instructionLimit)
        precondition(budget.instructionCount == 2)

        let faultMemory = GuestMemory(size: 2)
        precondition(faultMemory.write(Data([0xB8, 0x01]), offset: 0))
        let fault = X86_64Interpreter(memory: faultMemory)
        try fault.reset(entryPoint: 0)
        let faultExit = try fault.run(maxInstructions: 1)
        precondition(faultExit == .memoryFault(address: 1))

        let unsupportedMemory = GuestMemory(size: 4)
        precondition(unsupportedMemory.write(Data([0x0F, 0x0B]), offset: 0))
        let unsupported = X86_64Interpreter(memory: unsupportedMemory)
        try unsupported.reset(entryPoint: 0)
        let unsupportedExit = try unsupported.run(maxInstructions: 1)
        precondition(unsupportedExit == .unsupportedInstruction(address: 0))
        print("x86-64 interpreter MOV32, syscall, budget, stop/resume, and fault tests passed")
    }
}
