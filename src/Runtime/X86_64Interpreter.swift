import Foundation

/// Small, dependency-free x86-64 interpreter for bring-up and instruction tests.
/// This is not a Linux userspace runtime: syscalls, paging, exceptions, and most
/// x86-64 instructions are intentionally unsupported and report a visible exit.
final class X86_64Interpreter: GuestCPUBackend {
    let architecture: VMConfiguration.Architecture = .x86_64
    private(set) var instructionCount: UInt64 = 0
    private let memory: GuestMemory
    private let syscallDispatcher: LinuxSyscallDispatcher
    private var registers = [UInt64](repeating: 0, count: 16)
    private var rip: UInt64 = 0
    private var instructionWindow = [UInt8](repeating: 0, count: 15)
    private var instructionWindowStart: UInt64 = 0
    private var instructionWindowLength = 0
    private var flags: UInt64 = 0x2
    private var halted = false
    private let stopLock = NSLock()
    private var stopRequested = false

    init(memory: GuestMemory) {
        self.memory = memory
        syscallDispatcher = LinuxSyscallDispatcher(memory: memory)
    }

    func reset(entryPoint: UInt64) throws {
        guard entryPoint < memory.size else {
            throw GuestEngineError.backendNotInstalled(.x86_64)
        }
        registers = [UInt64](repeating: 0, count: 16)
        flags = 0x2
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
        while executed < maxInstructions {
            if executed & 0xff == 0 {
                stopLock.lock()
                let shouldStop = stopRequested
                stopLock.unlock()
                if shouldStop { return .interrupted }
            }

            let instructionAddress = rip
            prepareInstructionWindow(at: instructionAddress)
            guard var opcode = fetchByte() else { return .memoryFault(address: rip) }
            var rex: UInt8 = 0
            if opcode >= 0x40 && opcode <= 0x4F {
                rex = opcode
                guard let next = fetchByte() else { return .memoryFault(address: rip) }
                opcode = next
            }

            switch opcode {
            case 0x90: // NOP
                break
            case 0xF4: // HLT
                halted = true
                instructionCount &+= 1
                return .halted
            case 0xCC: // INT3
                rip = instructionAddress
                return .unsupportedInstruction(address: instructionAddress)
            case 0xB8...0xBF: // MOV r32, imm32 or MOV r64, imm64
                let index = Int(opcode - 0xB8) | (rex & 0x01 != 0 ? 8 : 0)
                if rex & 0x08 != 0 {
                    guard let immediate = fetchUInt64() else { return .memoryFault(address: rip) }
                    registers[index] = immediate
                } else {
                    guard let immediate = fetchUInt32() else { return .memoryFault(address: rip) }
                    registers[index] = UInt64(immediate)
                }
            case 0xEB: // JMP rel8
                guard let raw = fetchByte() else { return .memoryFault(address: rip) }
                rip = addSigned(Int8(bitPattern: raw), to: rip)
            case 0xE9: // JMP rel32
                guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
                rip = addSigned(Int32(bitPattern: raw), to: rip)
            case 0xE8: // CALL rel32
                guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
                let target = addSigned(Int32(bitPattern: raw), to: rip)
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                registers[4] -= 8
                guard memory.writeUInt64(rip, offset: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                rip = target
            case 0xC2: // RET imm16
                guard let adjustment = fetchUInt16() else {
                    return .memoryFault(address: rip)
                }
                guard let target = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                let (nextStackPointer, overflow) = registers[4].addingReportingOverflow(8 + UInt64(adjustment))
                guard !overflow else { return .memoryFault(address: registers[4]) }
                registers[4] = nextStackPointer
                rip = target
            case 0xC9: // LEAVE
                registers[4] = registers[5]
                guard let value = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                guard registers[4] <= UInt64.max - 8 else { return .memoryFault(address: registers[4]) }
                registers[5] = value
                registers[4] += 8
            case 0xF7: // TEST, NOT and NEG
                guard let modrm = fetchByte() else { return .memoryFault(address: rip) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 2 || group == 3 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: group == 0 ? 4 : 0) else {
                    return .memoryFault(address: rip)
                }
                let width64 = rex & 0x08 != 0
                switch group {
                case 0:
                    guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
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
                    return .memoryFault(address: rip)
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
                        registers[4] -= 8
                        let value = group == 2 ? rip : target
                        guard memory.writeUInt64(value, offset: registers[4]) else {
                            return .memoryFault(address: registers[4])
                        }
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
                    return .memoryFault(address: rip)
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
                    guard let immediate = fetchByte() else { return .memoryFault(address: rip) }
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
            case 0xC7:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: 4) else {
                    return .memoryFault(address: rip)
                }
                guard (modrm >> 3) & 7 == 0 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let immediate = fetchUInt32() else { return .memoryFault(address: rip) }
                let width64 = rex & 0x08 != 0
                let value = width64
                    ? UInt64(bitPattern: Int64(Int32(bitPattern: immediate)))
                    : UInt64(immediate)
                guard writeOperand(value, to: decoded.operand, width64: width64) else {
                    return .memoryFault(address: operandAddress(decoded.operand))
                }
            case 0x63: // MOVSXD r32/r64, r/m32
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return .memoryFault(address: rip)
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
                    return .memoryFault(address: rip)
                }
                let width64 = rex & 0x08 != 0
                let immediate: UInt64
                if opcode == 0x69 {
                    guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
                    immediate = width64
                        ? UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
                        : UInt64(UInt32(bitPattern: Int32(bitPattern: raw)))
                } else {
                    guard let raw = fetchByte() else { return .memoryFault(address: rip) }
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
            case 0x68, 0x6A:
                let value: UInt64
                if opcode == 0x68 {
                    guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
                    value = UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
                } else {
                    guard let raw = fetchByte() else { return .memoryFault(address: rip) }
                    value = UInt64(bitPattern: Int64(Int8(bitPattern: raw)))
                }
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                registers[4] -= 8
                guard memory.writeUInt64(value, offset: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
            case 0x50...0x57: // PUSH r64
                let index = Int(opcode - 0x50) | (rex & 0x01 != 0 ? 8 : 0)
                let value = registers[index] // PUSH RSP stores the pre-decrement value.
                guard registers[4] >= 8 else { return .memoryFault(address: registers[4]) }
                registers[4] -= 8
                guard memory.writeUInt64(value, offset: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
            case 0x58...0x5F: // POP r64
                let index = Int(opcode - 0x58) | (rex & 0x01 != 0 ? 8 : 0)
                guard let value = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                if index == 4 {
                    // POP RSP loads the popped value directly; it does not add 8.
                    registers[4] = value
                } else {
                    registers[index] = value
                    registers[4] &+= 8
                }
            case 0x89, 0x8B:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return .memoryFault(address: rip)
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
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return .memoryFault(address: rip)
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
                    return .memoryFault(address: rip)
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
                guard let modrm = fetchByte() else { return .memoryFault(address: rip) }
                let group = (modrm >> 3) & 7
                guard group == 0 || group == 1 || group == 4 || group == 5 || group == 6 || group == 7 else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                guard let decoded = decodeRM(modrm, rex: rex, trailingImmediateBytes: opcode == 0x81 ? 4 : 1) else {
                    return .memoryFault(address: rip)
                }
                let width64 = rex & 0x08 != 0
                let rawImmediate: UInt64
                if opcode == 0x83 {
                    guard let immediate = fetchByte() else { return .memoryFault(address: rip) }
                    rawImmediate = width64
                        ? UInt64(bitPattern: Int64(Int8(bitPattern: immediate)))
                        : UInt64(UInt32(bitPattern: Int32(Int8(bitPattern: immediate))))
                } else {
                    guard let immediate = fetchUInt32() else { return .memoryFault(address: rip) }
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
            case 0x72, 0x73, 0x74, 0x75, 0x78, 0x79, 0x7C, 0x7D, 0x7E, 0x7F:
                guard let raw = fetchByte() else { return .memoryFault(address: rip) }
                guard let takeBranch = X86_64ALU.condition(opcode & 0x0F, flags: flags) else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
                }
                if takeBranch { rip = addSigned(Int8(bitPattern: raw), to: rip) }
            case 0x0F: // Two-byte opcode map
                guard let second = fetchByte() else { return .memoryFault(address: rip) }
                if second == 0x05 {
                    let number = registers[0]
                    let arguments = [registers[7], registers[6], registers[2],
                                     registers[10], registers[8], registers[9]]
                    guard let outcome = syscallDispatcher.dispatch(number: number, arguments: arguments) else {
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
                } else if second == 0xB6 || second == 0xBE {
                    guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                        return .memoryFault(address: rip)
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
                        return .memoryFault(address: rip)
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
                        return .memoryFault(address: rip)
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
                } else if [UInt8(0x82), 0x83, 0x84, 0x85, 0x88, 0x89, 0x8C, 0x8D, 0x8E, 0x8F].contains(second) {
                    guard let raw = fetchUInt32() else { return .memoryFault(address: rip) }
                    guard let takeBranch = X86_64ALU.condition(second & 0x0F, flags: flags) else {
                        rip = instructionAddress
                        return .unsupportedInstruction(address: instructionAddress)
                    }
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

    private enum Operand {
        case register(Int)
        case memory(UInt64)
    }

    private func decodeRM(_ modrm: UInt8, rex: UInt8, trailingImmediateBytes: UInt8 = 0) -> (reg: Int, operand: Operand)? {
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
        return (reg, .memory(address))
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

    private func readByteOperand(_ operand: Operand, modrm: UInt8, rex: UInt8) -> UInt8? {
        switch operand {
        case .memory(let address):
            return memory.readByte(offset: address)
        case .register:
            let encoded = Int(modrm & 7)
            if rex == 0 && (4...7).contains(encoded) {
                return UInt8(truncatingIfNeeded: registers[encoded - 4] >> 8)
            }
            let index = encoded | (rex & 0x01 != 0 ? 8 : 0)
            return UInt8(truncatingIfNeeded: registers[index])
        }
    }

    private func readWordOperand(_ operand: Operand) -> UInt16? {
        switch operand {
        case .register(let index):
            return UInt16(truncatingIfNeeded: registers[index])
        case .memory(let address):
            let (nextAddress, overflow) = address.addingReportingOverflow(1)
            guard !overflow, let low = memory.readByte(offset: address),
                  let high = memory.readByte(offset: nextAddress) else { return nil }
            return UInt16(low) | UInt16(high) << 8
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

    private func prepareInstructionWindow(at address: UInt64) {
        instructionWindowStart = address
        instructionWindowLength = memory.readPrefix(offset: address, into: &instructionWindow) ?? 0
    }

    private func instructionWindowOffset(for address: UInt64, length: Int) -> Int? {
        guard address >= instructionWindowStart else { return nil }
        let offset = address - instructionWindowStart
        guard offset <= UInt64(instructionWindowLength),
              UInt64(length) <= UInt64(instructionWindowLength) - offset else { return nil }
        return Int(offset)
    }

    private func fetchByte() -> UInt8? {
        if let offset = instructionWindowOffset(for: rip, length: 1) {
            let value = instructionWindow[offset]
            rip &+= 1
            return value
        }
        guard let value = memory.readByte(offset: rip) else { return nil }
        rip &+= 1
        return value
    }

    private func fetchUInt16() -> UInt16? {
        guard let low = fetchByte(), let high = fetchByte() else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    private func fetchUInt32() -> UInt32? {
        if let offset = instructionWindowOffset(for: rip, length: 4) {
            let value = UInt32(instructionWindow[offset])
                | UInt32(instructionWindow[offset + 1]) << 8
                | UInt32(instructionWindow[offset + 2]) << 16
                | UInt32(instructionWindow[offset + 3]) << 24
            rip &+= 4
            return value
        }
        guard let value = memory.readUInt32(offset: rip) else { return nil }
        rip &+= 4
        return value
    }

    private func fetchUInt64() -> UInt64? {
        if let offset = instructionWindowOffset(for: rip, length: 8) {
            var value: UInt64 = 0
            for shift in 0..<8 { value |= UInt64(instructionWindow[offset + shift]) << (shift * 8) }
            rip &+= 8
            return value
        }
        guard let value = memory.readUInt64(offset: rip) else { return nil }
        rip &+= 8
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
