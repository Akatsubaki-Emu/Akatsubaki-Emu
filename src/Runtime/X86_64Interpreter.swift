import Foundation

/// Small, dependency-free x86-64 interpreter for bring-up and instruction tests.
/// This is not a Linux userspace runtime: syscalls, paging, exceptions, and most
/// x86-64 instructions are intentionally unsupported and report a visible exit.
final class X86_64Interpreter: GuestCPUBackend {
    let architecture: VMConfiguration.Architecture = .x86_64
    private(set) var instructionCount: UInt64 = 0
    private let memory: GuestMemory
    private var registers = [UInt64](repeating: 0, count: 16)
    private var rip: UInt64 = 0
    private var flags: UInt64 = 0x2
    private var halted = false
    private let stopLock = NSLock()
    private var stopRequested = false

    init(memory: GuestMemory) {
        self.memory = memory
    }

    func reset(entryPoint: UInt64) throws {
        guard entryPoint < memory.size else {
            throw GuestEngineError.backendNotInstalled(.x86_64)
        }
        registers = [UInt64](repeating: 0, count: 16)
        flags = 0x2
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
                guard let adjustment = fetchUInt16(),
                      let target = readUInt64(at: registers[4]) else {
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
            case 0xFF: // Indirect CALL, JMP and PUSH
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return .memoryFault(address: rip)
                }
                let group = (modrm >> 3) & 7
                guard group == 2 || group == 4 || group == 6,
                      let target = readOperand(decoded.operand, width64: true) else {
                    rip = instructionAddress
                    return .unsupportedInstruction(address: instructionAddress)
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
            case 0xC3: // RET
                guard let target = readUInt64(at: registers[4]) else {
                    return .memoryFault(address: registers[4])
                }
                registers[4] &+= 8
                rip = target
            case 0xC7:
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
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
                guard let modrm = fetchByte(), let decoded = decodeRM(modrm, rex: rex) else {
                    return .memoryFault(address: rip)
                }
                let group = (modrm >> 3) & 7
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
                if second == 0x05 { // SYSCALL — small Linux x86-64 userspace ABI subset
                    let number = registers[0] // RAX
                    switch number {
                    case 60, 231: // exit / exit_group
                        halted = true
                        instructionCount &+= 1
                        return .halted
                    case 1: // write(fd, buffer, count)
                        let descriptor = registers[7] // RDI
                        let address = registers[6] // RSI
                        let requested = registers[2] // RDX
                        guard descriptor == 1 || descriptor == 2 else {
                            registers[0] = UInt64(bitPattern: Int64(-9)) // -EBADF
                            break
                        }
                        if requested == 0 {
                            registers[0] = 0
                            break
                        }
                        guard requested <= 1_048_576,
                              requested <= UInt64(Int.max),
                              let bytes = memory.read(offset: address, length: Int(requested)) else {
                            registers[0] = UInt64(bitPattern: Int64(-14)) // -EFAULT
                            break
                        }
                        if let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
                            EmulationLog.shared.write("[guest stdout] " + text)
                        } else if !bytes.isEmpty {
                            EmulationLog.shared.write("[guest stdout] <\(bytes.count) non-UTF8 bytes>")
                        }
                        registers[0] = requested
                    default:
                        // Make unsupported syscalls explicit instead of silently
                        // pretending a guest OS or full Linux ABI is available.
                        rip = instructionAddress
                        return .backendUnavailable("Unsupported Linux x86-64 syscall \(number)")
                    }
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

    private func decodeRM(_ modrm: UInt8, rex: UInt8) -> (reg: Int, operand: Operand)? {
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
        let addressBase = usesRIPRelative ? rip : base
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

    private func writeOperand(_ value: UInt64, to operand: Operand, width64: Bool) -> Bool {
        switch operand {
        case .register(let index):
            registers[index] = width64 ? value : UInt64(UInt32(truncatingIfNeeded: value))
            return true
        case .memory(let address):
            if width64 { return memory.writeUInt64(value, offset: address) }
            let word = UInt32(truncatingIfNeeded: value)
            let bytes = Data([
                UInt8(truncatingIfNeeded: word),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 24)
            ])
            return memory.write(bytes, offset: address)
        }
    }

    private func operandAddress(_ operand: Operand) -> UInt64 {
        if case .memory(let address) = operand { return address }
        return rip
    }

    private func fetchByte() -> UInt8? {
        guard let value = memory.readByte(offset: rip) else { return nil }
        rip &+= 1
        return value
    }

    private func fetchUInt16() -> UInt16? {
        guard let low = fetchByte(), let high = fetchByte() else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    private func fetchUInt32() -> UInt32? {
        guard let value = memory.readUInt32(offset: rip) else { return nil }
        rip &+= 4
        return value
    }

    private func fetchUInt64() -> UInt64? {
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
