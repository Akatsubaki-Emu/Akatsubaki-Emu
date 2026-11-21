import Foundation

struct VMConfiguration {
    enum Architecture: String { case x86_64 }
}

protocol GuestCPUBackend {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func setInitialStackPointer(_ pointer: UInt64) throws
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

    func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 4 else { return false }
        let index = Int(offset)
        for shift in 0..<4 {
            bytes[index + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8))
        }
        return true
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

        let stackPointerMemory = GuestMemory(size: 1024)
        let stackPointerInterpreter = X86_64Interpreter(memory: stackPointerMemory)
        try stackPointerInterpreter.reset(entryPoint: 0)
        try stackPointerInterpreter.setInitialStackPointer(0x100)
        precondition(stackPointerInterpreter.registerValue(4) == 0x100)

        let arithmeticMemory = GuestMemory(size: 128)
        let arithmeticProgram: [UInt8] = [
            0xB8, 0xFF, 0xFF, 0xFF, 0xFF,
            0x83, 0xC0, 0x01,
            0x74, 0x05,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0xBB, 0x02, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(arithmeticMemory.write(Data(arithmeticProgram), offset: 0))
        let arithmetic = X86_64Interpreter(memory: arithmeticMemory)
        try arithmetic.reset(entryPoint: 0)
        let arithmeticExit = try arithmetic.run(maxInstructions: 16)
        precondition(arithmeticExit == .unsupportedInstruction(address: 20))
        precondition(arithmetic.registerValue(3) == 2)
        precondition(arithmetic.conditionFlags & X86_64ALU.zero != 0)
        precondition(arithmetic.conditionFlags & X86_64ALU.carry != 0)

        let signedMemory = GuestMemory(size: 128)
        let signedProgram: [UInt8] = [
            0xB8, 0x01, 0x00, 0x00, 0x00,
            0x83, 0xF8, 0x02,
            0x7C, 0x05,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0xBB, 0x02, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(signedMemory.write(Data(signedProgram), offset: 0))
        let signed = X86_64Interpreter(memory: signedMemory)
        try signed.reset(entryPoint: 0)
        let signedExit = try signed.run(maxInstructions: 16)
        precondition(signedExit == .unsupportedInstruction(address: 20))
        precondition(signed.registerValue(3) == 2)
        precondition(signed.conditionFlags & X86_64ALU.carry != 0)
        precondition(signed.conditionFlags & X86_64ALU.sign != 0)

        let xorMemory = GuestMemory(size: 32)
        precondition(xorMemory.write(Data([0x31, 0xC0, 0x0F, 0x0B]), offset: 0))
        let xor = X86_64Interpreter(memory: xorMemory)
        try xor.reset(entryPoint: 0)
        let xorExit = try xor.run(maxInstructions: 4)
        precondition(xorExit == .unsupportedInstruction(address: 2))
        precondition(xor.registerValue(0) == 0)
        precondition(xor.conditionFlags & X86_64ALU.zero != 0)
        precondition(xor.conditionFlags & X86_64ALU.carry == 0)

        let ripRelativeMemory = GuestMemory(size: 256)
        let ripRelativeProgram: [UInt8] = [
            0xB8, 0x78, 0x56, 0x34, 0x12,
            0x89, 0x05, 0x75, 0x00, 0x00, 0x00,
            0x8B, 0x1D, 0x6F, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(ripRelativeMemory.write(Data(ripRelativeProgram), offset: 0))
        let ripRelative = X86_64Interpreter(memory: ripRelativeMemory)
        try ripRelative.reset(entryPoint: 0)
        let ripRelativeExit = try ripRelative.run(maxInstructions: 8)
        precondition(ripRelativeExit == .unsupportedInstruction(address: 17))
        precondition(ripRelative.registerValue(3) == 0x12345678)
        precondition(ripRelativeMemory.readUInt32(offset: 0x80) == 0x12345678)

        let sibMemory = GuestMemory(size: 4096)
        let sibProgram: [UInt8] = [
            0x48, 0xBC, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
            0x48, 0x89, 0x44, 0x24, 0x08,
            0x48, 0x8B, 0x5C, 0x24, 0x08,
            0x0F, 0x0B
        ]
        precondition(sibMemory.write(Data(sibProgram), offset: 0))
        let sib = X86_64Interpreter(memory: sibMemory)
        try sib.reset(entryPoint: 0)
        let sibExit = try sib.run(maxInstructions: 8)
        precondition(sibExit == .unsupportedInstruction(address: 30))
        precondition(sib.registerValue(3) == 0x1122334455667788)
        precondition(sibMemory.readUInt64(offset: 0x108) == 0x1122334455667788)

        let leaMemory = GuestMemory(size: 256)
        precondition(leaMemory.write(Data([0x48, 0x8D, 0x1D, 0x79, 0x00, 0x00, 0x00, 0x0F, 0x0B]), offset: 0))
        let lea = X86_64Interpreter(memory: leaMemory)
        try lea.reset(entryPoint: 0)
        let leaExit = try lea.run(maxInstructions: 4)
        precondition(leaExit == .unsupportedInstruction(address: 7))
        precondition(lea.registerValue(3) == 128)

        let truncatedShortMemory = GuestMemory(size: 1)
        precondition(truncatedShortMemory.write(Data([0x74]), offset: 0))
        let truncatedShort = X86_64Interpreter(memory: truncatedShortMemory)
        try truncatedShort.reset(entryPoint: 0)
        let truncatedShortExit = try truncatedShort.run(maxInstructions: 1)
        precondition(truncatedShortExit == .memoryFault(address: 1))

        let truncatedNearMemory = GuestMemory(size: 3)
        precondition(truncatedNearMemory.write(Data([0x0F, 0x84, 0x01]), offset: 0))
        let truncatedNear = X86_64Interpreter(memory: truncatedNearMemory)
        try truncatedNear.reset(entryPoint: 0)
        let truncatedNearExit = try truncatedNear.run(maxInstructions: 1)
        precondition(truncatedNearExit == .memoryFault(address: 2))

        let orMemory = GuestMemory(size: 32)
        precondition(orMemory.write(Data([0xB8, 0x01, 0x00, 0x00, 0x00, 0x83, 0xC8, 0x02, 0x0F, 0x0B]), offset: 0))
        let orInterpreter = X86_64Interpreter(memory: orMemory)
        try orInterpreter.reset(entryPoint: 0)
        let orExit = try orInterpreter.run(maxInstructions: 8)
        precondition(orExit == .unsupportedInstruction(address: 8))
        precondition(orInterpreter.registerValue(0) == 3)
        precondition(orInterpreter.conditionFlags & X86_64ALU.carry == 0)
        precondition(orInterpreter.conditionFlags & X86_64ALU.overflow == 0)

        let c7Memory = GuestMemory(size: 32)
        precondition(c7Memory.write(Data([0x48, 0xC7, 0xC0, 0x78, 0x56, 0x34, 0x12, 0x0F, 0x0B]), offset: 0))
        let c7 = X86_64Interpreter(memory: c7Memory)
        try c7.reset(entryPoint: 0)
        let c7Exit = try c7.run(maxInstructions: 4)
        precondition(c7Exit == .unsupportedInstruction(address: 7))
        precondition(c7.registerValue(0) == 0x12345678)

        let leaveMemory = GuestMemory(size: 512)
        let leaveProgram: [UInt8] = [
            0x48, 0xBC, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x55, 0x48, 0x89, 0xE5, 0x48, 0x83, 0xEC, 0x08, 0xC9, 0x0F, 0x0B
        ]
        precondition(leaveMemory.write(Data(leaveProgram), offset: 0))
        let leave = X86_64Interpreter(memory: leaveMemory)
        try leave.reset(entryPoint: 0)
        let leaveExit = try leave.run(maxInstructions: 8)
        precondition(leaveExit == .unsupportedInstruction(address: 19))
        precondition(leave.registerValue(4) == 0x200)
        precondition(leave.registerValue(5) == 0)

        let indirectMemory = GuestMemory(size: 128)
        var indirectProgram: [UInt8] = [
            0x48, 0xB8, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xD0, 0x0F, 0x0B
        ]
        indirectProgram += [UInt8](repeating: 0x90, count: 0x20 - indirectProgram.count)
        indirectProgram += [0xBB, 0x42, 0x00, 0x00, 0x00, 0xC3]
        precondition(indirectMemory.write(Data(indirectProgram), offset: 0))
        let indirect = X86_64Interpreter(memory: indirectMemory)
        try indirect.reset(entryPoint: 0)
        let indirectExit = try indirect.run(maxInstructions: 16)
        precondition(indirectExit == .unsupportedInstruction(address: 12))
        precondition(indirect.registerValue(3) == 0x42)
        precondition(indirect.registerValue(4) == 4088)

        let retImmediateMemory = GuestMemory(size: 512)
        precondition(retImmediateMemory.write(Data([0xC2, 0x08, 0x00, 0x0F, 0x0B]), offset: 0))
        precondition(retImmediateMemory.writeUInt64(3, offset: 0x100))
        let retImmediate = X86_64Interpreter(memory: retImmediateMemory)
        try retImmediate.reset(entryPoint: 0)
        try retImmediate.setInitialStackPointer(0x100)
        let retImmediateExit = try retImmediate.run(maxInstructions: 4)
        precondition(retImmediateExit == .unsupportedInstruction(address: 3))
        precondition(retImmediate.registerValue(4) == 0x110)

        let unsupportedMemory = GuestMemory(size: 4)
        precondition(unsupportedMemory.write(Data([0x0F, 0x0B]), offset: 0))
        let unsupported = X86_64Interpreter(memory: unsupportedMemory)
        try unsupported.reset(entryPoint: 0)
        let unsupportedExit = try unsupported.run(maxInstructions: 1)
        precondition(unsupportedExit == .unsupportedInstruction(address: 0))
        print("x86-64 interpreter register, memory addressing, ALU flags, stack frames, indirect control flow, syscall, budget and fault tests passed")
    }
}
