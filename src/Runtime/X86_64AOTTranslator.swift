import Foundation

/// A conservative x86-64 to AArch64 block translator.
///
/// Only instructions whose guest-visible semantics are preserved without
/// changing x86 flags are emitted. Unsupported instructions stop at their
/// first byte so the caller can resume through the interpreter.
struct X86_64AOTTranslation: Codable, Equatable {
    enum StopReason: String, Codable {
        case endOfInput, unsupportedInstruction, truncatedInstruction
        case instructionLimit, outputLimit, inputLimit, invalidBudget
    }

    let machineCode: Data
    let guestBytesConsumed: Int
    let instructionCount: Int
    let stopReason: StopReason
    let fallbackOffset: Int?
    let fallbackOpcode: UInt8?

    var isComplete: Bool { stopReason == .endOfInput }
    var isCacheable: Bool { instructionCount > 0 && !machineCode.isEmpty }

    func isValid(for guestCode: Data, maximumOutputBytes: Int = 1_048_576) -> Bool {
        guard guestBytesConsumed >= 0, guestBytesConsumed <= guestCode.count,
              instructionCount >= 0, maximumOutputBytes >= 0,
              machineCode.count <= maximumOutputBytes,
              machineCode.count.isMultiple(of: 4),
              (instructionCount == 0) == machineCode.isEmpty else { return false }
        switch stopReason {
        case .endOfInput:
            return guestBytesConsumed == guestCode.count
                && fallbackOffset == nil && fallbackOpcode == nil
        case .unsupportedInstruction, .truncatedInstruction:
            guard fallbackOffset == guestBytesConsumed,
                  guestBytesConsumed < guestCode.count,
                  let fallbackOpcode else { return false }
            return fallbackOpcode == guestCode[guestCode.index(guestCode.startIndex,
                                                               offsetBy: guestBytesConsumed)]
        case .instructionLimit, .outputLimit, .inputLimit:
            return fallbackOffset == guestBytesConsumed
                && guestBytesConsumed < guestCode.count && fallbackOpcode == nil
        case .invalidBudget:
            return instructionCount == 0 && guestBytesConsumed == 0
                && fallbackOffset == nil && fallbackOpcode == nil
        }
    }
}

struct X86_64AOTTranslator {
    static let translatorIdentifier = "kenran-buto-aot-arm64"
    // Bump whenever emitted code or decoding semantics change.
    static let translatorVersion = "10"
    static let hostArchitecture = "arm64"
    static let cpuFeatures = ["armv8-a-baseline"]
    static let maximumX86InstructionLength = 15
    static let maximumInstructionBudget = 4096
    static let maximumOutputBudget = 1_048_576
    static let maximumGuestByteBudget = 65_536

    func translate(_ guestCode: Data,
                   guestRIP: UInt64? = nil,
                   maximumInstructions: Int = 4096,
                   maximumOutputBytes: Int = 1_048_576,
                   maximumGuestBytes: Int = 65_536) -> X86_64AOTTranslation {
        guard maximumInstructions > 0, maximumOutputBytes >= 4,
              maximumOutputBytes.isMultiple(of: 4), maximumGuestBytes > 0 else {
            return result([], consumed: 0, instructions: 0, reason: .invalidBudget)
        }

        // Callers cannot bypass the translator's resource limits by passing
        // Int.max or another oversized budget.
        let instructionBudget = min(maximumInstructions, Self.maximumInstructionBudget)
        let outputBudget = min(maximumOutputBytes, Self.maximumOutputBudget)
        let guestByteBudget = min(maximumGuestBytes, Self.maximumGuestByteBudget)
        return guestCode.withUnsafeBytes { raw in
            let inputCount = min(raw.count, guestByteBudget)
            let bytes = UnsafeBufferPointer(
                start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                count: inputCount
            )
            return translate(bytes, guestCodeCount: raw.count, guestRIP: guestRIP,
                             maximumInstructions: instructionBudget,
                             maximumOutputBytes: outputBudget)
        }
    }

    private func translate(_ bytes: UnsafeBufferPointer<UInt8>,
                           guestCodeCount: Int, guestRIP: UInt64?,
                           maximumInstructions: Int,
                           maximumOutputBytes: Int) -> X86_64AOTTranslation {
        var cursor = 0
        var instructions = 0
        var output = [UInt32]()
        let inputCapacity = min(bytes.count, 4096)
        let instructionCapacity = min(maximumInstructions, 1024) * 4
        let reserveWords = min(maximumOutputBytes / 4, max(1, min(inputCapacity, instructionCapacity)))
        output.reserveCapacity(reserveWords)

        while cursor < bytes.count {
            if instructions >= maximumInstructions {
                return result(output, consumed: cursor, instructions: instructions,
                              reason: .instructionLimit, fallbackOffset: cursor)
            }

            let start = cursor
            var rex: UInt8 = 0
            while cursor < bytes.count, (0x40...0x4F).contains(bytes[cursor]) {
                rex = bytes[cursor]
                cursor += 1
                if cursor - start >= Self.maximumX86InstructionLength {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
            }

            guard cursor < bytes.count else {
                if bytes.count < guestCodeCount {
                    return result(output, consumed: start, instructions: instructions,
                                  reason: .inputLimit, fallbackOffset: start)
                }
                return fallback(output, consumed: start, instructions: instructions,
                                reason: .truncatedInstruction, opcode: bytes[start])
            }

            let opcode = bytes[cursor]
            cursor += 1
            var words = EncodedWords()

            switch opcode {
            case 0x90...0x97:
                // 90 without REX.B is NOP; the REX.B form is XCHG RAX, r8.
                if opcode == 0x90 && (rex & 0x01) == 0 {
                    words.append(0xD503201F)
                } else {
                    let register = Int(opcode - 0x90) | ((rex & 0x01) != 0 ? 8 : 0)
                    words = Self.exchangeRegisters(0, register, is64Bit: (rex & 0x08) != 0)
                }

            case 0xB8...0xBF:
                let register = Int(opcode - 0xB8) | ((rex & 0x01) != 0 ? 8 : 0)
                let is64Bit = (rex & 0x08) != 0
                let immediateBytes = is64Bit ? 8 : 4
                guard bytes.count - cursor >= immediateBytes else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                // Enforce the architectural 15-byte limit across prefixes,
                // opcode and immediate, not just the prefix run.
                guard cursor - start <= Self.maximumX86InstructionLength - immediateBytes else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                var immediate: UInt64 = 0
                for index in 0..<immediateBytes {
                    immediate |= UInt64(bytes[cursor + index]) << (index * 8)
                }
                cursor += immediateBytes
                words = Self.moveImmediate(immediate, to: register, is64Bit: is64Bit)

            case 0xC7:
                // MOV r/m32, imm32 and MOV r/m64, sign-extended imm32.
                // Only register destinations are emitted; memory operands and
                // non-/0 group extensions remain interpreter side exits.
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                guard modRM >> 6 == 0b11, ((modRM >> 3) & 0x07) == 0,
                      rex & 0x04 == 0 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let register = Int(modRM & 0x07) | ((rex & 0x01) != 0 ? 8 : 0)
                guard cursor - start <= Self.maximumX86InstructionLength - 4 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                guard bytes.count - cursor >= 4 else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let immediate32 = UInt32(bytes[cursor])
                    | (UInt32(bytes[cursor + 1]) << 8)
                    | (UInt32(bytes[cursor + 2]) << 16)
                    | (UInt32(bytes[cursor + 3]) << 24)
                cursor += 4
                let is64Bit = (rex & 0x08) != 0
                let immediate = is64Bit
                    ? UInt64(bitPattern: Int64(Int32(bitPattern: immediate32)))
                    : UInt64(immediate32)
                words = Self.moveImmediate(immediate, to: register, is64Bit: is64Bit)

            case 0x87:
                // Only register operands are translated. Memory XCHG is implicitly locked.
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                guard cursor - start < Self.maximumX86InstructionLength else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                guard modRM >> 6 == 0b11 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let left = Int(modRM & 0x07) | ((rex & 0x01) != 0 ? 8 : 0)
                let right = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                words = Self.exchangeRegisters(left, right, is64Bit: (rex & 0x08) != 0)

            case 0x89, 0x8B:
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                guard cursor - start < Self.maximumX86InstructionLength else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                let mode = modRM >> 6
                guard mode == 0b11 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let reg = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                let rm = Int(modRM & 0x07) | ((rex & 0x01) != 0 ? 8 : 0)
                let destination = opcode == 0x89 ? rm : reg
                let source = opcode == 0x89 ? reg : rm
                let is64Bit = (rex & 0x08) != 0
                words.append(Self.moveRegister(source, to: destination, is64Bit: is64Bit))

            case 0x8D:
                // LEA computes an effective address but does not access guest
                // memory or modify flags. RIP-relative and oversized combined
                // displacements deliberately side-exit to the interpreter.
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                let mode = modRM >> 6
                guard mode != 0b11 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }

                let destination = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                let rmField = modRM & 0x07
                var baseRegister: Int? = nil
                var indexRegister: Int? = nil
                var scale = 0
                var requiresDisplacement32 = false
                var ripRelative = false

                if rmField == 0x04 {
                    guard cursor < bytes.count else {
                        if bytes.count < guestCodeCount {
                            return result(output, consumed: start, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: start)
                        }
                        return fallback(output, consumed: start, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[start])
                    }
                    let sib = bytes[cursor]
                    cursor += 1
                    scale = Int((sib >> 6) & 0x03)
                    let indexField = Int((sib >> 3) & 0x07)
                    let baseField = Int(sib & 0x07)
                    if indexField != 0x04 || (rex & 0x02) != 0 {
                        indexRegister = indexField | ((rex & 0x02) != 0 ? 8 : 0)
                    }
                    if mode == 0 && baseField == 0x05 {
                        requiresDisplacement32 = true
                    } else {
                        baseRegister = baseField | ((rex & 0x01) != 0 ? 8 : 0)
                    }
                } else if mode == 0 && rmField == 0x05 {
                    // ModRM mod=00/rm=101 is RIP-relative in 64-bit mode.
                    requiresDisplacement32 = true
                    ripRelative = true
                } else {
                    baseRegister = Int(rmField) | ((rex & 0x01) != 0 ? 8 : 0)
                }

                let displacementBytes = mode == 1 ? 1 : ((mode == 2 || requiresDisplacement32) ? 4 : 0)
                guard cursor - start <= Self.maximumX86InstructionLength - displacementBytes else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                var displacement: Int64 = 0
                if displacementBytes == 1 {
                    guard cursor < bytes.count else {
                        if bytes.count < guestCodeCount {
                            return result(output, consumed: start, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: start)
                        }
                        return fallback(output, consumed: start, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[start])
                    }
                    displacement = Int64(Int8(bitPattern: bytes[cursor]))
                    cursor += 1
                } else if displacementBytes == 4 {
                    guard bytes.count - cursor >= 4 else {
                        if bytes.count < guestCodeCount {
                            return result(output, consumed: start, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: start)
                        }
                        return fallback(output, consumed: start, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[start])
                    }
                    let raw = UInt32(bytes[cursor])
                        | (UInt32(bytes[cursor + 1]) << 8)
                        | (UInt32(bytes[cursor + 2]) << 16)
                        | (UInt32(bytes[cursor + 3]) << 24)
                    displacement = Int64(Int32(bitPattern: raw))
                    cursor += 4
                }
                guard cursor - start <= Self.maximumX86InstructionLength else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }

                let is64Bit = (rex & 0x08) != 0
                if ripRelative {
                    guard let guestRIP else {
                        return fallback(output, consumed: start, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[start])
                    }
                    // cursor is the total byte offset from the start of this block.
                    let nextRIP = guestRIP &+ UInt64(cursor)
                    let target = nextRIP &+ UInt64(bitPattern: displacement)
                    let value = is64Bit ? target : UInt64(UInt32(truncatingIfNeeded: target))
                    words = Self.moveImmediate(value, to: destination, is64Bit: is64Bit)
                } else {
                let displacementMagnitude = displacement < 0 ? -displacement : displacement
                if baseRegister != nil || indexRegister != nil {
                    guard displacementMagnitude <= 4095 else {
                        return fallback(output, consumed: start, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[start])
                    }
                }

                if let base = baseRegister, let index = indexRegister {
                    words.append(Self.addShiftedRegister(base, index, scale: scale,
                                                         to: destination, is64Bit: is64Bit))
                    if displacement != 0 {
                        words.append(Self.addImmediate(destination, displacement: displacement,
                                                       to: destination, is64Bit: is64Bit))
                    }
                } else if let base = baseRegister {
                    if displacement == 0 {
                        words.append(Self.moveRegister(base, to: destination, is64Bit: is64Bit))
                    } else {
                        words.append(Self.addImmediate(base, displacement: displacement,
                                                       to: destination, is64Bit: is64Bit))
                    }
                } else if let index = indexRegister {
                    words.append(Self.addShiftedRegister(31, index, scale: scale,
                                                         to: destination, is64Bit: is64Bit))
                    if displacement != 0 {
                        words.append(Self.addImmediate(destination, displacement: displacement,
                                                       to: destination, is64Bit: is64Bit))
                    }
                } else {
                    // A no-base/no-index SIB form is a sign-extended disp32.
                    words = Self.moveImmediate(UInt64(bitPattern: displacement),
                                               to: destination, is64Bit: is64Bit)
                }
                }

            case 0x98:
                // CWDE sign-extends AX to EAX; CDQE sign-extends EAX to RAX.
                let is64Bit = (rex & 0x08) != 0
                words.append(Self.extendRegister(
                    0, to: 0, sourceBits: is64Bit ? 32 : 16,
                    sourceLSB: 0, is64Bit: is64Bit, signExtend: true
                ))

            case 0x99:
                // CDQ/CQO sign-extend EAX/RAX into EDX/RDX without changing flags.
                let is64Bit = (rex & 0x08) != 0
                words.append(Self.arithmeticShiftRight(
                    0, to: 2, shift: is64Bit ? 63 : 31, is64Bit: is64Bit
                ))

            case 0x63:
                // MOVSXD r64,r/m32 is safe for register operands: SBFM
                // sign-extends the low 32 bits without changing guest flags.
                guard (rex & 0x08) != 0 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                guard modRM >> 6 == 0b11 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let destination = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                let source = Int(modRM & 0x07) | ((rex & 0x01) != 0 ? 8 : 0)
                words.append(Self.extendRegister(source, to: destination, sourceBits: 32,
                                                 sourceLSB: 0, is64Bit: true, signExtend: true))

            case 0x0F:
                // Register-only MOVZX/MOVSX byte/word forms. Memory operands
                // and unrelated 0F opcodes remain interpreter side exits.
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let secondOpcode = bytes[cursor]
                cursor += 1
                let sourceBits: Int
                let signExtend: Bool
                switch secondOpcode {
                case 0xB6: sourceBits = 8; signExtend = false
                case 0xB7: sourceBits = 16; signExtend = false
                case 0xBE: sourceBits = 8; signExtend = true
                case 0xBF: sourceBits = 16; signExtend = true
                default:
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                guard cursor < bytes.count else {
                    if bytes.count < guestCodeCount {
                        return result(output, consumed: start, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: start)
                    }
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[start])
                }
                let modRM = bytes[cursor]
                cursor += 1
                guard modRM >> 6 == 0b11 else {
                    return fallback(output, consumed: start, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[start])
                }
                let destination = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                let sourceField = Int(modRM & 0x07)
                let highByteRegister = rex == 0 && (4...7).contains(sourceField)
                let source = highByteRegister
                    ? sourceField - 4
                    : sourceField | ((rex & 0x01) != 0 ? 8 : 0)
                let sourceLSB = highByteRegister ? 8 : 0
                words.append(Self.extendRegister(source, to: destination,
                                                 sourceBits: sourceBits, sourceLSB: sourceLSB,
                                                 is64Bit: (rex & 0x08) != 0,
                                                 signExtend: signExtend))

            case 0xF3:
                // ENDBR64 is not assumed to be a NOP: guest CET policy is not
                // modelled yet, so preserve it for the interpreter fallback.
                return fallback(output, consumed: start, instructions: instructions,
                                reason: .unsupportedInstruction, opcode: bytes[start])

            default:
                return fallback(output, consumed: start, instructions: instructions,
                                reason: .unsupportedInstruction, opcode: bytes[start])
            }

            guard cursor - start <= Self.maximumX86InstructionLength else {
                return fallback(output, consumed: start, instructions: instructions,
                                reason: .unsupportedInstruction, opcode: bytes[start])
            }
            let remainingOutputWords = maximumOutputBytes / MemoryLayout<UInt32>.size - output.count
            guard words.count <= remainingOutputWords else {
                return result(output, consumed: start, instructions: instructions,
                              reason: .outputLimit, fallbackOffset: start)
            }
            append(words.first, to: &output)
            if words.count > 1 { append(words.second, to: &output) }
            if words.count > 2 { append(words.third, to: &output) }
            if words.count > 3 { append(words.fourth, to: &output) }
            instructions += 1
        }

        if bytes.count < guestCodeCount {
            return result(output, consumed: cursor, instructions: instructions,
                          reason: .inputLimit, fallbackOffset: cursor)
        }
        return result(output, consumed: cursor, instructions: instructions, reason: .endOfInput)
    }

    private struct EncodedWords {
        var first: UInt32 = 0
        var second: UInt32 = 0
        var third: UInt32 = 0
        var fourth: UInt32 = 0
        var count = 0

        mutating func append(_ word: UInt32) {
            switch count {
            case 0: first = word
            case 1: second = word
            case 2: third = word
            case 3: fourth = word
            default: preconditionFailure("A translated instruction emitted more than four words")
            }
            count += 1
        }
    }

    private func append(_ word: UInt32, to output: inout [UInt32]) {
        output.append(word.littleEndian)
    }

    private func fallback(_ code: [UInt32], consumed: Int, instructions: Int,
                          reason: X86_64AOTTranslation.StopReason, opcode: UInt8) -> X86_64AOTTranslation {
        result(code, consumed: consumed, instructions: instructions, reason: reason,
               fallbackOffset: consumed, fallbackOpcode: opcode)
    }

    private func result(_ code: [UInt32], consumed: Int, instructions: Int,
                        reason: X86_64AOTTranslation.StopReason,
                        fallbackOffset: Int? = nil,
                        fallbackOpcode: UInt8? = nil) -> X86_64AOTTranslation {
        X86_64AOTTranslation(machineCode: code.withUnsafeBytes { Data($0) }, guestBytesConsumed: consumed,
                             instructionCount: instructions, stopReason: reason,
                             fallbackOffset: fallbackOffset, fallbackOpcode: fallbackOpcode)
    }

    private static func moveImmediate(_ value: UInt64, to register: Int, is64Bit: Bool) -> EncodedWords {
        let highestHalf = is64Bit ? 3 : 1
        var firstHalf = 0
        for half in 0...highestHalf {
            if UInt16(truncatingIfNeeded: value >> (half * 16)) != 0 {
                firstHalf = half
                break
            }
        }

        var words = EncodedWords()
        let firstImmediate = UInt16(truncatingIfNeeded: value >> (firstHalf * 16))
        words.append(moveWide(firstImmediate, register: register, half: firstHalf,
                              is64Bit: is64Bit, keep: false))
        for half in 0...highestHalf where half != firstHalf {
            let chunk = UInt16(truncatingIfNeeded: value >> (half * 16))
            if chunk != 0 {
                words.append(moveWide(chunk, register: register, half: half,
                                      is64Bit: is64Bit, keep: true))
            }
        }
        return words
    }

    private static func moveWide(_ immediate: UInt16, register: Int, half: Int,
                                 is64Bit: Bool, keep: Bool) -> UInt32 {
        let base: UInt32 = is64Bit
            ? (keep ? 0xF2800000 : 0xD2800000)
            : (keep ? 0x72800000 : 0x52800000)
        return base | (UInt32(half) << 21) | (UInt32(immediate) << 5) | UInt32(register)
    }

    private static func addShiftedRegister(_ base: Int, _ index: Int, scale: Int,
                                            to destination: Int, is64Bit: Bool) -> UInt32 {
        let opcode: UInt32 = is64Bit ? 0x8B000000 : 0x0B000000
        return opcode | (UInt32(index) << 16) | (UInt32(scale) << 10)
            | (UInt32(base) << 5) | UInt32(destination)
    }

    private static func addImmediate(_ source: Int, displacement: Int64,
                                     to destination: Int, is64Bit: Bool) -> UInt32 {
        let magnitude = UInt32(displacement < 0 ? -displacement : displacement)
        let opcode: UInt32
        if is64Bit {
            opcode = displacement < 0 ? 0xD1000000 : 0x91000000
        } else {
            opcode = displacement < 0 ? 0x51000000 : 0x11000000
        }
        return opcode | (magnitude << 10) | (UInt32(source) << 5) | UInt32(destination)
    }

    private static func moveRegister(_ source: Int, to destination: Int, is64Bit: Bool) -> UInt32 {
        let base: UInt32 = is64Bit ? 0xAA0003E0 : 0x2A0003E0
        return base | (UInt32(source) << 16) | UInt32(destination)
    }

    /// UBFM/SBFM implement register-only MOVZX/MOVSX/MOVSXD. A nonzero
    /// sourceLSB selects AH/CH/DH/BH when the instruction has no REX prefix.
    private static func extendRegister(_ source: Int, to destination: Int,
                                       sourceBits: Int, sourceLSB: Int,
                                       is64Bit: Bool, signExtend: Bool) -> UInt32 {
        let opcode: UInt32
        if signExtend {
            opcode = is64Bit ? 0x93400000 : 0x13000000
        } else {
            opcode = is64Bit ? 0xD3400000 : 0x53000000
        }
        let immr = UInt32(sourceLSB)
        let imms = UInt32(sourceLSB + sourceBits - 1)
        return opcode | (immr << 16) | (imms << 10)
            | (UInt32(source) << 5) | UInt32(destination)
    }

    /// XCHG preserves guest flags. Three flag-neutral EOR operations swap
    /// the two guest registers without borrowing a non-guest host register.
    /// SBFM with the full sign-bit range implements x86 CDQ/CQO as ASR.
    private static func arithmeticShiftRight(_ source: Int, to destination: Int,
                                             shift: Int, is64Bit: Bool) -> UInt32 {
        let opcode: UInt32 = is64Bit ? 0x93400000 : 0x13000000
        let widthMask = UInt32(is64Bit ? 63 : 31)
        return opcode | (UInt32(shift) << 16) | (widthMask << 10)
            | (UInt32(source) << 5) | UInt32(destination)
    }

    private static func exchangeRegisters(_ left: Int, _ right: Int, is64Bit: Bool) -> EncodedWords {
        var words = EncodedWords()
        guard left != right else {
            // A 32-bit XCHG with the same register still zero-extends the GPR.
            words.append(moveRegister(left, to: left, is64Bit: is64Bit))
            return words
        }
        let opcode: UInt32 = is64Bit ? 0xCA000000 : 0x4A000000
        let first = opcode | (UInt32(right) << 16) | (UInt32(left) << 5) | UInt32(left)
        let second = opcode | (UInt32(right) << 16) | (UInt32(left) << 5) | UInt32(right)
        words.append(first)
        words.append(second)
        words.append(first)
        return words
    }
}
