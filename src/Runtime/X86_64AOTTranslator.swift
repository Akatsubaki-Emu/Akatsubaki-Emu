import Foundation

/// A deliberately conservative x86-64 to AArch64 block translator.
///
/// Only instructions whose guest-visible semantics are preserved without
/// changing x86 flags are emitted today. Unsupported instructions stop the
/// block at their first byte so the runtime can resume with its interpreter.
/// The emitted bytes are AArch64 machine code, but this type does not allocate
/// executable memory or execute them.
struct X86_64AOTTranslation: Codable, Equatable {
    enum StopReason: String, Codable {
        case endOfInput
        case unsupportedInstruction
        case truncatedInstruction
        case instructionLimit
        case outputLimit
        case invalidBudget
    }

    let machineCode: Data
    let guestBytesConsumed: Int
    let instructionCount: Int
    let stopReason: StopReason
    let fallbackOffset: Int?
    let fallbackOpcode: UInt8?

    var isComplete: Bool { stopReason == .endOfInput }
    var isCacheable: Bool { instructionCount > 0 && !machineCode.isEmpty }

    /// Checks the serialized artifact against the original guest block before
    /// it is allowed to leave the cache layer.
    func isValid(for guestCode: Data, maximumOutputBytes: Int = 1_048_576) -> Bool {
        guard guestBytesConsumed >= 0,
              guestBytesConsumed <= guestCode.count,
              instructionCount >= 0,
              machineCode.count <= maximumOutputBytes,
              machineCode.count.isMultiple(of: 4),
              (instructionCount == 0) == machineCode.isEmpty else { return false }

        switch stopReason {
        case .endOfInput:
            return guestBytesConsumed == guestCode.count
                && fallbackOffset == nil && fallbackOpcode == nil
        case .unsupportedInstruction, .truncatedInstruction:
            return fallbackOffset == guestBytesConsumed
                && fallbackOffset.map { $0 < guestCode.count } == true
                && fallbackOpcode == guestCode[guestCode.index(guestCode.startIndex, offsetBy: guestBytesConsumed)]
        case .instructionLimit, .outputLimit:
            return fallbackOffset == guestBytesConsumed
                && guestBytesConsumed < guestCode.count
                && fallbackOpcode == nil
        case .invalidBudget:
            return instructionCount == 0 && guestBytesConsumed == 0
                && fallbackOffset == nil && fallbackOpcode == nil
        }
    }
}

struct X86_64AOTTranslator {
    static let translatorIdentifier = "kenran-buto-aot-arm64"
    static let translatorVersion = "1"
    static let hostArchitecture = "arm64"
    static let cpuFeatures = ["armv8-a-baseline"]

    func translate(_ guestCode: Data,
                   maximumInstructions: Int = 4096,
                   maximumOutputBytes: Int = 1_048_576) -> X86_64AOTTranslation {
        guard maximumInstructions > 0, maximumOutputBytes >= 4 else {
            return result([], consumed: 0, instructions: 0, reason: .invalidBudget)
        }

        let bytes = [UInt8](guestCode)
        var cursor = 0
        var instructions = 0
        var output = [UInt8]()
        output.reserveCapacity(min(maximumOutputBytes, 4096))

        while cursor < bytes.count {
            if instructions >= maximumInstructions {
                return result(output, consumed: cursor, instructions: instructions,
                              reason: .instructionLimit, fallbackOffset: cursor)
            }

            let instructionStart = cursor
            var rex: UInt8 = 0
            while cursor < bytes.count, (0x40...0x4F).contains(bytes[cursor]) {
                rex = bytes[cursor]
                cursor += 1
                if cursor - instructionStart >= 15 {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
            }

            guard cursor < bytes.count else {
                return fallback(output, consumed: instructionStart, instructions: instructions,
                                reason: .truncatedInstruction, opcode: bytes[instructionStart])
            }

            let opcode = bytes[cursor]
            cursor += 1
            var emitted: [UInt32] = []

            switch opcode {
            case 0x90: // NOP; REX.B changes this encoding into XCHG EAX/RAX, r8.
                guard rex & 0x01 == 0 else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
                emitted = [0xD503201F]

            case 0xB8...0xBF: // MOV r32/r64, imm32/imm64
                let register = Int(opcode - 0xB8) | ((rex & 0x01) != 0 ? 8 : 0)
                let is64Bit = (rex & 0x08) != 0
                let immediateBytes = is64Bit ? 8 : 4
                guard cursor - instructionStart + immediateBytes <= 15 else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
                guard bytes.count - cursor >= immediateBytes else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[instructionStart])
                }

                var immediate: UInt64 = 0
                for index in 0..<immediateBytes {
                    immediate |= UInt64(bytes[cursor + index]) << (index * 8)
                }
                cursor += immediateBytes
                emitted = Self.moveImmediate(immediate, to: register, is64Bit: is64Bit)

            case 0x89, 0x8B: // MOV r/m32/64, r32/64 or reverse; register form only
                guard cursor < bytes.count else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[instructionStart])
                }
                let modRM = bytes[cursor]
                cursor += 1
                guard cursor - instructionStart <= 15 else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
                let mode = modRM >> 6
                guard mode == 0b11 else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
                let reg = Int((modRM >> 3) & 0x07) | ((rex & 0x04) != 0 ? 8 : 0)
                let rm = Int(modRM & 0x07) | ((rex & 0x01) != 0 ? 8 : 0)
                let destination = opcode == 0x89 ? rm : reg
                let source = opcode == 0x89 ? reg : rm
                let is64Bit = (rex & 0x08) != 0
                emitted = [Self.moveRegister(source, to: destination, is64Bit: is64Bit)]

            case 0xF3:
                // ENDBR64 is only a no-op when the guest CET policy permits it.
                // No CET feature state is represented in this translator yet.
                return fallback(output, consumed: instructionStart, instructions: instructions,
                                reason: .unsupportedInstruction, opcode: bytes[instructionStart])

            default:
                return fallback(output, consumed: instructionStart, instructions: instructions,
                                reason: .unsupportedInstruction, opcode: bytes[instructionStart])
            }

            let emittedBytes = emitted.count * MemoryLayout<UInt32>.size
            guard emittedBytes <= maximumOutputBytes - output.count else {
                return result(output, consumed: instructionStart, instructions: instructions,
                              reason: .outputLimit, fallbackOffset: instructionStart)
            }

            for word in emitted {
                output.append(UInt8(truncatingIfNeeded: word))
                output.append(UInt8(truncatingIfNeeded: word >> 8))
                output.append(UInt8(truncatingIfNeeded: word >> 16))
                output.append(UInt8(truncatingIfNeeded: word >> 24))
            }
            instructions += 1
        }

        return result(output, consumed: cursor, instructions: instructions, reason: .endOfInput)
    }

    private func fallback(_ code: [UInt8], consumed: Int, instructions: Int,
                          reason: X86_64AOTTranslation.StopReason, opcode: UInt8) -> X86_64AOTTranslation {
        result(code, consumed: consumed, instructions: instructions, reason: reason,
               fallbackOffset: consumed, fallbackOpcode: opcode)
    }

    private func result(_ code: [UInt8], consumed: Int, instructions: Int,
                        reason: X86_64AOTTranslation.StopReason,
                        fallbackOffset: Int? = nil,
                        fallbackOpcode: UInt8? = nil) -> X86_64AOTTranslation {
        X86_64AOTTranslation(
            machineCode: Data(code),
            guestBytesConsumed: consumed,
            instructionCount: instructions,
            stopReason: reason,
            fallbackOffset: fallbackOffset,
            fallbackOpcode: fallbackOpcode
        )
    }

    private static func moveImmediate(_ value: UInt64, to register: Int, is64Bit: Bool) -> [UInt32] {
        let highestHalf = is64Bit ? 3 : 1
        let chunks = (0...highestHalf).map { UInt16(truncatingIfNeeded: value >> ($0 * 16)) }
        let first = chunks.firstIndex(where: { $0 != 0 }) ?? 0
        var words = [moveWide(chunks[first], register: register, half: first,
                              is64Bit: is64Bit, keep: false)]
        for half in chunks.indices where half != first && chunks[half] != 0 {
            words.append(moveWide(chunks[half], register: register, half: half,
                                  is64Bit: is64Bit, keep: true))
        }
        return words
    }

    private static func moveWide(_ immediate: UInt16, register: Int, half: Int,
                                 is64Bit: Bool, keep: Bool) -> UInt32 {
        let base: UInt32
        if is64Bit {
            base = keep ? 0xF2800000 : 0xD2800000 // MOVK Xd / MOVZ Xd
        } else {
            base = keep ? 0x72800000 : 0x52800000 // MOVK Wd / MOVZ Wd
        }
        return base | (UInt32(half) << 21) | (UInt32(immediate) << 5) | UInt32(register)
    }

    private static func moveRegister(_ source: Int, to destination: Int, is64Bit: Bool) -> UInt32 {
        let base: UInt32 = is64Bit ? 0xAA0003E0 : 0x2A0003E0
        return base | (UInt32(source) << 16) | UInt32(destination)
    }
}
