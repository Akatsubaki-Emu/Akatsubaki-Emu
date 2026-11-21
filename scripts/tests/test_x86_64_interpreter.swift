import Foundation

struct VMConfiguration {
    enum Architecture: String { case x86_64 }
}

protocol GuestCPUBackend {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func setInitialStackPointer(_ pointer: UInt64) throws
    func configureLinuxProcess(programBreak: UInt64, stackBase: UInt64) throws
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
    case invalidState(String)
}

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]
    private(set) var readByteCalls = 0
    private(set) var readPrefixCalls = 0

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    func readByte(offset: UInt64) -> UInt8? {
        readByteCalls += 1
        guard offset < size else { return nil }
        return bytes[Int(offset)]
    }

    func writeByte(_ value: UInt8, offset: UInt64) -> Bool {
        guard offset < size else { return false }
        bytes[Int(offset)] = value
        return true
    }

    func readPrefix(offset: UInt64, into buffer: inout [UInt8]) -> Int? {
        readPrefixCalls += 1
        guard offset <= size else { return nil }
        let count = Int(min(UInt64(buffer.count), size - offset))
        if count > 0 {
            let start = Int(offset)
            for index in 0..<count { buffer[index] = bytes[start + index] }
        }
        return count
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

    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset, length <= UInt64(Int.max) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset + length), with: repeatElement(0, count: Int(length)))
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

        let memoryArithmeticMemory = GuestMemory(size: 256)
        precondition(memoryArithmeticMemory.write(Data([0x02, 0x00, 0x00, 0x00]), offset: 0x80))
        let memoryArithmeticProgram: [UInt8] = [
            0xB8, 0x03, 0x00, 0x00, 0x00,
            0x01, 0x05, 0x75, 0x00, 0x00, 0x00,
            0x8B, 0x1D, 0x6F, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(memoryArithmeticMemory.write(Data(memoryArithmeticProgram), offset: 0))
        let memoryArithmetic = X86_64Interpreter(memory: memoryArithmeticMemory)
        try memoryArithmetic.reset(entryPoint: 0)
        let memoryArithmeticExit = try memoryArithmetic.run(maxInstructions: 8)
        precondition(memoryArithmeticExit == .unsupportedInstruction(address: 17))
        precondition(memoryArithmetic.registerValue(3) == 5)
        precondition(memoryArithmeticMemory.readUInt32(offset: 0x80) == 5)

        let lea32Memory = GuestMemory(size: 256)
        let lea32Program: [UInt8] = [
            0x48, 0xBC, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x8D, 0x5C, 0x24, 0x08,
            0x0F, 0x0B
        ]
        precondition(lea32Memory.write(Data(lea32Program), offset: 0))
        let lea32 = X86_64Interpreter(memory: lea32Memory)
        try lea32.reset(entryPoint: 0)
        let lea32Exit = try lea32.run(maxInstructions: 4)
        precondition(lea32Exit == .unsupportedInstruction(address: 14))
        precondition(lea32.registerValue(3) == 0x108)

        let zeroShiftMemory = GuestMemory(size: 64)
        let zeroShiftProgram: [UInt8] = [
            0xB8, 0x01, 0x00, 0x00, 0x00,
            0x83, 0xF8, 0x02,
            0xB9, 0x00, 0x00, 0x00, 0x00,
            0xD3, 0xE0,
            0x0F, 0x0B
        ]
        precondition(zeroShiftMemory.write(Data(zeroShiftProgram), offset: 0))
        let zeroShift = X86_64Interpreter(memory: zeroShiftMemory)
        try zeroShift.reset(entryPoint: 0)
        let zeroShiftExit = try zeroShift.run(maxInstructions: 6)
        precondition(zeroShiftExit == .unsupportedInstruction(address: 15))
        precondition(zeroShift.registerValue(0) == 1)
        precondition(zeroShift.conditionFlags & X86_64ALU.carry != 0)
        precondition(zeroShift.conditionFlags & X86_64ALU.sign != 0)

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

        let indirectMemory = GuestMemory(size: 4096)
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

        let truncatedRetMemory = GuestMemory(size: 1)
        precondition(truncatedRetMemory.write(Data([0xC2]), offset: 0))
        let truncatedRet = X86_64Interpreter(memory: truncatedRetMemory)
        try truncatedRet.reset(entryPoint: 0)
        let truncatedRetExit = try truncatedRet.run(maxInstructions: 1)
        precondition(truncatedRetExit == .memoryFault(address: 1))

        let indirectFaultMemory = GuestMemory(size: 64)
        precondition(indirectFaultMemory.write(Data([0xFF, 0x25, 0x00, 0x10, 0x00, 0x00]), offset: 0))
        let indirectFault = X86_64Interpreter(memory: indirectFaultMemory)
        try indirectFault.reset(entryPoint: 0)
        let indirectFaultExit = try indirectFault.run(maxInstructions: 1)
        precondition(indirectFaultExit == .memoryFault(address: 0x1006))

        let movsxdMemory = GuestMemory(size: 32)
        precondition(movsxdMemory.write(Data([0xB8, 0xFF, 0xFF, 0xFF, 0xFF,
                                               0x48, 0x63, 0xC0, 0x0F, 0x0B]), offset: 0))
        let movsxd = X86_64Interpreter(memory: movsxdMemory)
        try movsxd.reset(entryPoint: 0)
        let movsxdExit = try movsxd.run(maxInstructions: 4)
        precondition(movsxdExit == .unsupportedInstruction(address: 8))
        precondition(movsxd.registerValue(0) == UInt64.max)

        let imulMemory = GuestMemory(size: 64)
        precondition(imulMemory.write(Data([0x48, 0xC7, 0xC0, 0xFE, 0xFF, 0xFF, 0xFF,
                                            0xBB, 0x03, 0x00, 0x00, 0x00,
                                            0x48, 0x0F, 0xAF, 0xC3, 0x0F, 0x0B]), offset: 0))
        let imul = X86_64Interpreter(memory: imulMemory)
        try imul.reset(entryPoint: 0)
        let imulExit = try imul.run(maxInstructions: 8)
        precondition(imulExit == .unsupportedInstruction(address: 16))
        precondition(imul.registerValue(0) == UInt64.max - 5)
        precondition(imul.conditionFlags & X86_64ALU.carry == 0)
        precondition(imul.conditionFlags & X86_64ALU.overflow == 0)

        let imulOverflowMemory = GuestMemory(size: 32)
        precondition(imulOverflowMemory.write(Data([0xB8, 0xFF, 0xFF, 0xFF, 0x7F,
                                                    0x6B, 0xC0, 0x02, 0x0F, 0x0B]), offset: 0))
        let imulOverflow = X86_64Interpreter(memory: imulOverflowMemory)
        try imulOverflow.reset(entryPoint: 0)
        let imulOverflowExit = try imulOverflow.run(maxInstructions: 4)
        precondition(imulOverflowExit == .unsupportedInstruction(address: 8))
        precondition(imulOverflow.registerValue(0) == 0xFFFF_FFFE)
        precondition(imulOverflow.conditionFlags & X86_64ALU.carry != 0)
        precondition(imulOverflow.conditionFlags & X86_64ALU.overflow != 0)

        let imulImmediateMemory = GuestMemory(size: 32)
        precondition(imulImmediateMemory.write(Data([0xB8, 0x04, 0x00, 0x00, 0x00,
                                                     0x69, 0xC0, 0xFE, 0xFF, 0xFF, 0xFF,
                                                     0x0F, 0x0B]), offset: 0))
        let imulImmediate = X86_64Interpreter(memory: imulImmediateMemory)
        try imulImmediate.reset(entryPoint: 0)
        let imulImmediateExit = try imulImmediate.run(maxInstructions: 4)
        precondition(imulImmediateExit == .unsupportedInstruction(address: 11))
        precondition(imulImmediate.registerValue(0) == 0xFFFF_FFF8)

        let movExtendMemory = GuestMemory(size: 128)
        let movExtendProgram: [UInt8] = [
            0x48, 0x0F, 0xB7, 0x05, 0x18, 0x00, 0x00, 0x00,
            0x0F, 0xBF, 0x0D, 0x11, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(movExtendMemory.write(Data(movExtendProgram), offset: 0))
        precondition(movExtendMemory.write(Data([0x34, 0xF2]), offset: 0x20))
        let movExtend = X86_64Interpreter(memory: movExtendMemory)
        try movExtend.reset(entryPoint: 0)
        let movExtendExit = try movExtend.run(maxInstructions: 4)
        precondition(movExtendExit == .unsupportedInstruction(address: 15))
        precondition(movExtend.registerValue(0) == 0xF234)
        precondition(movExtend.registerValue(1) == 0xFFFF_F234)

        let byteExtendMemory = GuestMemory(size: 128)
        let byteExtendProgram: [UInt8] = [
            0x0F, 0xB6, 0x05, 0x19, 0x00, 0x00, 0x00,
            0x0F, 0xBE, 0x0D, 0x0C, 0x00, 0x00, 0x00,
            0x0F, 0x0B
        ]
        precondition(byteExtendMemory.write(Data(byteExtendProgram), offset: 0))
        precondition(byteExtendMemory.write(Data([0xF2]), offset: 0x20))
        let byteExtend = X86_64Interpreter(memory: byteExtendMemory)
        try byteExtend.reset(entryPoint: 0)
        let byteExtendExit = try byteExtend.run(maxInstructions: 4)
        precondition(byteExtendExit == .unsupportedInstruction(address: 14))
        precondition(byteExtend.registerValue(0) == 0xF2)
        precondition(byteExtend.registerValue(1) == 0xFFFF_FFF2)

        let highByteMemory = GuestMemory(size: 32)
        precondition(highByteMemory.write(Data([0xB8, 0x78, 0x56, 0x34, 0x12,
                                                0x0F, 0xB6, 0xC4,
                                                0x40, 0x0F, 0xB6, 0xC4,
                                                0x0F, 0x0B]), offset: 0))
        let highByte = X86_64Interpreter(memory: highByteMemory)
        try highByte.reset(entryPoint: 0)
        let highByteExit = try highByte.run(maxInstructions: 5)
        precondition(highByteExit == .unsupportedInstruction(address: 12))
        precondition(highByte.registerValue(0) == 24)

        let shiftLeftMemory = GuestMemory(size: 32)
        precondition(shiftLeftMemory.write(Data([0xB8, 0x00, 0x00, 0x00, 0x80,
                                                 0xC1, 0xE0, 0x01, 0x0F, 0x0B]), offset: 0))
        let shiftLeft = X86_64Interpreter(memory: shiftLeftMemory)
        try shiftLeft.reset(entryPoint: 0)
        let shiftLeftExit = try shiftLeft.run(maxInstructions: 4)
        precondition(shiftLeftExit == .unsupportedInstruction(address: 8))
        precondition(shiftLeft.registerValue(0) == 0)
        precondition(shiftLeft.conditionFlags & X86_64ALU.carry != 0)
        precondition(shiftLeft.conditionFlags & X86_64ALU.overflow != 0)

        let shiftRightMemory = GuestMemory(size: 32)
        precondition(shiftRightMemory.write(Data([0xB8, 0x00, 0x00, 0x00, 0x80,
                                                  0xC1, 0xE8, 0x01, 0x0F, 0x0B]), offset: 0))
        let shiftRight = X86_64Interpreter(memory: shiftRightMemory)
        try shiftRight.reset(entryPoint: 0)
        let shiftRightExit = try shiftRight.run(maxInstructions: 4)
        precondition(shiftRightExit == .unsupportedInstruction(address: 8))
        precondition(shiftRight.registerValue(0) == 0x4000_0000)
        precondition(shiftRight.conditionFlags & X86_64ALU.overflow != 0)

        let shiftArithmeticMemory = GuestMemory(size: 32)
        precondition(shiftArithmeticMemory.write(Data([0xB8, 0x00, 0x00, 0x00, 0x80,
                                                       0xC1, 0xF8, 0x01, 0x0F, 0x0B]), offset: 0))
        let shiftArithmetic = X86_64Interpreter(memory: shiftArithmeticMemory)
        try shiftArithmetic.reset(entryPoint: 0)
        let shiftArithmeticExit = try shiftArithmetic.run(maxInstructions: 4)
        precondition(shiftArithmeticExit == .unsupportedInstruction(address: 8))
        precondition(shiftArithmetic.registerValue(0) == 0xC000_0000)
        precondition(shiftArithmetic.conditionFlags & X86_64ALU.overflow == 0)

        let shiftCLMemory = GuestMemory(size: 32)
        precondition(shiftCLMemory.write(Data([0xB8, 0x01, 0x00, 0x00, 0x00,
                                               0xB9, 0x02, 0x00, 0x00, 0x00,
                                               0xD3, 0xE0, 0x0F, 0x0B]), offset: 0))
        let shiftCL = X86_64Interpreter(memory: shiftCLMemory)
        try shiftCL.reset(entryPoint: 0)
        let shiftCLExit = try shiftCL.run(maxInstructions: 5)
        precondition(shiftCLExit == .unsupportedInstruction(address: 12))
        precondition(shiftCL.registerValue(0) == 4)

        let testImmediateMemory = GuestMemory(size: 32)
        precondition(testImmediateMemory.write(Data([0xB8, 0x00, 0x00, 0x00, 0x80,
                                                     0xF7, 0xC0, 0x01, 0x00, 0x00, 0x00,
                                                     0x0F, 0x0B]), offset: 0))
        let testImmediate = X86_64Interpreter(memory: testImmediateMemory)
        try testImmediate.reset(entryPoint: 0)
        let testImmediateExit = try testImmediate.run(maxInstructions: 4)
        precondition(testImmediateExit == .unsupportedInstruction(address: 11))
        precondition(testImmediate.registerValue(0) == 0x8000_0000)
        precondition(testImmediate.conditionFlags & X86_64ALU.zero != 0)

        let notMemory = GuestMemory(size: 32)
        precondition(notMemory.write(Data([0xB8, 0x78, 0x56, 0x34, 0x12,
                                           0xF7, 0xD0, 0x0F, 0x0B]), offset: 0))
        let notInterpreter = X86_64Interpreter(memory: notMemory)
        try notInterpreter.reset(entryPoint: 0)
        let notExit = try notInterpreter.run(maxInstructions: 4)
        precondition(notExit == .unsupportedInstruction(address: 7))
        precondition(notInterpreter.registerValue(0) == 0xEDCB_A987)

        let negMemory = GuestMemory(size: 32)
        precondition(negMemory.write(Data([0xB8, 0x01, 0x00, 0x00, 0x00,
                                           0xF7, 0xD8, 0x0F, 0x0B]), offset: 0))
        let negInterpreter = X86_64Interpreter(memory: negMemory)
        try negInterpreter.reset(entryPoint: 0)
        let negExit = try negInterpreter.run(maxInstructions: 4)
        precondition(negExit == .unsupportedInstruction(address: 7))
        precondition(negInterpreter.registerValue(0) == 0xFFFF_FFFF)
        precondition(negInterpreter.conditionFlags & X86_64ALU.carry != 0)

        let incMemory = GuestMemory(size: 32)
        precondition(incMemory.write(Data([0xB8, 0xFF, 0xFF, 0xFF, 0xFF,
                                           0xFF, 0xC0, 0x0F, 0x0B]), offset: 0))
        let incInterpreter = X86_64Interpreter(memory: incMemory)
        try incInterpreter.reset(entryPoint: 0)
        let incExit = try incInterpreter.run(maxInstructions: 4)
        precondition(incExit == .unsupportedInstruction(address: 7))
        precondition(incInterpreter.registerValue(0) == 0)
        precondition(incInterpreter.conditionFlags & X86_64ALU.zero != 0)
        precondition(incInterpreter.conditionFlags & X86_64ALU.carry == 0)

        let decMemory = GuestMemory(size: 32)
        precondition(decMemory.write(Data([0xB8, 0x00, 0x00, 0x00, 0x00,
                                           0xFF, 0xC8, 0x0F, 0x0B]), offset: 0))
        let decInterpreter = X86_64Interpreter(memory: decMemory)
        try decInterpreter.reset(entryPoint: 0)
        let decExit = try decInterpreter.run(maxInstructions: 4)
        precondition(decExit == .unsupportedInstruction(address: 7))
        precondition(decInterpreter.registerValue(0) == 0xFFFF_FFFF)
        precondition(decInterpreter.conditionFlags & X86_64ALU.carry == 0)

        let ripC7Memory = GuestMemory(size: 128)
        precondition(ripC7Memory.write(Data([0xC7, 0x05, 0x16, 0x00, 0x00, 0x00,
                                             0x78, 0x56, 0x34, 0x12, 0x0F, 0x0B]), offset: 0))
        let ripC7 = X86_64Interpreter(memory: ripC7Memory)
        try ripC7.reset(entryPoint: 0)
        let ripC7Exit = try ripC7.run(maxInstructions: 3)
        precondition(ripC7Exit == .unsupportedInstruction(address: 10))
        precondition(ripC7Memory.readUInt32(offset: 0x20) == 0x12345678)

        let ripTestMemory = GuestMemory(size: 128)
        precondition(ripTestMemory.write(Data([0xF7, 0x05, 0x16, 0x00, 0x00, 0x00,
                                               0x01, 0x00, 0x00, 0x00, 0x0F, 0x0B]), offset: 0))
        precondition(ripTestMemory.writeUInt32(1, offset: 0x20))
        let ripTest = X86_64Interpreter(memory: ripTestMemory)
        try ripTest.reset(entryPoint: 0)
        let ripTestExit = try ripTest.run(maxInstructions: 3)
        precondition(ripTestExit == .unsupportedInstruction(address: 10))
        precondition(ripTest.conditionFlags & X86_64ALU.zero == 0)

        let ripIMULMemory = GuestMemory(size: 128)
        precondition(ripIMULMemory.write(Data([0x6B, 0x05, 0x19, 0x00, 0x00, 0x00,
                                               0xFE, 0x0F, 0x0B]), offset: 0))
        precondition(ripIMULMemory.writeUInt32(4, offset: 0x20))
        let ripIMUL = X86_64Interpreter(memory: ripIMULMemory)
        try ripIMUL.reset(entryPoint: 0)
        let ripIMULExit = try ripIMUL.run(maxInstructions: 3)
        precondition(ripIMULExit == .unsupportedInstruction(address: 7))
        precondition(ripIMUL.registerValue(0) == 0xFFFF_FFF8)

        let ripAddMemory = GuestMemory(size: 128)
        precondition(ripAddMemory.write(Data([0x83, 0x05, 0x19, 0x00, 0x00, 0x00,
                                              0x02, 0x0F, 0x0B]), offset: 0))
        precondition(ripAddMemory.writeUInt32(5, offset: 0x20))
        let ripAdd = X86_64Interpreter(memory: ripAddMemory)
        try ripAdd.reset(entryPoint: 0)
        let ripAddExit = try ripAdd.run(maxInstructions: 3)
        precondition(ripAddExit == .unsupportedInstruction(address: 7))
        precondition(ripAddMemory.readUInt32(offset: 0x20) == 7)

        let test64Memory = GuestMemory(size: 64)
        precondition(test64Memory.write(Data([0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
                                              0x48, 0xF7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF,
                                              0x0F, 0x0B]), offset: 0))
        let test64 = X86_64Interpreter(memory: test64Memory)
        try test64.reset(entryPoint: 0)
        let test64Exit = try test64.run(maxInstructions: 3)
        precondition(test64Exit == .unsupportedInstruction(address: 17))
        precondition(test64.conditionFlags & X86_64ALU.zero == 0)

        let unsupportedF7Memory = GuestMemory(size: 16)
        precondition(unsupportedF7Memory.write(Data([0xF7, 0x25, 0x00, 0x10, 0x00, 0x00]), offset: 0))
        let unsupportedF7 = X86_64Interpreter(memory: unsupportedF7Memory)
        try unsupportedF7.reset(entryPoint: 0)
        let unsupportedF7Exit = try unsupportedF7.run(maxInstructions: 1)
        precondition(unsupportedF7Exit == .unsupportedInstruction(address: 0))

        let retMemory = GuestMemory(size: 64)
        precondition(retMemory.writeUInt64(8, offset: 56))
        precondition(retMemory.write(Data([0xC3]), offset: 0))
        precondition(retMemory.write(Data([0x0F, 0x0B]), offset: 8))
        let ret = X86_64Interpreter(memory: retMemory)
        try ret.reset(entryPoint: 0)
        let retExit = try ret.run(maxInstructions: 3)
        precondition(retExit == .unsupportedInstruction(address: 8))
        precondition(ret.registerValue(4) == 64)

        let byteImmediateMemory = GuestMemory(size: 64)
        precondition(byteImmediateMemory.write(Data([0xB8, 0x78, 0x56, 0x34, 0x12,
                                                     0xB4, 0xAA, 0x0F, 0x0B]), offset: 0))
        let byteImmediate = X86_64Interpreter(memory: byteImmediateMemory)
        try byteImmediate.reset(entryPoint: 0)
        let byteImmediateExit = try byteImmediate.run(maxInstructions: 4)
        precondition(byteImmediateExit == .unsupportedInstruction(address: 7))
        precondition(byteImmediate.registerValue(0) == 0x1234_AA78)

        let byteStoreMemory = GuestMemory(size: 128)
        precondition(byteStoreMemory.write(Data([0xB8, 0x78, 0x56, 0x34, 0x12,
                                                 0x88, 0x25, 0x15, 0x00, 0x00, 0x00,
                                                 0x0F, 0x0B]), offset: 0))
        let byteStore = X86_64Interpreter(memory: byteStoreMemory)
        try byteStore.reset(entryPoint: 0)
        let byteStoreExit = try byteStore.run(maxInstructions: 4)
        precondition(byteStoreExit == .unsupportedInstruction(address: 11))
        precondition(byteStoreMemory.readByte(offset: 0x20) == 0x56)

        let byteLoadMemory = GuestMemory(size: 128)
        precondition(byteLoadMemory.write(Data([0x8A, 0x05, 0x1A, 0x00, 0x00, 0x00,
                                                0x0F, 0x0B]), offset: 0))
        precondition(byteLoadMemory.writeByte(0xAB, offset: 0x20))
        let byteLoad = X86_64Interpreter(memory: byteLoadMemory)
        try byteLoad.reset(entryPoint: 0)
        let byteLoadExit = try byteLoad.run(maxInstructions: 3)
        precondition(byteLoadExit == .unsupportedInstruction(address: 6))
        precondition(byteLoad.registerValue(0) == 0xAB)

        let byteImmediateStoreMemory = GuestMemory(size: 128)
        precondition(byteImmediateStoreMemory.write(Data([0xC6, 0x05, 0x19, 0x00, 0x00, 0x00,
                                                          0x7F, 0x0F, 0x0B]), offset: 0))
        let byteImmediateStore = X86_64Interpreter(memory: byteImmediateStoreMemory)
        try byteImmediateStore.reset(entryPoint: 0)
        let byteImmediateStoreExit = try byteImmediateStore.run(maxInstructions: 3)
        precondition(byteImmediateStoreExit == .unsupportedInstruction(address: 7))
        precondition(byteImmediateStoreMemory.readByte(offset: 0x20) == 0x7F)

        let rexByteMemory = GuestMemory(size: 32)
        precondition(rexByteMemory.write(Data([0x41, 0xB0, 0x7F, 0x0F, 0x0B]), offset: 0))
        let rexByte = X86_64Interpreter(memory: rexByteMemory)
        try rexByte.reset(entryPoint: 0)
        let rexByteExit = try rexByte.run(maxInstructions: 3)
        precondition(rexByteExit == .unsupportedInstruction(address: 3))
        precondition(rexByte.registerValue(8) == 0x7F)

        let unsupportedC6Memory = GuestMemory(size: 16)
        precondition(unsupportedC6Memory.write(Data([0xC6, 0x0D]), offset: 0))
        let unsupportedC6 = X86_64Interpreter(memory: unsupportedC6Memory)
        try unsupportedC6.reset(entryPoint: 0)
        let unsupportedC6Exit = try unsupportedC6.run(maxInstructions: 2)
        precondition(unsupportedC6Exit == .unsupportedInstruction(address: 0))

        let syscallMemory = GuestMemory(size: 4 * 1024 * 1024)
        let syscallProgram: [UInt8] = [
            0xB8, 0x0C, 0x00, 0x00, 0x00,
            0xBF, 0x00, 0x20, 0x00, 0x00,
            0x0F, 0x05,
            0xB8, 0x0C, 0x00, 0x00, 0x00,
            0x31, 0xFF,
            0x0F, 0x05,
            0x0F, 0x0B
        ]
        precondition(syscallMemory.write(Data(syscallProgram), offset: 0))
        let syscallInterpreter = X86_64Interpreter(memory: syscallMemory)
        try syscallInterpreter.reset(entryPoint: 0)
        try syscallInterpreter.configureLinuxProcess(programBreak: 0x1000, stackBase: 0x3F0000)
        let syscallExit = try syscallInterpreter.run(maxInstructions: 12)
        precondition(syscallExit == .unsupportedInstruction(address: 21))
        precondition(syscallInterpreter.registerValue(0) == 0x2000)

        let unsupportedMemory = GuestMemory(size: 4)
        precondition(unsupportedMemory.write(Data([0x0F, 0x0B]), offset: 0))
        let unsupported = X86_64Interpreter(memory: unsupportedMemory)
        try unsupported.reset(entryPoint: 0)
        let unsupportedExit = try unsupported.run(maxInstructions: 1)
        precondition(unsupportedExit == .unsupportedInstruction(address: 0))
        let windowMemory = GuestMemory(size: 64)
        precondition(windowMemory.write(Data([0x90, 0x90, 0xF4]), offset: 0x20))
        let windowInterpreter = X86_64Interpreter(memory: windowMemory)
        try windowInterpreter.reset(entryPoint: 0x20)
        let windowExit = try windowInterpreter.run(maxInstructions: 8)
        precondition(windowExit == .halted)
        precondition(windowMemory.readPrefixCalls == 3)
        precondition(windowMemory.readByteCalls == 0)

        let boundaryMemory = GuestMemory(size: 8192)
        precondition(boundaryMemory.write(Data([0xB8, 0x78, 0x56, 0x34, 0x12, 0xF4]), offset: 4094))
        let boundaryInterpreter = X86_64Interpreter(memory: boundaryMemory)
        try boundaryInterpreter.reset(entryPoint: 4094)
        let boundaryExit = try boundaryInterpreter.run(maxInstructions: 4)
        precondition(boundaryExit == .halted)
        precondition(boundaryInterpreter.registerValue(0) == 0x12345678)

        let edgeMemory = GuestMemory(size: 4096)
        precondition(edgeMemory.write(Data([0x90]), offset: 4095))
        let edgeInterpreter = X86_64Interpreter(memory: edgeMemory)
        try edgeInterpreter.reset(entryPoint: 4095)
        let edgeExit = try edgeInterpreter.run(maxInstructions: 2)
        precondition(edgeExit == .memoryFault(address: 4096))

        let selfModifyingMemory = GuestMemory(size: 64)
        precondition(selfModifyingMemory.write(Data([
            0xB8, 0xF4, 0x00, 0x00, 0x00,
            0x89, 0x05, 0x00, 0x00, 0x00, 0x00,
            0x90, 0xF4
        ]), offset: 0))
        let selfModifyingInterpreter = X86_64Interpreter(memory: selfModifyingMemory)
        try selfModifyingInterpreter.reset(entryPoint: 0)
        let selfModifyingExit = try selfModifyingInterpreter.run(maxInstructions: 8)
        precondition(selfModifyingExit == .halted)
        precondition(selfModifyingMemory.readByte(offset: 11) == 0xF4)
        precondition(selfModifyingMemory.readPrefixCalls == 3)

        print("x86-64 interpreter register, memory addressing, ALU flags, stack frames, indirect control flow, instruction windows, brk syscall, budget and fault tests passed")
    }
}
