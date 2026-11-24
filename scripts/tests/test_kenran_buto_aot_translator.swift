import Foundation

@main
struct KenranButoAOTTranslatorTests {
    static func word(_ data: Data, _ index: Int) -> UInt32 {
        let offset = index * 4
        precondition(offset >= 0 && data.count - offset >= 4)
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    static func main() {
        let translator = X86_64AOTTranslator()

        // MOV EAX, 1; MOV R9, 0x1122334455667788; NOP
        let guest = Data([
            0xB8, 0x01, 0x00, 0x00, 0x00,
            0x49, 0xB9, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
            0x90
        ])
        let translated = translator.translate(guest)
        precondition(translated.isComplete)
        precondition(translated.isCacheable)
        precondition(translated.guestBytesConsumed == guest.count)
        precondition(translated.instructionCount == 3)
        precondition(word(translated.machineCode, 0) == 0x52800020) // MOVZ W0, #1
        precondition(word(translated.machineCode, 1) == 0xD28EF109) // MOVZ X9, #0x7788
        precondition(word(translated.machineCode, 2) == 0xF2AAACC9) // MOVK X9, #0x5566, LSL #16
        precondition(word(translated.machineCode, 3) == 0xF2C66889) // MOVK X9, #0x3344, LSL #32
        precondition(word(translated.machineCode, 4) == 0xF2E22449) // MOVK X9, #0x1122, LSL #48
        precondition(word(translated.machineCode, 5) == 0xD503201F) // NOP

        // MOV EAX, EBX and MOV RBX, RAX use register-only encodings.
        let registerMoves = translator.translate(Data([0x89, 0xD8, 0x48, 0x89, 0xC3]))
        precondition(registerMoves.isComplete)
        precondition(registerMoves.instructionCount == 2)
        precondition(word(registerMoves.machineCode, 0) == 0x2A0303E0) // ORR W0, WZR, W3
        precondition(word(registerMoves.machineCode, 1) == 0xAA0003E3) // ORR X3, XZR, X0

        // Every tested REX prefix with B=1 makes 90 an XCHG, not NOP.
        // 0x43 also sets REX.X; the translator must still honor REX.B.
        for rex in [UInt8(0x41), UInt8(0x43), UInt8(0x49)] {
            let exchange = translator.translate(Data([rex, 0x90]))
            precondition(exchange.stopReason == .unsupportedInstruction)
            precondition(exchange.guestBytesConsumed == 0)
            precondition(exchange.fallbackOpcode == rex)
            precondition(exchange.machineCode.isEmpty)
        }

        // The complete x86 instruction length, including REX prefixes and
        // immediate bytes, must not exceed the architectural 15-byte limit.
        let legal15ByteInstruction = Data(
            [UInt8](repeating: 0x48, count: 6) + [0xB8] + [UInt8](repeating: 0, count: 8)
        )
        let legal15 = translator.translate(legal15ByteInstruction)
        precondition(legal15.isComplete)
        precondition(legal15.guestBytesConsumed == 15)

        let overlong16ByteInstruction = Data(
            [UInt8](repeating: 0x48, count: 7) + [0xB8] + [UInt8](repeating: 0, count: 8)
        )
        let overlong = translator.translate(overlong16ByteInstruction)
        precondition(overlong.stopReason == .unsupportedInstruction)
        precondition(overlong.guestBytesConsumed == 0)
        precondition(overlong.fallbackOpcode == 0x48)
        precondition(overlong.machineCode.isEmpty)

        // Bound guest input before copying/decoding it.
        let inputLimited = translator.translate(Data([0x90, 0x90]), maximumGuestBytes: 1)
        precondition(inputLimited.stopReason == .inputLimit)
        precondition(inputLimited.guestBytesConsumed == 1)
        precondition(inputLimited.isValid(for: Data([0x90, 0x90])))

        // ENDBR64 must fall back until guest CET policy is explicit.
        let endbr = translator.translate(Data([0xF3, 0x0F, 0x1E, 0xFA]))
        precondition(endbr.stopReason == .unsupportedInstruction)
        precondition(endbr.guestBytesConsumed == 0)
        precondition(endbr.fallbackOpcode == 0xF3)
        let malformedEndbr = translator.translate(Data([0xF3, 0x0F, 0x1E, 0xFB]))
        precondition(malformedEndbr.stopReason == .unsupportedInstruction)
        precondition(malformedEndbr.guestBytesConsumed == 0)

        // Arithmetic and memory operands stop before the unsupported instruction.
        let unsupportedGuest = Data([0xB8, 1, 0, 0, 0, 0x01, 0xD8])
        let fallback = translator.translate(unsupportedGuest)
        precondition(fallback.stopReason == .unsupportedInstruction)
        precondition(fallback.guestBytesConsumed == 5)
        precondition(fallback.fallbackOffset == 5)
        precondition(fallback.fallbackOpcode == 0x01)
        precondition(fallback.isCacheable)
        precondition(fallback.isValid(for: unsupportedGuest))

        // A truncated immediate is not consumed or partially emitted.
        let truncated = translator.translate(Data([0xB8, 0x01, 0x02]))
        precondition(truncated.stopReason == .truncatedInstruction)
        precondition(truncated.guestBytesConsumed == 0)
        precondition(truncated.machineCode.isEmpty)

        // Budgets stop at an instruction boundary.
        let instructionLimited = translator.translate(Data([0x90, 0x90]), maximumInstructions: 1)
        precondition(instructionLimited.stopReason == .instructionLimit)
        precondition(instructionLimited.guestBytesConsumed == 1)
        let outputLimited = translator.translate(
            Data([0x48, 0xB8, 0xEF, 0xCD, 0xAB, 0x90, 0x78, 0x56, 0x34, 0x12]),
            maximumOutputBytes: 4
        )
        precondition(outputLimited.stopReason == .outputLimit)
        precondition(outputLimited.guestBytesConsumed == 0)

        print("Kenran Butō AOT decoder, AArch64 emission, 15-byte bounds and interpreter fallback passed")
    }
}
