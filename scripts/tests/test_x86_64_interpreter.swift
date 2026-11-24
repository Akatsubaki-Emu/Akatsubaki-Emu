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

enum GuestMemoryTransactionResult: Int32 {
    case success = 0
    case invalid = 1
    case alreadyMapped = 2
    case allocationFailed = 3
}

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]
    private(set) var readByteCalls = 0
    private(set) var readExecuteByteCalls = 0
    private(set) var readUInt16Calls = 0
    private(set) var readPrefixCalls = 0
    private var executableBytes: [Bool]
    private let pageSize: UInt64 = 4096
    private var permissionsEnabled = false
    private var pagePermissions: [UInt64: UInt8] = [:]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
        executableBytes = [Bool](repeating: true, count: Int(size))
    }

    func hasMappedPages(offset: UInt64, length: UInt64) -> Bool {
        guard length > 0, offset <= size, length <= size - offset else { return false }
        guard permissionsEnabled else { return true }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        return (first...last).allSatisfy { pagePermissions[$0] != nil }
    }

    func mapTransaction(offset: UInt64, length: UInt64, permissions: UInt8,
                        replaceExisting: Bool) -> GuestMemoryTransactionResult {
        guard offset % pageSize == 0, length > 0,
              permissions & ~UInt8(0x7) == 0,
              offset <= size, length <= size - offset else { return .invalid }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        if !replaceExisting && (first...last).contains(where: { pagePermissions[$0] != nil }) {
            return .alreadyMapped
        }
        permissionsEnabled = true
        for page in first...last {
            pagePermissions[page] = permissions
            let start = page * pageSize
            let end = start + min(pageSize, size - start)
            if start < end {
                bytes.replaceSubrange(Int(start)..<Int(end),
                                      with: repeatElement(0, count: Int(end - start)))
            }
        }
        return .success
    }

    func protect(offset: UInt64, length: UInt64, permissions: UInt8) -> Bool {
        guard permissionsEnabled, offset % pageSize == 0, length > 0,
              permissions & ~UInt8(0x7) == 0,
              offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        guard (first...last).allSatisfy({ pagePermissions[$0] != nil }) else { return false }
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
            let end = start + min(pageSize, size - start)
            if start < end {
                bytes.replaceSubrange(Int(start)..<Int(end),
                                      with: repeatElement(0, count: Int(end - start)))
            }
        }
        return true
    }

    func resizeBreak(from oldBreak: UInt64, to newBreak: UInt64) -> GuestMemoryTransactionResult {
        guard oldBreak <= size, newBreak <= size else { return .invalid }
        let firstNewPage = oldBreak / pageSize + (oldBreak % pageSize == 0 ? 0 : 1)
        let lastNewPage = newBreak / pageSize + (newBreak % pageSize == 0 ? 0 : 1)
        if newBreak > oldBreak, lastNewPage > firstNewPage {
            return mapTransaction(offset: firstNewPage * pageSize,
                                  length: (lastNewPage - firstNewPage) * pageSize,
                                  permissions: 3, replaceExisting: false)
        }
        if newBreak < oldBreak {
            let firstRemovedPage = newBreak / pageSize + (newBreak % pageSize == 0 ? 0 : 1)
            let lastRemovedPage = oldBreak / pageSize + (oldBreak % pageSize == 0 ? 0 : 1)
            if lastRemovedPage > firstRemovedPage,
               !unmap(offset: firstRemovedPage * pageSize,
                      length: (lastRemovedPage - firstRemovedPage) * pageSize) {
                return .invalid
            }
        }
        return .success
    }

    func readByte(offset: UInt64) -> UInt8? {
        readByteCalls += 1
        guard offset < size else { return nil }
        return bytes[Int(offset)]
    }

    func readExecuteByte(offset: UInt64) -> UInt8? {
        readExecuteByteCalls += 1
        guard offset < size, executableBytes[Int(offset)] else { return nil }
        return bytes[Int(offset)]
    }

    func readUInt16(offset: UInt64) -> UInt16? {
        readUInt16Calls += 1
        guard offset <= size, size - offset >= 2 else { return nil }
        let index = Int(offset)
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    func writeByte(_ value: UInt8, offset: UInt64) -> Bool {
        guard offset < size else { return false }
        bytes[Int(offset)] = value
        return true
    }

    func readPrefix(offset: UInt64, maximumLength: Int? = nil, into buffer: inout [UInt8]) -> Int? {
        readPrefixCalls += 1
        guard offset <= size else { return nil }
        let limit = min(buffer.count, max(0, maximumLength ?? buffer.count))
        let maximumCount = Int(min(UInt64(limit), size - offset))
        let start = Int(offset)
        var count = 0
        while count < maximumCount && executableBytes[start + count] {
            buffer[count] = bytes[start + count]
            count += 1
        }
        return count
    }

    func setExecutable(_ enabled: Bool, offset: UInt64, length: Int) -> Bool {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { return false }
        let start = Int(offset)
        for index in 0..<length { executableBytes[start + index] = enabled }
        return true
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

    func read(offset: UInt64, length: Int, into data: inout Data,
              destinationOffset: Int) -> Bool {
        guard length >= 0, destinationOffset >= 0,
              destinationOffset <= data.count,
              length <= data.count - destinationOffset,
              offset <= size, UInt64(length) <= size - offset else { return false }
        guard length > 0 else { return true }
        let sourceStart = Int(offset)
        data.replaceSubrange(
            destinationOffset..<(destinationOffset + length),
            with: bytes[sourceStart..<(sourceStart + length)]
        )
        return true
    }

    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        return true
    }
}

final class TestAOTExecutor: KenranButoAOTExecuting {
    let isAvailable: Bool
    private(set) var executeCalls = 0

    init(isAvailable: Bool) { self.isAvailable = isAvailable }

    func execute(guestCode: Data, registers: inout [UInt64], rip: UInt64,
                 rflags: UInt64, fsBase: UInt64, gsBase: UInt64,
                 memory: GuestMemory, maximumInstructions: Int) -> KenranButoAOTExecutionResult? {
        executeCalls += 1
        return nil
    }

    func invalidateAll() {}
}

final class EmulationLog {
    static let shared = EmulationLog()
    private(set) var messages: [String] = []
    func write(_ message: String) { messages.append(message) }
}

@main
struct InterpreterTests {
    static func main() throws {
        // A JIT-unavailable device must stay on the interpreter without building
        // or copying the 4 KiB AOT window for each instruction.
        let noJITMemory = GuestMemory(size: 64)
        precondition(noJITMemory.write(Data([0xB8, 0x2A, 0, 0, 0, 0xF4]), offset: 0))
        let unavailableAOT = TestAOTExecutor(isAvailable: false)
        let noJITInterpreter = X86_64Interpreter(memory: noJITMemory, aotExecutor: unavailableAOT)
        try noJITInterpreter.reset(entryPoint: 0)
        let noJITExit = try noJITInterpreter.run(maxInstructions: 4)
        precondition(noJITExit == .halted)
        precondition(unavailableAOT.executeCalls == 0)
        precondition(noJITMemory.readPrefixCalls == 2)

        // Unsupported starts are rejected before asking the AOT executor to compile.
        let unsupportedStartMemory = GuestMemory(size: 64)
        precondition(unsupportedStartMemory.write(Data([0xCC]), offset: 0))
        let readyAOT = TestAOTExecutor(isAvailable: true)
        let unsupportedStart = X86_64Interpreter(memory: unsupportedStartMemory, aotExecutor: readyAOT)
        try unsupportedStart.reset(entryPoint: 0)
        let unsupportedStartExit = try unsupportedStart.run(maxInstructions: 1)
        precondition(unsupportedStartExit == .unsupportedInstruction(address: 0))
        precondition(readyAOT.executeCalls == 0)
        precondition(unsupportedStartMemory.readPrefixCalls == 1)

        // A rejected native block must not rebuild a 4 KiB page window at each later instruction.
        let decliningAOTMemory = GuestMemory(size: 64)
        let decliningProgram: [UInt8] = [
            0xB8, 0x2A, 0, 0, 0,
            0xBB, 0x07, 0, 0, 0,
            0x90,
            0xCC
        ]
        precondition(decliningAOTMemory.write(Data(decliningProgram), offset: 0))
        let decliningAOT = TestAOTExecutor(isAvailable: true)
        let decliningAOTInterpreter = X86_64Interpreter(
            memory: decliningAOTMemory,
            aotExecutor: decliningAOT
        )
        try decliningAOTInterpreter.reset(entryPoint: 0)
        let decliningAOTExit = try decliningAOTInterpreter.run(maxInstructions: 8)
        precondition(decliningAOTExit == .unsupportedInstruction(address: 11))
        precondition(decliningAOT.executeCalls == 1)
        precondition(decliningAOTMemory.readPrefixCalls == 5)
        precondition(decliningAOTInterpreter.registerValue(0) == 42)
        precondition(decliningAOTInterpreter.registerValue(3) == 7)
        precondition(decliningAOTInterpreter.instructionCount == 3)

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
            0x0F, 0xBE, 0x0D, 0x12, 0x00, 0x00, 0x00,
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

        let byteAddMemory = GuestMemory(size: 64)
        precondition(byteAddMemory.write(Data([0xB0, 0xFF, 0xB3, 0x01, 0x00, 0xD8, 0x0F, 0x0B]), offset: 0))
        let byteAdd = X86_64Interpreter(memory: byteAddMemory)
        try byteAdd.reset(entryPoint: 0)
        let byteAddExit = try byteAdd.run(maxInstructions: 5)
        precondition(byteAddExit == .unsupportedInstruction(address: 6))
        precondition(byteAdd.registerValue(0) == 0)
        precondition(byteAdd.conditionFlags & X86_64ALU.carry != 0)
        precondition(byteAdd.conditionFlags & X86_64ALU.zero != 0)
        precondition(byteAdd.conditionFlags & X86_64ALU.auxiliaryCarry != 0)
        precondition(byteAdd.conditionFlags & X86_64ALU.parity != 0)

        let byteSubtractMemory = GuestMemory(size: 64)
        precondition(byteSubtractMemory.write(Data([0xB0, 0x00, 0xB3, 0x01, 0x28, 0xD8, 0x0F, 0x0B]), offset: 0))
        let byteSubtract = X86_64Interpreter(memory: byteSubtractMemory)
        try byteSubtract.reset(entryPoint: 0)
        let byteSubtractExit = try byteSubtract.run(maxInstructions: 5)
        precondition(byteSubtractExit == .unsupportedInstruction(address: 6))
        precondition(byteSubtract.registerValue(0) == 0xFF)
        precondition(byteSubtract.conditionFlags & X86_64ALU.carry != 0)
        precondition(byteSubtract.conditionFlags & X86_64ALU.sign != 0)

        let byteTestMemory = GuestMemory(size: 64)
        precondition(byteTestMemory.write(Data([0xB0, 0x01, 0xB3, 0x01, 0x84, 0xD8, 0x0F, 0x0B]), offset: 0))
        let byteTest = X86_64Interpreter(memory: byteTestMemory)
        try byteTest.reset(entryPoint: 0)
        let byteTestExit = try byteTest.run(maxInstructions: 5)
        precondition(byteTestExit == .unsupportedInstruction(address: 6))
        precondition(byteTest.registerValue(0) == 1)
        precondition(byteTest.conditionFlags & X86_64ALU.zero == 0)

        let byteCompareMemory = GuestMemory(size: 64)
        precondition(byteCompareMemory.write(Data([0xB0, 0x01, 0xB3, 0x02, 0x38, 0xD8, 0x0F, 0x0B]), offset: 0))
        let byteCompare = X86_64Interpreter(memory: byteCompareMemory)
        try byteCompare.reset(entryPoint: 0)
        let byteCompareExit = try byteCompare.run(maxInstructions: 5)
        precondition(byteCompareExit == .unsupportedInstruction(address: 6))
        precondition(byteCompare.registerValue(0) == 1)
        precondition(byteCompare.conditionFlags & X86_64ALU.carry != 0)

        let byteImmediateAddMemory = GuestMemory(size: 64)
        precondition(byteImmediateAddMemory.write(Data([0xB0, 0x7F, 0x80, 0xC0, 0x01, 0x0F, 0x0B]), offset: 0))
        let byteImmediateAdd = X86_64Interpreter(memory: byteImmediateAddMemory)
        try byteImmediateAdd.reset(entryPoint: 0)
        let byteImmediateAddExit = try byteImmediateAdd.run(maxInstructions: 4)
        precondition(byteImmediateAddExit == .unsupportedInstruction(address: 5))
        precondition(byteImmediateAdd.registerValue(0) == 0x80)
        precondition(byteImmediateAdd.conditionFlags & X86_64ALU.overflow != 0)
        precondition(byteImmediateAdd.conditionFlags & X86_64ALU.sign != 0)

        let byteImmediateCompareMemory = GuestMemory(size: 64)
        precondition(byteImmediateCompareMemory.write(Data([0xB0, 0xFF, 0x80, 0xF8, 0x01, 0x0F, 0x0B]), offset: 0))
        let byteImmediateCompare = X86_64Interpreter(memory: byteImmediateCompareMemory)
        try byteImmediateCompare.reset(entryPoint: 0)
        let byteImmediateCompareExit = try byteImmediateCompare.run(maxInstructions: 4)
        precondition(byteImmediateCompareExit == .unsupportedInstruction(address: 5))
        precondition(byteImmediateCompare.registerValue(0) == 0xFF)
        precondition(byteImmediateCompare.conditionFlags & X86_64ALU.carry == 0)

        let byteTestImmediateMemory = GuestMemory(size: 64)
        precondition(byteTestImmediateMemory.write(Data([0xB0, 0x0F, 0xA8, 0xF0, 0x0F, 0x0B]), offset: 0))
        let byteTestImmediate = X86_64Interpreter(memory: byteTestImmediateMemory)
        try byteTestImmediate.reset(entryPoint: 0)
        let byteTestImmediateExit = try byteTestImmediate.run(maxInstructions: 4)
        precondition(byteTestImmediateExit == .unsupportedInstruction(address: 4))
        precondition(byteTestImmediate.registerValue(0) == 0x0F)
        precondition(byteTestImmediate.conditionFlags & X86_64ALU.zero != 0)

        let unsupportedByteImmediateMemory = GuestMemory(size: 16)
        precondition(unsupportedByteImmediateMemory.write(Data([0x80, 0x15]), offset: 0))
        let unsupportedByteImmediate = X86_64Interpreter(memory: unsupportedByteImmediateMemory)
        try unsupportedByteImmediate.reset(entryPoint: 0)
        let unsupportedByteImmediateExit = try unsupportedByteImmediate.run(maxInstructions: 2)
        precondition(unsupportedByteImmediateExit == .unsupportedInstruction(address: 0))

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
        precondition(syscallInterpreter.registerValue(1) == 21)
        precondition(syscallInterpreter.registerValue(11) == 0x46)

        let fsSegmentMemory = GuestMemory(size: 0x2000)
        let fsSegmentProgram: [UInt8] = [
            0xBF, 0x02, 0x10, 0x00, 0x00,
            0x48, 0xBE, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xB8, 0x9E, 0x00, 0x00, 0x00,
            0x0F, 0x05,
            0x64, 0xC6, 0x04, 0x25, 0x20, 0x00, 0x00, 0x00, 0x5A,
            0xBF, 0x03, 0x10, 0x00, 0x00,
            0x48, 0xBE, 0x80, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xB8, 0x9E, 0x00, 0x00, 0x00,
            0x0F, 0x05,
            0x64, 0x8A, 0x04, 0x25, 0x20, 0x00, 0x00, 0x00,
            0xF4
        ]
        precondition(fsSegmentMemory.write(Data(fsSegmentProgram), offset: 0))
        let fsSegment = X86_64Interpreter(memory: fsSegmentMemory)
        try fsSegment.reset(entryPoint: 0)
        let fsSegmentExit = try fsSegment.run(maxInstructions: 11)
        precondition(fsSegmentExit == .halted)
        precondition(fsSegmentMemory.readByte(offset: 0x1020) == 0x5A)
        precondition(fsSegment.registerValue(0) == 0x5A)
        precondition(fsSegmentMemory.readUInt64(offset: 0x1080) == 0x1000)

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
        precondition(edgeMemory.readExecuteByteCalls == 1)
        precondition(edgeMemory.readByteCalls == 0)

        let executeBoundaryMemory = GuestMemory(size: 8192)
        precondition(executeBoundaryMemory.write(Data([0xB8, 0x78]), offset: 4094))
        precondition(executeBoundaryMemory.write(Data([0x56, 0x34, 0x12]), offset: 4096))
        precondition(executeBoundaryMemory.setExecutable(false, offset: 4096, length: 4096))
        let executeBoundaryInterpreter = X86_64Interpreter(memory: executeBoundaryMemory)
        try executeBoundaryInterpreter.reset(entryPoint: 4094)
        let executeBoundaryExit = try executeBoundaryInterpreter.run(maxInstructions: 1)
        precondition(executeBoundaryExit == .memoryFault(address: 4096))
        precondition(executeBoundaryMemory.readExecuteByteCalls == 1)
        precondition(executeBoundaryMemory.readByteCalls == 0)

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

        let zeroExtendMemory = GuestMemory(size: 256)
        precondition(zeroExtendMemory.write(Data([0x0F, 0xB7, 0x05, 0x79, 0x00, 0x00, 0x00, 0xF4]), offset: 0))
        precondition(zeroExtendMemory.write(Data([0xFF, 0x80]), offset: 0x80))
        let zeroExtend = X86_64Interpreter(memory: zeroExtendMemory)
        try zeroExtend.reset(entryPoint: 0)
        let zeroExtendExit = try zeroExtend.run(maxInstructions: 4)
        precondition(zeroExtendExit == .halted)
        precondition(zeroExtend.registerValue(0) == 0x80FF)
        precondition(zeroExtendMemory.readUInt16Calls == 1)
        precondition(zeroExtendMemory.readByteCalls == 0)

        let signExtendMemory = GuestMemory(size: 256)
        precondition(signExtendMemory.write(Data([0x48, 0x0F, 0xBF, 0x05, 0x78, 0x00, 0x00, 0x00, 0xF4]), offset: 0))
        precondition(signExtendMemory.write(Data([0xFF, 0x80]), offset: 0x80))
        let signExtend = X86_64Interpreter(memory: signExtendMemory)
        try signExtend.reset(entryPoint: 0)
        let signExtendExit = try signExtend.run(maxInstructions: 4)
        precondition(signExtendExit == .halted)
        precondition(signExtend.registerValue(0) == 0xFFFFFFFFFFFF80FF)
        precondition(signExtendMemory.readUInt16Calls == 1)
        precondition(signExtendMemory.readByteCalls == 0)

        let wordBoundaryMemory = GuestMemory(size: 256)
        precondition(wordBoundaryMemory.write(Data([0x0F, 0xB7, 0x05, 0xF8, 0x00, 0x00, 0x00]), offset: 0))
        precondition(wordBoundaryMemory.writeByte(0xA5, offset: 255))
        let wordBoundary = X86_64Interpreter(memory: wordBoundaryMemory)
        try wordBoundary.reset(entryPoint: 0)
        let wordBoundaryExit = try wordBoundary.run(maxInstructions: 1)
        precondition(wordBoundaryExit == .memoryFault(address: 255))
        precondition(wordBoundaryMemory.readUInt16Calls == 1)
        precondition(wordBoundaryMemory.readByteCalls == 0)

        let truncatedByteIncMemory = GuestMemory(size: 2)
        precondition(truncatedByteIncMemory.write(Data([0xFE, 0x04]), offset: 0))
        let truncatedByteInc = X86_64Interpreter(memory: truncatedByteIncMemory)
        try truncatedByteInc.reset(entryPoint: 0)
        let truncatedByteIncExit = try truncatedByteInc.run(maxInstructions: 1)
        precondition(truncatedByteIncExit == .memoryFault(address: 2))

        let truncatedMultiByteNopMemory = GuestMemory(size: 3)
        precondition(truncatedMultiByteNopMemory.write(Data([0x0F, 0x1F, 0x44]), offset: 0))
        let truncatedMultiByteNop = X86_64Interpreter(memory: truncatedMultiByteNopMemory)
        try truncatedMultiByteNop.reset(entryPoint: 0)
        let truncatedMultiByteNopExit = try truncatedMultiByteNop.run(maxInstructions: 1)
        precondition(truncatedMultiByteNopExit == .memoryFault(address: 3))

        let byteFlagMemory = GuestMemory(size: 64)
        precondition(byteFlagMemory.write(Data([
            0xB0, 0x80, 0xF6, 0xC0, 0x80, 0x0F, 0x98, 0xC3,
            0xFE, 0xC3, 0xFE, 0xCB, 0xF4
        ]), offset: 0))
        let byteFlagInterpreter = X86_64Interpreter(memory: byteFlagMemory)
        try byteFlagInterpreter.reset(entryPoint: 0)
        let byteFlagExit = try byteFlagInterpreter.run(maxInstructions: 12)
        precondition(byteFlagExit == .halted)
        precondition(byteFlagInterpreter.registerValue(3) == 1)

        let conditionalMoveMemory = GuestMemory(size: 64)
        precondition(conditionalMoveMemory.write(Data([
            0xB8, 0x05, 0x00, 0x00, 0x00,
            0x83, 0xF8, 0x05,
            0xB9, 0x02, 0x00, 0x00, 0x00,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0x0F, 0x44, 0xD9, 0xF4
        ]), offset: 0))
        let conditionalMove = X86_64Interpreter(memory: conditionalMoveMemory)
        try conditionalMove.reset(entryPoint: 0)
        let conditionalMoveExit = try conditionalMove.run(maxInstructions: 12)
        precondition(conditionalMoveExit == .halted)
        precondition(conditionalMove.registerValue(3) == 2)

        let multiByteNopMemory = GuestMemory(size: 64)
        precondition(multiByteNopMemory.write(Data([0x0F, 0x1F, 0x44, 0x00, 0x00, 0xF4]), offset: 0))
        let multiByteNop = X86_64Interpreter(memory: multiByteNopMemory)
        try multiByteNop.reset(entryPoint: 0)
        let multiByteNopExit = try multiByteNop.run(maxInstructions: 4)
        precondition(multiByteNopExit == .halted)

        // ENDBR64 is a CET landing pad and has no guest-visible side effects.
        let endbr64Memory = GuestMemory(size: 64)
        precondition(endbr64Memory.write(Data([
            0x31, 0xC0,
            0xF3, 0x0F, 0x1E, 0xFA,
            0x74, 0x05,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0xBB, 0x02, 0x00, 0x00, 0x00,
            0xF4
        ]), offset: 0))
        let endbr64 = X86_64Interpreter(memory: endbr64Memory)
        try endbr64.reset(entryPoint: 0)
        let endbr64Exit = try endbr64.run(maxInstructions: 5)
        precondition(endbr64Exit == .halted)
        precondition(endbr64.registerValue(3) == 2)

        let malformedEndbr64Memory = GuestMemory(size: 16)
        precondition(malformedEndbr64Memory.write(Data([0xF3, 0x0F, 0x1E, 0xFB]), offset: 0))
        let malformedEndbr64 = X86_64Interpreter(memory: malformedEndbr64Memory)
        try malformedEndbr64.reset(entryPoint: 0)
        let malformedEndbr64Exit = try malformedEndbr64.run(maxInstructions: 1)
        precondition(malformedEndbr64Exit == .unsupportedInstruction(address: 0))

        let truncatedEndbr64Memory = GuestMemory(size: 3)
        precondition(truncatedEndbr64Memory.write(Data([0xF3, 0x0F, 0x1E]), offset: 0))
        let truncatedEndbr64 = X86_64Interpreter(memory: truncatedEndbr64Memory)
        try truncatedEndbr64.reset(entryPoint: 0)
        let truncatedEndbr64Exit = try truncatedEndbr64.run(maxInstructions: 1)
        precondition(truncatedEndbr64Exit == .memoryFault(address: 3))

        // Exactly 15 bytes (14 redundant REX prefixes plus NOP) remain legal.
        let legal15ByteMemory = GuestMemory(size: 32)
        let legal15ByteProgram = [UInt8](repeating: 0x48, count: 14) + [0x90, 0xF4]
        precondition(legal15ByteMemory.write(Data(legal15ByteProgram), offset: 0))
        let legal15Byte = X86_64Interpreter(memory: legal15ByteMemory)
        try legal15Byte.reset(entryPoint: 0)
        let legal15ByteExit = try legal15Byte.run(maxInstructions: 2)
        precondition(legal15ByteExit == .halted)
        precondition(legal15Byte.instructionCount == 2)

        // The architectural 15-byte limit includes immediate bytes, not only prefixes.
        let overlongImmediateMemory = GuestMemory(size: 64)
        let overlongImmediateProgram = [UInt8](repeating: 0x48, count: 14)
            + [0xB8] + [UInt8](repeating: 0, count: 8)
        precondition(overlongImmediateMemory.write(Data(overlongImmediateProgram), offset: 0))
        let overlongImmediate = X86_64Interpreter(memory: overlongImmediateMemory)
        try overlongImmediate.reset(entryPoint: 0)
        let overlongImmediateExit = try overlongImmediate.run(maxInstructions: 1)
        precondition(overlongImmediateExit == .unsupportedInstruction(address: 0))
        precondition(overlongImmediate.instructionPointer == 0)

        // A ModRM/SIB displacement that crosses byte 15 must side-exit, not fault.
        let overlongSIBMemory = GuestMemory(size: 64)
        let overlongSIBProgram = [UInt8](repeating: 0x48, count: 11)
            + [0x8B, 0x04, 0x25, 0, 0, 0, 0]
        precondition(overlongSIBMemory.write(Data(overlongSIBProgram), offset: 0))
        let overlongSIB = X86_64Interpreter(memory: overlongSIBMemory)
        try overlongSIB.reset(entryPoint: 0)
        let overlongSIBExit = try overlongSIB.run(maxInstructions: 1)
        precondition(overlongSIBExit == .unsupportedInstruction(address: 0))
        precondition(overlongSIB.instructionPointer == 0)

        // Trailing immediate fetches are subject to the same whole-instruction bound.
        let overlongTrailingImmediateMemory = GuestMemory(size: 64)
        let overlongTrailingImmediateProgram = [UInt8](repeating: 0x48, count: 11)
            + [0xC7, 0xC0, 1, 0, 0, 0]
        precondition(overlongTrailingImmediateMemory.write(Data(overlongTrailingImmediateProgram), offset: 0))
        let overlongTrailingImmediate = X86_64Interpreter(memory: overlongTrailingImmediateMemory)
        try overlongTrailingImmediate.reset(entryPoint: 0)
        let overlongTrailingImmediateExit = try overlongTrailingImmediate.run(maxInstructions: 1)
        precondition(overlongTrailingImmediateExit == .unsupportedInstruction(address: 0))
        precondition(overlongTrailingImmediate.instructionPointer == 0)

        // ENDBR64 without its mandatory F3 prefix is not the landing-pad opcode.
        let unprefixedEndbr64Memory = GuestMemory(size: 16)
        precondition(unprefixedEndbr64Memory.write(Data([0x0F, 0x1E, 0xFA]), offset: 0))
        let unprefixedEndbr64 = X86_64Interpreter(memory: unprefixedEndbr64Memory)
        try unprefixedEndbr64.reset(entryPoint: 0)
        let unprefixedEndbr64Exit = try unprefixedEndbr64.run(maxInstructions: 1)
        precondition(unprefixedEndbr64Exit == .unsupportedInstruction(address: 0))
        precondition(unprefixedEndbr64.instructionPointer == 0)

        // F3 must not be silently ignored on unrelated two-byte instructions.
        let invalidF3Memory = GuestMemory(size: 16)
        precondition(invalidF3Memory.write(Data([0xF3, 0x0F, 0x05]), offset: 0))
        let invalidF3 = X86_64Interpreter(memory: invalidF3Memory)
        try invalidF3.reset(entryPoint: 0)
        let invalidF3Exit = try invalidF3.run(maxInstructions: 1)
        precondition(invalidF3Exit == .unsupportedInstruction(address: 0))
        precondition(invalidF3.instructionPointer == 0)

        let shortParityMemory = GuestMemory(size: 64)
        precondition(shortParityMemory.write(Data([
            0x31, 0xC0, 0x7A, 0x05,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0xBB, 0x02, 0x00, 0x00, 0x00, 0xF4
        ]), offset: 0))
        let shortParity = X86_64Interpreter(memory: shortParityMemory)
        try shortParity.reset(entryPoint: 0)
        let shortParityExit = try shortParity.run(maxInstructions: 8)
        precondition(shortParityExit == .halted)
        precondition(shortParity.registerValue(3) == 2)

        let nearParityMemory = GuestMemory(size: 64)
        precondition(nearParityMemory.write(Data([
            0x31, 0xC0, 0x0F, 0x8A, 0x05, 0x00, 0x00, 0x00,
            0xBB, 0x01, 0x00, 0x00, 0x00,
            0xBB, 0x02, 0x00, 0x00, 0x00, 0xF4
        ]), offset: 0))
        let nearParity = X86_64Interpreter(memory: nearParityMemory)
        try nearParity.reset(entryPoint: 0)
        let nearParityExit = try nearParity.run(maxInstructions: 8)
        precondition(nearParityExit == .halted)
        precondition(nearParity.registerValue(3) == 2)

        for code in UInt8(0)...UInt8(15) {
            for combination in 0..<32 {
                var flags: UInt64 = 0
                if combination & 0x1 != 0 { flags |= X86_64ALU.carry }
                if combination & 0x2 != 0 { flags |= X86_64ALU.zero }
                if combination & 0x4 != 0 { flags |= X86_64ALU.sign }
                if combination & 0x8 != 0 { flags |= X86_64ALU.overflow }
                if combination & 0x10 != 0 { flags |= X86_64ALU.parity }
                let cf = combination & 0x1 != 0
                let zf = combination & 0x2 != 0
                let sf = combination & 0x4 != 0
                let of = combination & 0x8 != 0
                let pf = combination & 0x10 != 0
                let expected: Bool
                switch code {
                case 0x0: expected = of
                case 0x1: expected = !of
                case 0x2: expected = cf
                case 0x3: expected = !cf
                case 0x4: expected = zf
                case 0x5: expected = !zf
                case 0x6: expected = cf || zf
                case 0x7: expected = !cf && !zf
                case 0x8: expected = sf
                case 0x9: expected = !sf
                case 0xA: expected = pf
                case 0xB: expected = !pf
                case 0xC: expected = sf != of
                case 0xD: expected = sf == of
                case 0xE: expected = zf || (sf != of)
                case 0xF: expected = !zf && (sf == of)
                default: expected = false
                }
                precondition(X86_64ALU.condition(code, flags: flags) == expected)
            }
        }

        let accumulatorExchange32Memory = GuestMemory(size: 64)
        let accumulatorExchange32Program: [UInt8] = [
            0x48, 0xB8, 0x44, 0x33, 0x22, 0x11, 0xDD, 0xCC, 0xBB, 0xAA,
            0x49, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x55, 0x66, 0x77, 0x88,
            0x41, 0x90,
            0x0F, 0x0B
        ]
        precondition(accumulatorExchange32Memory.write(Data(accumulatorExchange32Program), offset: 0))
        let accumulatorExchange32 = X86_64Interpreter(memory: accumulatorExchange32Memory)
        try accumulatorExchange32.reset(entryPoint: 0)
        let accumulatorExchange32Exit = try accumulatorExchange32.run(maxInstructions: 4)
        precondition(accumulatorExchange32Exit == .unsupportedInstruction(address: 22))
        precondition(accumulatorExchange32.registerValue(0) == 0x55667788)
        precondition(accumulatorExchange32.registerValue(8) == 0x11223344)

        let accumulatorExchange64Memory = GuestMemory(size: 64)
        let accumulatorExchange64Program: [UInt8] = [
            0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
            0x49, 0xB8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
            0x49, 0x90,
            0x0F, 0x0B
        ]
        precondition(accumulatorExchange64Memory.write(Data(accumulatorExchange64Program), offset: 0))
        let accumulatorExchange64 = X86_64Interpreter(memory: accumulatorExchange64Memory)
        try accumulatorExchange64.reset(entryPoint: 0)
        let accumulatorExchange64Exit = try accumulatorExchange64.run(maxInstructions: 4)
        precondition(accumulatorExchange64Exit == .unsupportedInstruction(address: 22))
        precondition(accumulatorExchange64.registerValue(0) == 0x8877665544332211)
        precondition(accumulatorExchange64.registerValue(8) == 0x1122334455667788)


        let registerStackMemory = GuestMemory(size: 128)
        precondition(registerStackMemory.write(Data([
            0xB8, 0x44, 0x33, 0x22, 0x11,
            0x50,
            0xB8, 0x00, 0x00, 0x00, 0x00,
            0x58, 0xF4
        ]), offset: 0))
        let registerStack = X86_64Interpreter(memory: registerStackMemory)
        try registerStack.reset(entryPoint: 0)
        let registerStackExit = try registerStack.run(maxInstructions: 5)
        precondition(registerStackExit == .halted)
        precondition(registerStack.registerValue(0) == 0x11223344)
        precondition(registerStack.registerValue(4) == 120)

        let extendedStackMemory = GuestMemory(size: 128)
        precondition(extendedStackMemory.write(Data([
            0x41, 0xB8, 0x11, 0x22, 0x33, 0x44,
            0x41, 0x50,
            0x41, 0xB8, 0x00, 0x00, 0x00, 0x00,
            0x41, 0x58, 0xF4
        ]), offset: 0))
        let extendedStack = X86_64Interpreter(memory: extendedStackMemory)
        try extendedStack.reset(entryPoint: 0)
        let extendedStackExit = try extendedStack.run(maxInstructions: 5)
        precondition(extendedStackExit == .halted)
        precondition(extendedStack.registerValue(8) == 0x44332211)
        precondition(extendedStack.registerValue(4) == 120)

        let immediateByteStackMemory = GuestMemory(size: 128)
        precondition(immediateByteStackMemory.write(Data([0x6A, 0x80, 0x58, 0xF4]), offset: 0))
        let immediateByteStack = X86_64Interpreter(memory: immediateByteStackMemory)
        try immediateByteStack.reset(entryPoint: 0)
        let immediateByteStackExit = try immediateByteStack.run(maxInstructions: 3)
        precondition(immediateByteStackExit == .halted)
        precondition(immediateByteStack.registerValue(0) == 0xFFFFFFFFFFFFFF80)

        let immediateDwordStackMemory = GuestMemory(size: 128)
        precondition(immediateDwordStackMemory.write(Data([0x68, 0x00, 0x00, 0x00, 0x80, 0x58, 0xF4]), offset: 0))
        let immediateDwordStack = X86_64Interpreter(memory: immediateDwordStackMemory)
        try immediateDwordStack.reset(entryPoint: 0)
        let immediateDwordStackExit = try immediateDwordStack.run(maxInstructions: 3)
        precondition(immediateDwordStackExit == .halted)
        precondition(immediateDwordStack.registerValue(0) == 0xFFFFFFFF80000000)

        let pushStackPointerMemory = GuestMemory(size: 128)
        precondition(pushStackPointerMemory.write(Data([0x54, 0xF4]), offset: 0))
        let pushStackPointer = X86_64Interpreter(memory: pushStackPointerMemory)
        try pushStackPointer.reset(entryPoint: 0)
        let pushStackPointerExit = try pushStackPointer.run(maxInstructions: 2)
        precondition(pushStackPointerExit == .halted)
        precondition(pushStackPointer.registerValue(4) == 112)
        precondition(pushStackPointerMemory.readUInt64(offset: 112) == 120)

        let popStackPointerMemory = GuestMemory(size: 128)
        precondition(popStackPointerMemory.write(Data([0x5C, 0xF4]), offset: 0))
        precondition(popStackPointerMemory.writeUInt64(64, offset: 120))
        let popStackPointer = X86_64Interpreter(memory: popStackPointerMemory)
        try popStackPointer.reset(entryPoint: 0)
        let popStackPointerExit = try popStackPointer.run(maxInstructions: 2)
        precondition(popStackPointerExit == .halted)
        precondition(popStackPointer.registerValue(4) == 64)

        let stackUnderflowMemory = GuestMemory(size: 8)
        precondition(stackUnderflowMemory.write(Data([0x50]), offset: 0))
        let stackUnderflow = X86_64Interpreter(memory: stackUnderflowMemory)
        try stackUnderflow.reset(entryPoint: 0)
        let stackUnderflowExit = try stackUnderflow.run(maxInstructions: 1)
        precondition(stackUnderflowExit == .memoryFault(address: 0))
        precondition(stackUnderflow.registerValue(4) == 0)

        let callStackFaultMemory = GuestMemory(size: 64)
        let callStackFaultProgram: [UInt8] = [
            0x48, 0xBC, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xE8, 0x00, 0x00, 0x00, 0x00
        ]
        precondition(callStackFaultMemory.write(Data(callStackFaultProgram), offset: 0))
        let callStackFault = X86_64Interpreter(memory: callStackFaultMemory)
        try callStackFault.reset(entryPoint: 0)
        let callStackFaultExit = try callStackFault.run(maxInstructions: 2)
        precondition(callStackFaultExit == .memoryFault(address: UInt64.max - 8))
        precondition(callStackFault.registerValue(4) == UInt64.max)


        let relativeCallFaultMemory = GuestMemory(size: 64)
        let relativeCallFaultProgram: [UInt8] = [
            0x48, 0xBC, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xE8, 0x00, 0x00, 0x00, 0x00
        ]
        precondition(relativeCallFaultMemory.write(Data(relativeCallFaultProgram), offset: 0))
        let relativeCallFault = X86_64Interpreter(memory: relativeCallFaultMemory)
        try relativeCallFault.reset(entryPoint: 0)
        let relativeCallFaultExit = try relativeCallFault.run(maxInstructions: 2)
        precondition(relativeCallFaultExit == .memoryFault(address: 64))
        precondition(relativeCallFault.registerValue(4) == 72)

        let indirectCallFaultMemory = GuestMemory(size: 64)
        let indirectCallFaultProgram: [UInt8] = [
            0x48, 0xBC, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x48, 0xB8, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xD0
        ]
        precondition(indirectCallFaultMemory.write(Data(indirectCallFaultProgram), offset: 0))
        let indirectCallFault = X86_64Interpreter(memory: indirectCallFaultMemory)
        try indirectCallFault.reset(entryPoint: 0)
        let indirectCallFaultExit = try indirectCallFault.run(maxInstructions: 3)
        precondition(indirectCallFaultExit == .memoryFault(address: 64))
        precondition(indirectCallFault.registerValue(4) == 72)

        let indirectPushFaultMemory = GuestMemory(size: 64)
        let indirectPushFaultProgram: [UInt8] = [
            0x48, 0xBC, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x48, 0xB8, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xF0
        ]
        precondition(indirectPushFaultMemory.write(Data(indirectPushFaultProgram), offset: 0))
        let indirectPushFault = X86_64Interpreter(memory: indirectPushFaultMemory)
        try indirectPushFault.reset(entryPoint: 0)
        let indirectPushFaultExit = try indirectPushFault.run(maxInstructions: 3)
        precondition(indirectPushFaultExit == .memoryFault(address: 64))
        precondition(indirectPushFault.registerValue(4) == 72)

        let leaveFaultMemory = GuestMemory(size: 64)
        precondition(leaveFaultMemory.write(Data([
            0x48, 0xBD, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xC9
        ]), offset: 0))
        let leaveFault = X86_64Interpreter(memory: leaveFaultMemory)
        try leaveFault.reset(entryPoint: 0)
        let leaveFaultExit = try leaveFault.run(maxInstructions: 2)
        precondition(leaveFaultExit == .memoryFault(address: 72))
        precondition(leaveFault.registerValue(4) == 56)
        precondition(leaveFault.registerValue(5) == 72)

#if KENRAN_BUTO_AOT_TESTS
        precondition(MemoryLayout<KenranButoAOTGuestState>.size == 96)
        precondition(MemoryLayout<KenranButoAOTMemoryCallbacks>.size == 32)
        let callbackMemory = GuestMemory(size: 4096)
        precondition(callbackMemory.write(Data([0x11,0x22,0x33,0x44]), offset: 128))
        var callbacks = KenranButoAOTExecutor.makeMemoryCallbacks(for: callbackMemory)
        var callbackRegisters = [UInt64](repeating: 0, count: 16)
        var callbackState = KenranButoAOTGuestState()
        let stateReady = callbackRegisters.withUnsafeMutableBufferPointer { regs in
            withUnsafePointer(to: &callbacks) { cb in
                iSteamAOTGuestStateInitialize(&callbackState, regs.baseAddress, 0x1000, 0x202, 0, 0, cb, 16)
            }
        }
        precondition(stateReady && iSteamAOTGuestStateIsValid(&callbackState))
        var bytes = [UInt8](repeating: 0, count: 4)
        let readOK = bytes.withUnsafeMutableBufferPointer { p in
            iSteamAOTGuestMemoryRead(&callbackState, 128, UnsafeMutableRawPointer(p.baseAddress!), p.count)
        }
        precondition(readOK && bytes == [0x11,0x22,0x33,0x44])
        let replacement:[UInt8] = [0xAA,0xBB,0xCC,0xDD]
        let writeOK = replacement.withUnsafeBufferPointer { p in
            iSteamAOTGuestMemoryWrite(&callbackState, 132, UnsafeRawPointer(p.baseAddress!), p.count)
        }
        precondition(writeOK)
        var faultByte: UInt8 = 0
        let faultOK = withUnsafeMutablePointer(to: &faultByte) { p in
            iSteamAOTGuestMemoryRead(&callbackState, 4096, UnsafeMutableRawPointer(p), 1)
        }
        precondition(!faultOK && callbackState.exit_reason == 7)
        precondition(callbackState.exit_address == 4096 && callbackState.exit_rip == 0x1000)

        if iSteamAOTExecutableMemoryIsAvailable() {
            let program = Data([0xB8,0x01,0,0,0,0xBB,0x02,0,0,0,0x01,0xD8,0xF4])
            let hybridMemory = GuestMemory(size: 8192)
            precondition(hybridMemory.write(program, offset: 0x1000))
            let executor = KenranButoAOTExecutor()
            var regs = [UInt64](repeating: 0, count: 16)
            let sideExit = executor.execute(guestCode: program, registers: &regs, rip: 0x1000,
                rflags: 0x202, fsBase: 0, gsBase: 0, memory: hybridMemory, maximumInstructions: 8)
            precondition(sideExit != nil && sideExit!.guestBytesConsumed == 10)
            precondition(sideExit!.instructionCount == 2 && sideExit!.exitRip == 0x100A)
            precondition(sideExit!.exitReason == .unsupportedInstruction)
            precondition(regs[0] == 1 && regs[3] == 2)

            let multiProgram = Data([
                0xB8,0x01,0,0,0, 0xBB,0x02,0,0,0,
                0xB9,0x03,0,0,0, 0xBA,0x04,0,0,0, 0x0F,0x0B
            ])
            let multiMemory = GuestMemory(size: 8192)
            precondition(multiMemory.write(multiProgram, offset: 0x1000))
            var multiRegisters = [UInt64](repeating: 0, count: 16)
            let multiResult = executor.execute(guestCode: multiProgram, registers: &multiRegisters,
                rip: 0x1000, rflags: 0x202, fsBase: 0, gsBase: 0, memory: multiMemory, maximumInstructions: 8)
            precondition(multiResult != nil && multiResult!.guestBytesConsumed == 20)
            precondition(multiResult!.instructionCount == 4 && multiResult!.exitRip == 0x1014)
            precondition(multiResult!.exitReason == .unsupportedInstruction)
            precondition(multiRegisters[0] == 1 && multiRegisters[3] == 2 &&
                         multiRegisters[1] == 3 && multiRegisters[2] == 4)

            let multiInterpreter = X86_64Interpreter(memory: multiMemory, aotExecutor: executor)
            try multiInterpreter.reset(entryPoint: 0x1000)
            let multiExit = try multiInterpreter.run(maxInstructions: 8)
            precondition(multiExit == .unsupportedInstruction(address: 0x1014))
            precondition(multiInterpreter.instructionCount == 4)
            precondition(executor.cachedBlockCount <= 64)
            precondition(executor.cachedExecutableBytes <= 16 * 1024 * 1024)
            for index in 0..<96 {
                let value = UInt32(index)
                let code = Data([0xB8, UInt8(truncatingIfNeeded: value), 0, 0, 0])
                var cacheRegisters = [UInt64](repeating: 0, count: 16)
                let cacheResult = executor.execute(guestCode: code, registers: &cacheRegisters,
                    rip: 0x1000 + UInt64(index) * 16, rflags: 0x202, fsBase: 0, gsBase: 0,
                    memory: multiMemory, maximumInstructions: 4)
                precondition(cacheResult != nil)
            }
            precondition(executor.cachedBlockCount <= 64)
            precondition(executor.cachedExecutableBytes <= 16 * 1024 * 1024)

            // Differentially execute MOV + SIB LEA through AOT, then side-exit
            // at UD2 and resume in the architectural interpreter.
            let leaProgram = Data([
                0x48,0xB8,0x00,0x01,0,0,0,0,0,0,
                0x48,0xB9,0x20,0,0,0,0,0,0,0,
                0x48,0x8D,0x54,0x88,0x10,
                0x0F,0x0B
            ])
            let leaMemory = GuestMemory(size: 8192)
            precondition(leaMemory.write(leaProgram, offset: 0x1000))
            var leaRegisters = [UInt64](repeating: 0, count: 16)
            let leaResult = executor.execute(guestCode: leaProgram, registers: &leaRegisters,
                rip: 0x1000, rflags: 0x202, fsBase: 0, gsBase: 0,
                memory: leaMemory, maximumInstructions: 8)
            precondition(leaResult != nil && leaResult!.guestBytesConsumed == 25)
            precondition(leaResult!.instructionCount == 3 && leaResult!.exitRip == 0x1019)
            precondition(leaResult!.exitReason == .unsupportedInstruction)
            precondition(leaRegisters[0] == 0x100 && leaRegisters[1] == 0x20 && leaRegisters[2] == 0x190)

            let leaBaseline = X86_64Interpreter(memory: leaMemory)
            try leaBaseline.reset(entryPoint: 0x1000)
            let leaBaselineExit = try leaBaseline.run(maxInstructions: 8)
            let leaHybrid = X86_64Interpreter(memory: leaMemory, aotExecutor: executor)
            try leaHybrid.reset(entryPoint: 0x1000)
            let leaHybridExit = try leaHybrid.run(maxInstructions: 8)
            precondition(leaHybridExit == leaBaselineExit)
            precondition(leaHybridExit == .unsupportedInstruction(address: 0x1019))
            precondition(leaHybrid.instructionCount == leaBaseline.instructionCount)
            for index in 0..<16 {
                precondition(leaHybrid.registerValue(index) == leaBaseline.registerValue(index))
            }
            precondition(leaHybrid.registerValue(2) == 0x190)

            // LEA must also be eligible when it is the first instruction in a block.
            // This catches the interpreter's AOT start-probe lagging behind the decoder.
            let leaFirstProgram = Data([0x48, 0x8D, 0x54, 0x88, 0x10, 0x0F, 0x0B])
            let leaFirstMemory = GuestMemory(size: 8192)
            precondition(leaFirstMemory.write(leaFirstProgram, offset: 0x1000))
            let blocksBeforeLEAFirst = executor.blocksExecuted
            let leaFirstBaseline = X86_64Interpreter(memory: leaFirstMemory)
            try leaFirstBaseline.reset(entryPoint: 0x1000)
            let leaFirstBaselineExit = try leaFirstBaseline.run(maxInstructions: 8)
            let leaFirstHybrid = X86_64Interpreter(memory: leaFirstMemory, aotExecutor: executor)
            try leaFirstHybrid.reset(entryPoint: 0x1000)
            let leaFirstHybridExit = try leaFirstHybrid.run(maxInstructions: 8)
            precondition(leaFirstHybridExit == leaFirstBaselineExit)
            precondition(leaFirstHybridExit == .unsupportedInstruction(address: 0x1005))
            precondition(leaFirstHybrid.instructionCount == leaFirstBaseline.instructionCount)
            precondition(leaFirstHybrid.registerValue(2) == 16)
            precondition(executor.blocksExecuted == blocksBeforeLEAFirst + 1)

            // Register-immediate C7 /0 must also enter AOT directly and preserve
            // x86's sign-extension of imm32 into a 64-bit destination.
            let movImmediateFirstProgram = Data([
                0x48, 0xC7, 0xC0, 0x00, 0x00, 0x00, 0x80, 0x0F, 0x0B
            ])
            let movImmediateFirstMemory = GuestMemory(size: 8192)
            precondition(movImmediateFirstMemory.write(movImmediateFirstProgram, offset: 0x1000))
            let blocksBeforeMovImmediate = executor.blocksExecuted
            let movImmediateFirstBaseline = X86_64Interpreter(memory: movImmediateFirstMemory)
            try movImmediateFirstBaseline.reset(entryPoint: 0x1000)
            let movImmediateFirstBaselineExit = try movImmediateFirstBaseline.run(maxInstructions: 8)
            let movImmediateFirstHybrid = X86_64Interpreter(memory: movImmediateFirstMemory, aotExecutor: executor)
            try movImmediateFirstHybrid.reset(entryPoint: 0x1000)
            let movImmediateFirstHybridExit = try movImmediateFirstHybrid.run(maxInstructions: 8)
            precondition(movImmediateFirstHybridExit == movImmediateFirstBaselineExit)
            precondition(movImmediateFirstHybridExit == .unsupportedInstruction(address: 0x1007))
            precondition(movImmediateFirstHybrid.instructionCount == movImmediateFirstBaseline.instructionCount)
            precondition(movImmediateFirstHybrid.registerValue(0) == 0xFFFF_FFFF_8000_0000)
            precondition(executor.blocksExecuted == blocksBeforeMovImmediate + 1)

            let baselineMemory = GuestMemory(size: 8192)
            precondition(baselineMemory.write(program, offset: 0x1000))
            let baseline = X86_64Interpreter(memory: baselineMemory)
            try baseline.reset(entryPoint: 0x1000)
            let baselineExit = try baseline.run(maxInstructions: 8)
            let hybrid = X86_64Interpreter(memory: hybridMemory, aotExecutor: executor)
            try hybrid.reset(entryPoint: 0x1000)
            let hybridExit = try hybrid.run(maxInstructions: 8)
            precondition(hybridExit == baselineExit && hybridExit == .halted)
            precondition(hybrid.instructionCount == baseline.instructionCount)
            for r in 0..<16 { precondition(hybrid.registerValue(r) == baseline.registerValue(r)) }
            precondition(executor.blocksExecuted >= 2)
            print("Kenran Butō AOT native block execution, exact-RIP side exit and differential passed")
        } else {
            print("Kenran Butō AOT native execution skipped: host lacks ARM64 executable-memory support")
        }
#endif

        print("x86-64 interpreter register, memory addressing, 16-bit operand reads, ALU flags, stack frames, indirect control flow, instruction windows, brk syscall, budget and fault tests passed")
    }
}
