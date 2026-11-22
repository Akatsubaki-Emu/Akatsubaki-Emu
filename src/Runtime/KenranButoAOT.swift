import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Conservative x86-64 to AArch64 block translation. Unsupported instructions
/// stop at their first byte for interpreter fallback. Output is not executable
/// until a platform-verified runtime adapter maps and dispatches it.
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
            return guestBytesConsumed == guestCode.count && fallbackOffset == nil && fallbackOpcode == nil
        case .unsupportedInstruction, .truncatedInstruction:
            guard let fallbackOffset, fallbackOffset == guestBytesConsumed,
                  fallbackOffset < guestCode.count else { return false }
            return fallbackOpcode == guestCode[guestCode.index(guestCode.startIndex, offsetBy: guestBytesConsumed)]
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
    static let translatorVersion = "2"
    static let hostArchitecture = "arm64"
    static let cpuFeatures = ["armv8-a-baseline"]
    static let maximumInstructionBudget = 4096
    static let maximumOutputBudget = 1_048_576
    static let maximumInputBudget = 1_048_576

    func translate(_ guestCode: Data, maximumInstructions: Int = 4096,
                   maximumOutputBytes: Int = 1_048_576,
                   maximumInputBytes: Int = 65_536) -> X86_64AOTTranslation {
        guard maximumInstructions > 0, maximumOutputBytes >= 4, maximumInputBytes > 0 else {
            return result([], consumed: 0, instructions: 0, reason: .invalidBudget)
        }
        let instructionBudget = min(maximumInstructions, Self.maximumInstructionBudget)
        let outputBudget = min(maximumOutputBytes, Self.maximumOutputBudget)
        let inputBudget = min(maximumInputBytes, Self.maximumInputBudget)

        return guestCode.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let availableBytes = min(bytes.count, inputBudget)
            var cursor = 0
            var instructions = 0
            var output = [UInt8]()
            output.reserveCapacity(min(outputBudget, instructionBudget * 16))

            while cursor < availableBytes {
                if instructions >= instructionBudget {
                    return result(output, consumed: cursor, instructions: instructions,
                                  reason: .instructionLimit, fallbackOffset: cursor)
                }
                let instructionStart = cursor
                var rex: UInt8 = 0
                while cursor < availableBytes, (0x40...0x4F).contains(bytes[cursor]) {
                    rex = bytes[cursor]
                    cursor += 1
                }
                guard cursor < availableBytes else {
                    if availableBytes < bytes.count {
                        return result(output, consumed: instructionStart, instructions: instructions,
                                      reason: .inputLimit, fallbackOffset: instructionStart)
                    }
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .truncatedInstruction, opcode: bytes[instructionStart])
                }

                let opcode = bytes[cursor]
                cursor += 1
                var emittedWordCount = 0
                var immediate: UInt64 = 0
                var destinationRegister = 0
                var is64BitMove = false
                var isImmediateMove = false
                var registerMoveWord: UInt32 = 0

                switch opcode {
                case 0x90: // REX.B=1 encodes XCHG with R8/R8D, not NOP.
                    guard (rex & 0x01) == 0 else {
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                    }
                    emittedWordCount = 1

                case 0xB8...0xBF: // MOV r32/r64, imm32/imm64
                    destinationRegister = Int(opcode - 0xB8) | ((rex & 0x01) != 0 ? 8 : 0)
                    is64BitMove = (rex & 0x08) != 0
                    let immediateBytes = is64BitMove ? 8 : 4
                    guard availableBytes - cursor >= immediateBytes else {
                        if availableBytes < bytes.count {
                            return result(output, consumed: instructionStart, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: instructionStart)
                        }
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[instructionStart])
                    }
                    for index in 0..<immediateBytes {
                        immediate |= UInt64(bytes[cursor + index]) << (index * 8)
                    }
                    cursor += immediateBytes
                    emittedWordCount = Self.moveImmediateWordCount(immediate, is64Bit: is64BitMove)
                    isImmediateMove = true

                case 0x89, 0x8B: // Register-only MOV; memory operands fall back.
                    guard cursor < availableBytes else {
                        if availableBytes < bytes.count {
                            return result(output, consumed: instructionStart, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: instructionStart)
                        }
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[instructionStart])
                    }
                    let modRM = bytes[cursor]
                    cursor += 1
                    guard (modRM >> 6) == 0b11 else {
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                    }
                    let reg = Int((modRM >> 3) & 7) | ((rex & 4) != 0 ? 8 : 0)
                    let rm = Int(modRM & 7) | ((rex & 1) != 0 ? 8 : 0)
                    let destination = opcode == 0x89 ? rm : reg
                    let source = opcode == 0x89 ? reg : rm
                    registerMoveWord = Self.moveRegister(source, to: destination, is64Bit: (rex & 8) != 0)
                    emittedWordCount = 1

                case 0xF3: // Exact ENDBR64 landing pad; CET enforcement is not implemented.
                    guard rex == 0 else {
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                    }
                    guard availableBytes - cursor >= 3 else {
                        if availableBytes < bytes.count {
                            return result(output, consumed: instructionStart, instructions: instructions,
                                          reason: .inputLimit, fallbackOffset: instructionStart)
                        }
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .truncatedInstruction, opcode: bytes[instructionStart])
                    }
                    guard bytes[cursor] == 0x0F, bytes[cursor + 1] == 0x1E,
                          bytes[cursor + 2] == 0xFA else {
                        return fallback(output, consumed: instructionStart, instructions: instructions,
                                        reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                    }
                    cursor += 3
                    emittedWordCount = 1

                default:
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }

                // Enforce the architectural 15-byte x86 instruction maximum after decoding.
                guard cursor - instructionStart <= 15 else {
                    return fallback(output, consumed: instructionStart, instructions: instructions,
                                    reason: .unsupportedInstruction, opcode: bytes[instructionStart])
                }
                let emittedBytes = emittedWordCount * MemoryLayout<UInt32>.size
                guard emittedBytes <= outputBudget - output.count else {
                    return result(output, consumed: instructionStart, instructions: instructions,
                                  reason: .outputLimit, fallbackOffset: instructionStart)
                }
                if isImmediateMove {
                    Self.emitMoveImmediate(immediate, to: destinationRegister,
                                            is64Bit: is64BitMove, into: &output)
                } else if opcode == 0x89 || opcode == 0x8B {
                    Self.emit(registerMoveWord, into: &output)
                } else {
                    Self.emit(0xD503201F, into: &output)
                }
                instructions += 1
            }
            if availableBytes < bytes.count {
                return result(output, consumed: cursor, instructions: instructions,
                              reason: .inputLimit, fallbackOffset: cursor)
            }
            return result(output, consumed: cursor, instructions: instructions, reason: .endOfInput)
        }
    }

    private func fallback(_ code: [UInt8], consumed: Int, instructions: Int,
                          reason: X86_64AOTTranslation.StopReason, opcode: UInt8) -> X86_64AOTTranslation {
        result(code, consumed: consumed, instructions: instructions, reason: reason,
               fallbackOffset: consumed, fallbackOpcode: opcode)
    }

    private func result(_ code: [UInt8], consumed: Int, instructions: Int,
                        reason: X86_64AOTTranslation.StopReason,
                        fallbackOffset: Int? = nil, fallbackOpcode: UInt8? = nil) -> X86_64AOTTranslation {
        X86_64AOTTranslation(machineCode: Data(code), guestBytesConsumed: consumed,
                             instructionCount: instructions, stopReason: reason,
                             fallbackOffset: fallbackOffset, fallbackOpcode: fallbackOpcode)
    }

    private static func moveImmediateWordCount(_ value: UInt64, is64Bit: Bool) -> Int {
        let halfCount = is64Bit ? 4 : 2
        var count = 0
        for half in 0..<halfCount where UInt16(truncatingIfNeeded: value >> (half * 16)) != 0 {
            count += 1
        }
        return max(1, count)
    }

    private static func emitMoveImmediate(_ value: UInt64, to register: Int,
                                          is64Bit: Bool, into output: inout [UInt8]) {
        let halfCount = is64Bit ? 4 : 2
        var firstNonZero: Int?
        for half in 0..<halfCount where UInt16(truncatingIfNeeded: value >> (half * 16)) != 0 {
            if firstNonZero == nil { firstNonZero = half }
        }
        let first = firstNonZero ?? 0
        let firstValue = UInt16(truncatingIfNeeded: value >> (first * 16))
        emit(moveWide(firstValue, register: register, half: first, is64Bit: is64Bit, keep: false), into: &output)
        for half in 0..<halfCount where half != first {
            let chunk = UInt16(truncatingIfNeeded: value >> (half * 16))
            if chunk != 0 {
                emit(moveWide(chunk, register: register, half: half, is64Bit: is64Bit, keep: true), into: &output)
            }
        }
    }

    private static func emit(_ word: UInt32, into output: inout [UInt8]) {
        output.append(UInt8(truncatingIfNeeded: word))
        output.append(UInt8(truncatingIfNeeded: word >> 8))
        output.append(UInt8(truncatingIfNeeded: word >> 16))
        output.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    private static func moveWide(_ immediate: UInt16, register: Int, half: Int,
                                 is64Bit: Bool, keep: Bool) -> UInt32 {
        let base: UInt32 = is64Bit
            ? (keep ? 0xF2800000 : 0xD2800000)
            : (keep ? 0x72800000 : 0x52800000)
        return base | (UInt32(half) << 21) | (UInt32(immediate) << 5) | UInt32(register)
    }

    private static func moveRegister(_ source: Int, to destination: Int, is64Bit: Bool) -> UInt32 {
        let base: UInt32 = is64Bit ? 0xAA0003E0 : 0x2A0003E0
        return base | (UInt32(source) << 16) | UInt32(destination)
    }
}

#if canImport(CryptoKit)
/// Stores validated AArch64 artifacts; executable mapping and dispatch are
/// intentionally left to a separately verified platform runtime adapter.
final class KenranButoAOTCompiler {
    struct Compilation {
        let translation: X86_64AOTTranslation
        let cacheHit: Bool
    }

    private let translator: X86_64AOTTranslator
    private let cache: TranslationCache

    init(cache: TranslationCache = .shared, translator: X86_64AOTTranslator = X86_64AOTTranslator()) {
        self.cache = cache
        self.translator = translator
    }

    func compile(_ guestCode: Data, guestABI: String) throws -> Compilation {
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: Self.sha256(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: guestABI
        )
        if let cached = try cache.load(identity) {
            if let translation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               translation.isCacheable, translation.isValid(for: guestCode) {
                return Compilation(translation: translation, cacheHit: true)
            }
            try cache.invalidate(identity)
        }
        let translation = translator.translate(guestCode)
        if translation.isCacheable {
            try cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
