import Foundation

enum KenranButoAOTExitReason: UInt32 { case none=0, unsupportedInstruction=1, truncatedInstruction=2, inputLimit=3, instructionLimit=4, outputLimit=5, endOfInput=6, memoryReadFault=7, memoryWriteFault=8, invalidState=9 }
struct KenranButoAOTExecutionResult { let guestBytesConsumed:Int; let instructionCount:Int; let exitReason:KenranButoAOTExitReason; let exitRip:UInt64; let exitAddress:UInt64 }
protocol KenranButoAOTExecuting: AnyObject {
    var isAvailable: Bool { get }
    func refreshAvailability() -> Bool
    func execute(guestCode:Data,registers:inout [UInt64],rip:UInt64,rflags:UInt64,fsBase:UInt64,gsBase:UInt64,memory:GuestMemory,maximumInstructions:Int)->KenranButoAOTExecutionResult?
    func invalidateAll()
}

/// Small, dependency-free x86-64 interpreter for bring-up and instruction tests.
/// This is not a Linux userspace runtime: syscalls, paging, exceptions, and most
/// x86-64 instructions are intentionally unsupported and report a visible exit.
final class X86_64Interpreter: GuestCPUBackend {
    let architecture: VMConfiguration.Architecture = .x86_64
    private(set) var instructionCount: UInt64 = 0
    private let memory: GuestMemory
    private let aotExecutor: KenranButoAOTExecuting?
    private let syscallDispatcher: LinuxSyscallDispatcher
    private var registers = [UInt64](repeating: 0, count: 16)
    private var rip: UInt64 = 0
    private var instructionWindow = [UInt8](repeating: 0, count: 15)
    private var aotInstructionWindow = [UInt8](repeating: 0, count: 4096)
    private var instructionWindowLength = 0
    private var instructionWindowCursor = 0
    private var instructionLengthExceeded = false
    private var flags: UInt64 = 0x2
    private var fsBase: UInt64 = 0
    private var gsBase: UInt64 = 0
    private var activeSegmentBase: UInt64 = 0
    private var halted = false
    private let stopLock = NSLock()
    private var stopRequested = false

    init(memory: GuestMemory, aotExecutor: KenranButoAOTExecuting? = nil) {
        self.memory = memory
        self.aotExecutor = aotExecutor
        syscallDispatcher = LinuxSyscallDispatcher(memory: memory)
    }

    func reset(entryPoint: UInt64) throws {
        aotExecutor?.invalidateAll()
        guard entryPoint < memory.size else {
            throw GuestEngineError.backendNotInstalled(.x86_64)
        }
        registers = [UInt64](repeating: 0, count: 16)
        flags = 0x2
        fsBase = 0
        gsBase = 0
        activeSegmentBase = 0
        syscallDispatcher.reset()
        registers[4] = memory.size >= 8 ? memory.size - 8 : 0 // RSP
        rip = entryPoint
        instructionCount = 0
        halted = false
        stopLock.lock()
        stopRequested = false
        stopLock.unlock()
    }

    var instructionPointer: UInt64 { rip }
    var conditionFlags: UInt64 { flags }

    func configureLinuxProcess(programBreak: UInt64, stackBase: UInt64) throws {
        try syscallDispatcher.configure(programBreak: programBreak, stackBase: stackBase)
    }

    func setInitialStackPointer(_ pointer: UInt64) throws {
        guard pointer & 0xF == 0, memory.size >= 8, pointer <= memory.size - 8 else {
            throw GuestEngineError.invalidState("The Linux initial stack pointer is outside guest memory or is not 16-byte aligned.")
        }
        registers[4] = pointer
        registers[5] = 0
    }

    func registerValue(_ index: Int) -> UInt64? {
        registers.indices.contains(index) ? registers[index] : nil
    }

    func requestStop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    func resume() {
        stopLock.lock()
        stopRequested = false
        stopLock.unlock()
    }

    func run(maxInstructions: UInt64) throws -> GuestCPUExit {
        guard maxInstructions > 0 else { throw GuestEngineError.invalidInstructionBudget }
        if halted { return .halted }
        var executed: UInt64 = 0
        // Refresh Swift-side readiness and evict cached executable blocks when JIT is unavailable.
        // The native C invoke boundary independently rechecks readiness for every block.
        let aotIsAvailable = aotExecutor?.refreshAvailability() == true
        var aotDeclined = false
        let stopCheckMask: UInt64 = aotIsAvailable ? 0x0f : 0xff
        while executed < maxInstructions {
            if executed & stopCheckMask == 0 {
                stopLock.lock()
                let shouldStop = stopRequested
                stopLock.unlock()
                if shouldStop { return .interrupted }
            }

            let instructionAddress = rip
            instructionLengthExceeded = false
            prepareInstructionWindow(at: instructionAddress)
            if let aotExecutor, aotIsAvailable, !aotDeclined, canStartAOTBlock() {
                // Never cross the current guest page while forming a translated block.
                // The architectural x86 decoder retains its independent 15-byte window.
                let aotPageRemaining = 4096 - Int(instructionAddress & 0xFFF)
                let aotWindowLength = memory.readPrefix(
                    offset: instructionAddress,
                    maximumLength: aotPageRemaining,
                    into: &aotInstructionWindow
                ) ?? 0
                if aotWindowLength > 0 {
                    let remaining = maxInstructions - executed
                    // Bound native batches so stop requests remain responsive.
                    let budget = Int(min(remaining, 16))
                    if let result = aotExecutor.execute(
                        guestCode: Data(aotInstructionWindow.prefix(aotWindowLength)),
                        registers: &registers, rip: instructionAddress, rflags: flags,
                        fsBase: fsBase, gsBase: gsBase, memory: memory,
                        maximumInstructions: budget
                    ) {
                        guard result.instructionCount >= 0 && result.instructionCount <= budget &&
                              result.guestBytesConsumed >= 0 &&
                              result.guestBytesConsumed <= aotWindowLength else {
                            return .backendUnavailable("Kenran Butō AOT returned an invalid block result.")
                        }
                        if result.instructionCount > 0 {
                            let count = UInt64(result.instructionCount)
                            executed += count
                            instructionCount &+= count
                        }
                        rip = result.exitRip
                        switch result.exitReason {
                        case .memoryReadFault, .memoryWriteFault:
                            return .memoryFault(address: result.exitAddress)
                        case .invalidState:
                            return .backendUnavailable("Kenran Butō AOT guest-state ABI validation failed.")
                        default: break
                        }
                        let (expectedRip, overflow) = instructionAddress.addingReportingOverflow(UInt64(result.guestBytesConsumed))
                        guard !overflow && result.exitRip == expectedRip &&
                              result.guestBytesConsumed > 0 && result.instructionCount > 0 else {
                            return .backendUnavailable("Kenran Butō AOT side exit did not preserve exact guest RIP.")
                        }
                        if stopRequested { return .interrupted }
                        continue
                    } else {
                        // A declined native block disables AOT for the rest of this run.
                        aotDeclined = true
                    }
                }
            }
            guard var opcode = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
            var rex: UInt8 = 0
            activeSegmentBase = 0
            var endbrPrefix = false
            var prefixCount = 0
            while true {
                if opcode == 0x64 {
                    activeSegmentBase = fsBase
                    rex = 0
                } else if opcode == 0x65 {
                    activeSegmentBase = gsBase
                    rex = 0
                } else if opcode == 0xF3 {
                    endbrPrefix = true
                    rex = 0
                } else if opcode >= 0x40 && opcode <= 0x4F {
                    rex = opcode
                } else {
                    break
                }
                prefixCount += 1
                if prefixCount > 14 {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let next = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                opcode = next
            }

            if endbrPrefix && opcode != 0x0F {
                rip = instructionAddress
                return .unsupportedInstruction(address: instructionAddress)
            }

            switch opcode {
            case 0x50...0x57: // PUSH r64
                let index = Int(opcode - 0x50) | (rex & 0x01 != 0 ? 8 : 0)
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                let nextStackPointer = registers[4] - 8
                guard memory.writeUInt64(registers[index], offset: nextStackPointer) else {
                    return .memoryFault(address: nextStackPointer)
                }
                registers[4] = nextStackPointer
            case 0x58...0x5F: // POP r64
                let index = Int(opcode - 0x58) | (rex & 0x01 != 0 ? 8 : 0)
                guard let value = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                let (nextStackPointer, overflow) = registers[4].addingReportingOverflow(8)
                guard !overflow else { return .memoryFault(address: registers[4]) }
                if index == 4 {
                    registers[4] = value
                } else {
                    registers[4] = nextStackPointer
                    registers[index] = value
                }
            case 0x68: // PUSH sign-extended imm32
                guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                let value = UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                let nextStackPointer = registers[4] - 8
                guard memory.writeUInt64(value, offset: nextStackPointer) else {
                    return .memoryFault(address: nextStackPointer)
                }
                registers[4] = nextStackPointer
            case 0x6A: // PUSH sign-extended imm8
                guard let raw = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let value = UInt64(bitPattern: Int64(Int8(bitPattern: raw)))
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                let nextStackPointer = registers[4] - 8
                guard memory.writeUInt64(value, offset: nextStackPointer) else {
                    return .memoryFault(address: nextStackPointer)
                }
                registers[4] = nextStackPointer
            case 0x90...0x97: // XCHG EAX/RAX, r32/r64
                let index = Int(opcode - 0x90) | (rex & 0x01 != 0 ? 8 : 0)
                if index != 0 {
                    if rex & 0x08 != 0 {
                        registers.swapAt(0, index)
                    } else {
                        let accumulator = UInt32(truncatingIfNeeded: registers[0])
                        let value = UInt32(truncatingIfNeeded: registers[index])
                        registers[0] = UInt64(value)
                        registers[index] = UInt64(accumulator)
                    }
                }
            case 0xF4: // HLT
                halted = true
                instructionCount &+= 1
                return .halted
            case 0xCC: // INT3
                rip = instructionAddress
                return .unsupportedInstruction(address: instructionAddress)
            case 0xB0...0xB7: // MOV r8, imm8
                guard let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let index = Int(opcode - 0xB0) | (rex & 0x01 != 0 ? 8 : 0)
                writeByteRegister(immediate, encodedIndex: index, rex: rex)
            case 0xB8...0xBF: // MOV r32, imm32 or MOV r64, imm64
                let index = Int(opcode - 0xB8) | (rex & 0x01 != 0 ? 8 : 0)
                if rex & 0x08 != 0 {
                    guard let immediate = fetchUInt64() else { return instructionFetchFailure(at: instructionAddress) }
                    registers[index] = immediate
                } else {
                    guard let immediate = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                    registers[index] = UInt64(immediate)
                }
            case 0xEB: // JMP rel8
                guard let raw = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                rip = addSigned(Int8(bitPattern: raw), to: rip)
            case 0xE9: // JMP rel32
                guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                rip = addSigned(Int32(bitPattern: raw), to: rip)
            case 0xE8: // CALL rel32
                guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                let target = addSigned(Int32(bitPattern: raw), to: rip)
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                let nextStackPointer = registers[4] - 8
                guard memory.writeUInt64(rip, offset: nextStackPointer) else {
                    return .memoryFault(address: nextStackPointer)
                }
                registers[4] = nextStackPointer
                rip = target
            case 0xC2: // RET imm16
                guard let adjustment = fetchUInt16() else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard let target = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                let (nextStackPointer, overflow) = registers[4].addingReportingOverflow(8 + UInt64(adjustment))
                guard !overflow else { return .memoryFault(address: registers[4]) }
                registers[4] = nextStackPointer
                rip = target
            case 0xC9: // LEAVE
                let framePointer = registers[5]
                guard let value = readUInt64(at: framePointer) else {
                    return .memoryFault(address: framePointer)
                }
                let (nextStackPointer, overflow) = framePointer.addingReportingOverflow(8)
                guard !overflow else { return .memoryFault(address: framePointer) }
                registers[4] = nextStackPointer
                registers[5] = value
            case 0xF6: // TEST, NOT and NEG r/m8
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 2 || group == 3 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: group == 0 ? 1 : 0) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard let source = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                switch group {
                case 0:
                    guard let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    flags = X86_64ALU.and8(source, immediate, flags: flags).flags
                case 2:
                    guard writeByteOperand(~source, to: decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                case 3:
                    let result = X86_64ALU.subtract8(0, source, flags: flags)
                    flags = result.flags
                    guard writeByteOperand(UInt8(truncatingIfNeeded: result.value), to: decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                default:
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
            case 0xFE: // INC and DEC r/m8
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 1 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard let source = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let previousCarry = flags & X86_64ALU.carry
                let result = group == 0
                    ? X86_64ALU.add8(source, 1, flags: flags)
                    : X86_64ALU.subtract8(source, 1, flags: flags)
                flags = (result.flags & ~X86_64ALU.carry) | previousCarry
                guard writeByteOperand(UInt8(truncatingIfNeeded: result.value), to: decoded.operand, modrm: modrm, rex: rex) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0xF7: // TEST, NOT and NEG
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 2 || group == 3 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: group == 0 ? 4 : 0) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let width64 = rex & 0x08 != 0
                switch group {
                case 0:
                    guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                    let immediate = width64
                        ? UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
                        : UInt64(raw)
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    flags = X86_64ALU.and(source, immediate, width64: width64, flags: flags).flags
                case 2:
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let mask = width64 ? UInt64.max : UInt64(UInt32.max)
                    guard writeOperand((~source) & mask, to: decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                case 3:
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let result = X86_64ALU.subtract(0, source, width64: width64, flags: flags)
                    flags = result.flags
                    guard writeOperand(result.value, to: decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                default:
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
            case 0xFF: // INC, DEC, indirect CALL, JMP and PUSH
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let group = (modrm >> 3) & 7
                if group == 0 || group == 1 {
                    let width64 = rex & 0x08 != 0
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let previousCarry = flags & X86_64ALU.carry
                    let result = group == 0
                        ? X86_64ALU.add(source, 1, width64: width64, flags: flags)
                        : X86_64ALU.subtract(source, 1, width64: width64, flags: flags)
                    flags = (result.flags & ~X86_64ALU.carry) | previousCarry
                    guard writeOperand(result.value, to: decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                } else {
                    guard group == 2 || group == 4 || group == 6 else {
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
                    guard let target = readOperand(decoded.operand, width64: true) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    if group == 2 || group == 6 {
                        guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                        let nextStackPointer = registers[4] - 8
                        let value = group == 2 ? rip : target
                        guard memory.writeUInt64(value, offset: nextStackPointer) else {
                            return .memoryFault(address: nextStackPointer)
                        }
                        registers[4] = nextStackPointer
                    }
                    if group != 6 { rip = target }
                }
            case 0xC3: // RET
                guard let target = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                registers[4] &+= 8
                rip = target
            case 0xC1, 0xD1, 0xD3: // SHL, SHR and SAR
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: opcode == 0xC1 ? 1 : 0) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let group = (modrm >> 3) & 7
                let kind: X86_64ALU.ShiftKind
                switch group {
                case 4: kind = .left
                case 5: kind = .logicalRight
                case 7: kind = .arithmeticRight
                default:
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                let count: UInt8
                switch opcode {
                case 0xC1:
                    guard let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    count = immediate
                case 0xD1:
                    count = 1
                default:
                    count = UInt8(truncatingIfNeeded: registers[1])
                }
                let width64 = rex & 0x08 != 0
                guard let source = readOperand(decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let result = X86_64ALU.shift(source, count: count, kind: kind,
                                             width64: width64, flags: flags)
                flags = result.flags
                guard writeOperand(result.value, to: decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0xC6: // MOV r/m8, imm8
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                guard ((modrm >> 3) & 7) == 0 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: 1),
                      let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                guard writeByteOperand(immediate, to: decoded.operand, modrm: modrm, rex: rex) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0xC7:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: 4) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard (modrm >> 3) & 7 == 0 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let immediate = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                let width64 = rex & 0x08 != 0
                let value = width64
                    ? UInt64(bitPattern: Int64(Int32(bitPattern: immediate)))
                    : UInt64(immediate)
                guard writeOperand(value, to: decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0x63: // MOVSXD r32/r64, r/m32
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard let raw = readOperand(decoded.operand, width64: false) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let signed = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
                let value = rex & 0x08 != 0
                    ? UInt64(bitPattern: signed)
                    : UInt64(UInt32(truncatingIfNeeded: signed))
                registers[decoded.reg] = value
            case 0x69, 0x6B: // IMUL r32/r64, r/m32/r/m64, immediate
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: opcode == 0x69 ? 4 : 1) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let width64 = rex & 0x08 != 0
                let immediate: UInt64
                if opcode == 0x69 {
                    guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                    immediate = width64
                        ? UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
                        : UInt64(UInt32(bitPattern: Int32(bitPattern: raw)))
                } else {
                    guard let raw = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    immediate = width64
                        ? UInt64(bitPattern: Int64(Int8(bitPattern: raw)))
                        : UInt64(UInt32(bitPattern: Int32(Int8(bitPattern: raw))))
                }
                guard let source = readOperand(decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let result = X86_64ALU.multiply(source, immediate, width64: width64, flags: flags)
                flags = result.flags
                registers[decoded.reg] = width64
                    ? result.value
                    : UInt64(UInt32(truncatingIfNeeded: result.value))
            case 0x80: // ADD/OR/AND/SUB/XOR/CMP r/m8, imm8
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 1 || group == 4 || group == 5 || group == 6 || group == 7 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: 1),
                      let immediate = fetchByte(),
                      let lhs = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let result: X86_64ALU.Result
                switch group {
                case 0: result = X86_64ALU.add8(lhs, immediate, flags: flags)
                case 1: result = X86_64ALU.or8(lhs, immediate, flags: flags)
                case 4: result = X86_64ALU.and8(lhs, immediate, flags: flags)
                case 5, 7: result = X86_64ALU.subtract8(lhs, immediate, flags: flags)
                case 6: result = X86_64ALU.xor8(lhs, immediate, flags: flags)
                default:
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                flags = result.flags
                if group != 7 && !writeByteOperand(UInt8(truncatingIfNeeded: result.value),
                    to: decoded.operand, modrm: modrm, rex: rex) {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0xA8: // TEST AL, imm8
                guard let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                flags = X86_64ALU.and8(readByteRegister(0, rex: rex), immediate, flags: flags).flags
            case 0x88, 0x8A: // MOV r/m8, r8 and MOV r8, r/m8
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                if opcode == 0x88 {
                    let value = readByteRegister(decoded.reg, rex: rex)
                    guard writeByteOperand(value, to: decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                } else {
                    guard let value = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    writeByteRegister(value, encodedIndex: decoded.reg, rex: rex)
                }
            case 0x00, 0x02, 0x08, 0x0A, 0x20, 0x22, 0x28, 0x2A, 0x30, 0x32, 0x38, 0x3A, 0x84:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard let rmValue = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let regValue = readByteRegister(decoded.reg, rex: rex)
                if opcode == 0x84 {
                    flags = X86_64ALU.and8(rmValue, regValue, flags: flags).flags
                } else {
                    let reverseDirection = opcode & 0x02 != 0
                    let lhs = reverseDirection ? regValue : rmValue
                    let rhs = reverseDirection ? rmValue : regValue
                    let operation = opcode & 0xF8
                    let result: X86_64ALU.Result
                    switch operation {
                    case 0x00: result = X86_64ALU.add8(lhs, rhs, flags: flags)
                    case 0x08: result = X86_64ALU.or8(lhs, rhs, flags: flags)
                    case 0x20: result = X86_64ALU.and8(lhs, rhs, flags: flags)
                    case 0x28, 0x38: result = X86_64ALU.subtract8(lhs, rhs, flags: flags)
                    case 0x30: result = X86_64ALU.xor8(lhs, rhs, flags: flags)
                    default:
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
                    flags = result.flags
                    if operation != 0x38 {
                        let value = UInt8(truncatingIfNeeded: result.value)
                        if reverseDirection {
                            writeByteRegister(value, encodedIndex: decoded.reg, rex: rex)
                        } else if !writeByteOperand(value, to: decoded.operand, modrm: modrm, rex: rex) {
                            return .memoryFault(address: operandAddress(decoded.operand))
                        }
                    }
                }
            case 0x89, 0x8B:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let sourceRegister = decoded.reg
                let width64 = rex & 0x08 != 0
                if opcode == 0x89 {
                    guard writeOperand(registers[sourceRegister], to: decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                } else {
                    guard let value = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    registers[sourceRegister] = width64 ? value : UInt64(UInt32(truncatingIfNeeded: value))
                }
            case 0x8D:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex, includeSegmentBase: false) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                guard case .memory(let address) = decoded.operand else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                registers[decoded.reg] = rex & 0x08 != 0
                    ? address
                    : UInt64(UInt32(truncatingIfNeeded: address))
            case 0x01, 0x03, 0x09, 0x0B, 0x21, 0x23, 0x29, 0x2B, 0x31, 0x33, 0x39, 0x3B, 0x85:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let reg = decoded.reg
                let width64 = rex & 0x08 != 0
                let registerIsDestination = opcode == 0x03 || opcode == 0x0B || opcode == 0x23 || opcode == 0x2B || opcode == 0x33 || opcode == 0x3B
                let lhs: UInt64
                let rhs: UInt64
                if registerIsDestination {
                    lhs = registers[reg]
                    guard let value = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    rhs = value
                } else {
                    guard let value = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    lhs = value
                    rhs = registers[reg]
                }
                let result: X86_64ALU.Result
                switch opcode {
                case 0x01, 0x03:
                    result = X86_64ALU.add(lhs, rhs, width64: width64, flags: flags)
                case 0x29, 0x2B, 0x39, 0x3B:
                    result = X86_64ALU.subtract(lhs, rhs, width64: width64, flags: flags)
                case 0x31, 0x33:
                    result = X86_64ALU.xor(lhs, rhs, width64: width64, flags: flags)
                case 0x09, 0x0B:
                    result = X86_64ALU.or(lhs, rhs, width64: width64, flags: flags)
                default:
                    result = X86_64ALU.and(lhs, rhs, width64: width64, flags: flags)
                }
                flags = result.flags
                if opcode != 0x39 && opcode != 0x3B && opcode != 0x85 {
                    if registerIsDestination {
                        registers[reg] = result.value
                    } else if !writeOperand(result.value, to: decoded.operand, width64: width64) {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                }
            case 0x81, 0x83:
                guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 1 || group == 4 || group == 5 || group == 6 || group == 7 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: opcode == 0x81 ? 4 : 1) else {
                    return instructionFetchFailure(at: instructionAddress)
                }
                let width64 = rex & 0x08 != 0
                let rawImmediate: UInt64
                if opcode == 0x83 {
                    guard let immediate = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    rawImmediate = width64
                        ? UInt64(bitPattern: Int64(Int8(bitPattern: immediate)))
                        : UInt64(UInt32(bitPattern: Int32(Int8(bitPattern: immediate))))
                } else {
                    guard let immediate = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                    rawImmediate = width64
                        ? UInt64(bitPattern: Int64(Int32(bitPattern: immediate)))
                        : UInt64(immediate)
                }
                guard let lhs = readOperand(decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
                let result: X86_64ALU.Result
                switch group {
                case 0: result = X86_64ALU.add(lhs, rawImmediate, width64: width64, flags: flags)
                case 1: result = X86_64ALU.or(lhs, rawImmediate, width64: width64, flags: flags)
                case 4: result = X86_64ALU.and(lhs, rawImmediate, width64: width64, flags: flags)
                case 5, 7: result = X86_64ALU.subtract(lhs, rawImmediate, width64: width64, flags: flags)
                case 6: result = X86_64ALU.xor(lhs, rawImmediate, width64: width64, flags: flags)
                default:
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                flags = result.flags
                if group != 7 && !writeOperand(result.value, to: decoded.operand, width64: width64) {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0x70...0x7F:
                guard let raw = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                let takeBranch = X86_64ALU.condition(opcode & 0x0F, flags: flags)
                if takeBranch { rip = addSigned(Int8(bitPattern: raw), to: rip) }
            case 0x0F: // Two-byte opcode map
                guard let second = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                if endbrPrefix {
                    guard second == 0x1E, rex == 0, activeSegmentBase == 0 else {
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
                    guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    guard modrm == 0xFA else {
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
                } else if second == 0x05 {
                    // SYSCALL saves the post-instruction RIP and guest flags in RCX/R11.
                    registers[1] = rip
                    registers[11] = flags
                    let number = registers[0]
                    if number == 158 {
                        registers[0] = dispatchArchPrctl(operation: registers[7], argument: registers[6])
                    } else {
                        guard let outcome = syscallDispatcher.dispatch(
                            number: number,
                            arg0: registers[7], arg1: registers[6], arg2: registers[2],
                            arg3: registers[10], arg4: registers[8], arg5: registers[9]
                        ) else {
                            rip = instructionAddress
                            return .backendUnavailable("Unsupported Linux x86-64 syscall \(number)")
                        }
                        switch outcome {
                        case .returned(let value):
                            registers[0] = value
                        case .exited:
                            halted = true
                            instructionCount &+= 1
                            return .halted
                        }
                    }
                } else if second == 0xB6 || second == 0xBE {
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                    guard let byte = readByteOperand(decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let width64 = rex & 0x08 != 0
                    let extended = second == 0xB6
                        ? UInt64(byte)
                        : UInt64(bitPattern: Int64(Int8(bitPattern: byte)))
                    registers[decoded.reg] = width64
                        ? extended
                        : UInt64(UInt32(truncatingIfNeeded: extended))
                } else if second == 0xB7 || second == 0xBF {
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                    guard let word = readWordOperand(decoded.operand) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let width64 = rex & 0x08 != 0
                    let extended = second == 0xB7
                        ? UInt64(word)
                        : UInt64(bitPattern: Int64(Int16(bitPattern: word)))
                    registers[decoded.reg] = width64
                        ? extended
                        : UInt64(UInt32(truncatingIfNeeded: extended))
                } else if second == 0xAF { // IMUL r32/r64, r/m32/r/m64
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                    let width64 = rex & 0x08 != 0
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    let result = X86_64ALU.multiply(registers[decoded.reg], source,
                                                    width64: width64, flags: flags)
                    flags = result.flags
                    registers[decoded.reg] = width64
                        ? result.value
                        : UInt64(UInt32(truncatingIfNeeded: result.value))
                } else if second >= 0x40 && second <= 0x4F {
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                    let width64 = rex & 0x08 != 0
                    guard let source = readOperand(decoded.operand, width64: width64) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                    if X86_64ALU.condition(second & 0x0F, flags: flags) {
                        registers[decoded.reg] = width64
                            ? source
                            : UInt64(UInt32(truncatingIfNeeded: source))
                    }
                } else if second >= 0x90 && second <= 0x9F {
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                    let value: UInt8 = X86_64ALU.condition(second & 0x0F, flags: flags) ? 1 : 0
                    guard writeByteOperand(value, to: decoded.operand, modrm: modrm, rex: rex) else {
                        return .memoryFault(address: operandAddress(decoded.operand))
                    }
                } else if second == 0x1F {
                    guard let modrm = fetchByte() else { return instructionFetchFailure(at: instructionAddress) }
                    guard ((modrm >> 3) & 7) == 0 else {
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
                    guard let _ = decodeRM(modrm, rex: rex) else {
                        return instructionFetchFailure(at: instructionAddress)
                    }
                } else if second >= 0x80 && second <= 0x8F {
                    guard let raw = fetchUInt32() else { return instructionFetchFailure(at: instructionAddress) }
                    let takeBranch = X86_64ALU.condition(second & 0x0F, flags: flags)
                    if takeBranch { rip = addSigned(Int32(bitPattern: raw), to: rip) }
                } else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
            default:
                rip = instructionAddress
                return .unsupportedInstruction(address: instructionAddress)
            }

            executed &+= 1
            instructionCount &+= 1
        }
        return .instructionLimit
    }


    private func dispatchArchPrctl(operation: UInt64, argument: UInt64) -> UInt64 {
        let maximumUserAddress: UInt64 = 0x0000_7FFF_FFFF_FFFF
        switch operation {
        case 0x1001: // ARCH_SET_GS
            guard argument <= maximumUserAddress else { return UInt64(bitPattern: Int64(-22)) }
            gsBase = argument
            return 0
        case 0x1002: // ARCH_SET_FS
            guard argument <= maximumUserAddress else { return UInt64(bitPattern: Int64(-22)) }
            fsBase = argument
            return 0
        case 0x1003: // ARCH_GET_FS
            return memory.writeUInt64(fsBase, offset: argument) ? 0 : UInt64(bitPattern: Int64(-14))
        case 0x1004: // ARCH_GET_GS
            return memory.writeUInt64(gsBase, offset: argument) ? 0 : UInt64(bitPattern: Int64(-14))
        default:
            return UInt64(bitPattern: Int64(-22))
        }
    }

    private enum Operand {
        case register(Int)
        case memory(UInt64)
    }

    private func decodeRM(_ modrm: UInt8, rex: UInt8, trailingImmediateBytes: UInt8 = 0, includeSegmentBase: Bool = true) -> (reg: Int, operand: Operand)? {
        let mode = modrm >> 6
        let reg = Int((modrm >> 3) & 7) | (rex & 0x04 != 0 ? 8 : 0)
        let rmField = modrm & 7
        if mode == 3 {
            return (reg, .register(Int(rmField) | (rex & 0x01 != 0 ? 8 : 0)))
        }

        var base: UInt64 = 0
        var index: UInt64 = 0
        var usesRIPRelative = false
        var displacementRequired = mode == 1 || mode == 2
        if rmField == 4 {
            guard let sib = fetchByte() else { return nil }
            let scale = UInt64(1) << ((sib >> 6) & 3)
            let indexField = (sib >> 3) & 7
            let baseField = sib & 7
            if indexField != 4 || rex & 0x02 != 0 {
                let indexRegister = Int(indexField) | (rex & 0x02 != 0 ? 8 : 0)
                index = registers[indexRegister] &* scale
            }
            if mode == 0 && baseField == 5 {
                displacementRequired = true
            } else {
                let baseRegister = Int(baseField) | (rex & 0x01 != 0 ? 8 : 0)
                base = registers[baseRegister]
            }
        } else if mode == 0 && rmField == 5 {
            usesRIPRelative = true
            displacementRequired = true
        } else {
            let baseRegister = Int(rmField) | (rex & 0x01 != 0 ? 8 : 0)
            base = registers[baseRegister]
        }

        var displacement: Int64 = 0
        if displacementRequired {
            if mode == 1 {
                guard let raw = fetchByte() else { return nil }
                displacement = Int64(Int8(bitPattern: raw))
            } else {
                guard let raw = fetchUInt32() else { return nil }
                displacement = Int64(Int32(bitPattern: raw))
            }
        }
        let addressBase = usesRIPRelative ? rip &+ UInt64(trailingImmediateBytes) : base
        let address = addressBase &+ index &+ UInt64(bitPattern: displacement)
        let segmentedAddress = address &+ (includeSegmentBase ? activeSegmentBase : 0)
        return (reg, .memory(segmentedAddress))
    }

    private func readOperand(_ operand: Operand, width64: Bool) -> UInt64? {
        switch operand {
        case .register(let index):
            return width64 ? registers[index] : UInt64(UInt32(truncatingIfNeeded: registers[index]))
        case .memory(let address):
            if width64 { return memory.readUInt64(offset: address) }
            return memory.readUInt32(offset: address).map { UInt64($0) }
        }
    }

    private func readByteRegister(_ encodedIndex: Int, rex: UInt8) -> UInt8 {
        if rex == 0 && (4...7).contains(encodedIndex) {
            return UInt8(truncatingIfNeeded: registers[encodedIndex - 4] >> 8)
        }
        return UInt8(truncatingIfNeeded: registers[encodedIndex])
    }

    private func writeByteRegister(_ value: UInt8, encodedIndex: Int, rex: UInt8) {
        if rex == 0 && (4...7).contains(encodedIndex) {
            let index = encodedIndex - 4
            registers[index] = (registers[index] & ~UInt64(0xFF00)) | (UInt64(value) << 8)
        } else {
            registers[encodedIndex] = (registers[encodedIndex] & ~UInt64(0xFF)) | UInt64(value)
        }
    }

    private func writeByteOperand(_ value: UInt8, to operand: Operand, modrm: UInt8, rex: UInt8) -> Bool {
        switch operand {
        case .memory(let address):
            return memory.writeByte(value, offset: address)
        case .register:
            let encoded = Int(modrm & 7) | (rex & 0x01 != 0 ? 8 : 0)
            writeByteRegister(value, encodedIndex: encoded, rex: rex)
            return true
        }
    }

    private func readByteOperand(_ operand: Operand, modrm: UInt8, rex: UInt8) -> UInt8? {
        switch operand {
        case .memory(let address):
            return memory.readByte(offset: address)
        case .register:
            let encoded = Int(modrm & 7) | (rex & 0x01 != 0 ? 8 : 0)
            return readByteRegister(encoded, rex: rex)
        }
    }

    private func readWordOperand(_ operand: Operand) -> UInt16? {
        switch operand {
        case .register(let index):
            return UInt16(truncatingIfNeeded: registers[index])
        case .memory(let address):
            return memory.readUInt16(offset: address)
        }
    }

    private func writeOperand(_ value: UInt64, to operand: Operand, width64: Bool) -> Bool {
        switch operand {
        case .register(let index):
            registers[index] = width64 ? value : UInt64(UInt32(truncatingIfNeeded: value))
            return true
        case .memory(let address):
            if width64 { return memory.writeUInt64(value, offset: address) }
            let word = UInt32(truncatingIfNeeded: value)
            return memory.writeUInt32(word, offset: address)
        }
    }

    private func operandAddress(_ operand: Operand) -> UInt64 {
        if case .memory(let address) = operand { return address }
        return rip
    }

    /// Probe the architectural instruction window before reading a full AOT block.
    /// Only flag-neutral instructions implemented by the current translator are eligible.
    private func canStartAOTBlock() -> Bool {
        // The interpreter may fetch across executable pages, but an AOT block
        // is deliberately bounded to the page containing its entry RIP.
        let pageRemaining = 4096 - Int(rip & 0xFFF)
        var cursor = 0
        var rex: UInt8 = 0
        while cursor < min(instructionWindowLength, pageRemaining),
              (0x40...0x4F).contains(instructionWindow[cursor]) {
            rex = instructionWindow[cursor]
            cursor += 1
            if cursor >= 15 { return false }
        }
        guard cursor < instructionWindowLength, cursor < pageRemaining else { return false }
        switch instructionWindow[cursor] {
        case 0x90...0x97:
            return true
        case 0x87:
            guard cursor + 2 <= instructionWindowLength,
                  cursor + 2 <= pageRemaining else { return false }
            return canTranslateRegisterXCHGAtCurrentWindow(opcodeOffset: cursor)
        case 0xB8...0xBF:
            let immediateBytes = rex & 0x08 != 0 ? 8 : 4
            let instructionEnd = cursor + 1 + immediateBytes
            return instructionEnd <= 15
                && instructionEnd <= instructionWindowLength
                && instructionEnd <= pageRemaining
        case 0x89, 0x8B:
            guard cursor + 2 <= instructionWindowLength,
                  cursor + 2 <= pageRemaining else { return false }
            return instructionWindow[cursor + 1] >> 6 == 0b11
        case 0xC7:
            return canTranslateRegisterImmediateMOVAtCurrentWindow(opcodeOffset: cursor, rex: rex)
        case 0x8D:
            return canTranslateLEAAtCurrentWindow(opcodeOffset: cursor, rex: rex)
        default:
            return false
        }
    }

    private func canTranslateRegisterXCHGAtCurrentWindow(opcodeOffset: Int) -> Bool {
        let modRMOffset = opcodeOffset + 1
        guard modRMOffset < instructionWindowLength else { return false }
        return instructionWindow[modRMOffset] >> 6 == 0b11
    }

    /// C7 /0 is AOT-eligible only for a complete register-immediate form.
    /// Memory destinations, other group extensions and REX.R forms side-exit.
    private func canTranslateRegisterImmediateMOVAtCurrentWindow(opcodeOffset: Int, rex: UInt8) -> Bool {
        let modRMOffset = opcodeOffset + 1
        let pageRemaining = 4096 - Int(rip & 0xFFF)
        guard opcodeOffset + 6 <= 15,
              opcodeOffset + 6 <= instructionWindowLength,
              opcodeOffset + 6 <= pageRemaining,
              modRMOffset < instructionWindowLength else { return false }
        let modRM = instructionWindow[modRMOffset]
        return modRM >> 6 == 0b11
            && ((modRM >> 3) & 0x07) == 0
            && rex & 0x04 == 0
    }

    /// Keep unsupported LEA forms on the interpreter path so one rejected
    /// instruction does not disable later AOT blocks for the rest of the run.
    private func canTranslateLEAAtCurrentWindow(opcodeOffset: Int, rex: UInt8) -> Bool {
        let modRMOffset = opcodeOffset + 1
        let pageRemaining = 4096 - Int(rip & 0xFFF)
        guard modRMOffset < instructionWindowLength else { return false }
        let modRM = instructionWindow[modRMOffset]
        let mode = modRM >> 6
        guard mode != 0b11 else { return false }

        let rmField = modRM & 0x07
        let hasSIB = rmField == 0x04
        var hasBase = true
        var hasIndex = false

        if hasSIB {
            let sibOffset = modRMOffset + 1
            guard sibOffset < instructionWindowLength else { return false }
            let sib = instructionWindow[sibOffset]
            let indexField = (sib >> 3) & 0x07
            let baseField = sib & 0x07
            hasIndex = indexField != 0x04 || (rex & 0x02) != 0
            if mode == 0 && baseField == 0x05 {
                hasBase = false
            }
        } else if mode == 0 && rmField == 0x05 {
            // AOT execution passes the guest block RIP to the translator.
            hasBase = false
        }

        let displacementBytes = mode == 1 ? 1 : ((mode == 2 || (mode == 0 && !hasBase)) ? 4 : 0)
        let displacementOffset = modRMOffset + 1 + (hasSIB ? 1 : 0)
        let instructionEnd = displacementOffset + displacementBytes
        guard instructionEnd <= 15, instructionEnd <= instructionWindowLength,
              instructionEnd <= pageRemaining else { return false }

        if (hasBase || hasIndex) && displacementBytes > 0 {
            let displacement: Int64
            if displacementBytes == 1 {
                displacement = Int64(Int8(bitPattern: instructionWindow[displacementOffset]))
            } else {
                let raw = UInt32(instructionWindow[displacementOffset])
                    | (UInt32(instructionWindow[displacementOffset + 1]) << 8)
                    | (UInt32(instructionWindow[displacementOffset + 2]) << 16)
                    | (UInt32(instructionWindow[displacementOffset + 3]) << 24)
                displacement = Int64(Int32(bitPattern: raw))
            }
            guard (-4095...4095).contains(displacement) else { return false }
        }
        return true
    }

    private func prepareInstructionWindow(at address: UInt64) {
        instructionWindowLength = memory.readPrefix(offset: address, into: &instructionWindow) ?? 0
        instructionWindowCursor = 0
    }

    private func instructionFetchFailure(at instructionAddress: UInt64) -> GuestCPUExit {
        guard instructionLengthExceeded else { return .memoryFault(address: rip) }
        rip = instructionAddress
        return .unsupportedInstruction(address: instructionAddress)
    }

    private func fetchByte() -> UInt8? {
        guard instructionWindowCursor < 15 else {
            instructionLengthExceeded = true
            return nil
        }
        if instructionWindowCursor < instructionWindowLength {
            let value = instructionWindow[instructionWindowCursor]
            instructionWindowCursor += 1
            rip &+= 1
            return value
        }
        guard let value = memory.readExecuteByte(offset: rip) else { return nil }
        instructionWindowCursor += 1
        rip &+= 1
        return value
    }

    private func fetchUInt16() -> UInt16? {
        guard let low = fetchByte(), let high = fetchByte() else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    private func readExecutableInteger(at address: UInt64, byteCount: Int) -> UInt64? {
        guard (1...8).contains(byteCount) else { return nil }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            let (byteAddress, overflow) = address.addingReportingOverflow(UInt64(index))
            guard !overflow, let byte = memory.readExecuteByte(offset: byteAddress) else { return nil }
            value |= UInt64(byte) << (index * 8)
        }
        return value
    }

    private func fetchUInt32() -> UInt32? {
        guard instructionWindowCursor <= 11 else {
            instructionLengthExceeded = true
            return nil
        }
        if instructionWindowCursor <= instructionWindowLength,
           instructionWindowLength - instructionWindowCursor >= 4 {
            let offset = instructionWindowCursor
            let value = UInt32(instructionWindow[offset])
                | UInt32(instructionWindow[offset + 1]) << 8
                | UInt32(instructionWindow[offset + 2]) << 16
                | UInt32(instructionWindow[offset + 3]) << 24
            instructionWindowCursor += 4
            rip &+= 4
            return value
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            guard let byte = fetchByte() else { return nil }
            value |= UInt32(byte) << (index * 8)
        }
        return value
    }

    private func fetchUInt64() -> UInt64? {
        guard instructionWindowCursor <= 7 else {
            instructionLengthExceeded = true
            return nil
        }
        if instructionWindowCursor <= instructionWindowLength,
           instructionWindowLength - instructionWindowCursor >= 8 {
            let offset = instructionWindowCursor
            let value = UInt64(instructionWindow[offset])
                | UInt64(instructionWindow[offset + 1]) << 8
                | UInt64(instructionWindow[offset + 2]) << 16
                | UInt64(instructionWindow[offset + 3]) << 24
                | UInt64(instructionWindow[offset + 4]) << 32
                | UInt64(instructionWindow[offset + 5]) << 40
                | UInt64(instructionWindow[offset + 6]) << 48
                | UInt64(instructionWindow[offset + 7]) << 56
            instructionWindowCursor += 8
            rip &+= 8
            return value
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            guard let byte = fetchByte() else { return nil }
            value |= UInt64(byte) << (index * 8)
        }
        return value
    }

    private func readUInt64(at address: UInt64) -> UInt64? {
        memory.readUInt64(offset: address)
    }

    private func addSigned(_ displacement: Int8, to base: UInt64) -> UInt64 {
        displacement >= 0 ? base &+ UInt64(displacement) : base &- UInt64(-Int16(displacement))
    }

    private func addSigned(_ displacement: Int32, to base: UInt64) -> UInt64 {
        displacement >= 0 ? base &+ UInt64(displacement) : base &- UInt64(-Int64(displacement))
    }
}
