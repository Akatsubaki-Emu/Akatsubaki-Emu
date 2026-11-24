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

        // C7 /0 register-only immediates preserve x86 MOV width semantics.
        let movImmediate32 = translator.translate(Data([0xC7, 0xC0, 0x78, 0x56, 0x34, 0x12]))
        precondition(movImmediate32.isComplete && movImmediate32.guestBytesConsumed == 6)
        precondition(movImmediate32.instructionCount == 1)
        precondition(word(movImmediate32.machineCode, 0) == 0x528ACF00) // MOVZ W0, #0x5678
        precondition(word(movImmediate32.machineCode, 1) == 0x72A24680) // MOVK W0, #0x1234, LSL #16

        let movImmediate64 = translator.translate(Data([0x48, 0xC7, 0xC0, 0x00, 0x00, 0x00, 0x80]))
        precondition(movImmediate64.isComplete && movImmediate64.instructionCount == 1)
        precondition(word(movImmediate64.machineCode, 0) == 0xD2B00000) // MOVZ X0, #0x8000, LSL #16
        precondition(word(movImmediate64.machineCode, 1) == 0xF2DFFFE0) // MOVK X0, #0xFFFF, LSL #32
        precondition(word(movImmediate64.machineCode, 2) == 0xF2FFFFE0) // MOVK X0, #0xFFFF, LSL #48

        let movImmediateExtended = translator.translate(Data([0x41, 0xC7, 0xC0, 0x78, 0x56, 0x34, 0x12]))
        precondition(movImmediateExtended.isComplete && movImmediateExtended.instructionCount == 1)
        precondition(word(movImmediateExtended.machineCode, 0) == 0x528ACF08) // MOVZ W8, #0x5678
        precondition(word(movImmediateExtended.machineCode, 1) == 0x72A24688) // MOVK W8, #0x1234, LSL #16

        let movImmediateTruncated = translator.translate(Data([0xC7, 0xC0, 0x01, 0x02]))
        precondition(movImmediateTruncated.stopReason == .truncatedInstruction)
        precondition(movImmediateTruncated.guestBytesConsumed == 0)

        let movImmediateInputLimited = translator.translate(
            Data([0xC7, 0xC0, 0x01, 0x02, 0x03, 0x04]), maximumGuestBytes: 3
        )
        precondition(movImmediateInputLimited.stopReason == .inputLimit)
        precondition(movImmediateInputLimited.guestBytesConsumed == 0)

        let movImmediateMemory = translator.translate(Data([0xC7, 0x00, 0x01, 0x02, 0x03, 0x04]))
        precondition(movImmediateMemory.stopReason == .unsupportedInstruction)
        precondition(movImmediateMemory.guestBytesConsumed == 0)

        let movImmediateOtherExtension = translator.translate(Data([0xC7, 0xC8, 0x01, 0x02, 0x03, 0x04]))
        precondition(movImmediateOtherExtension.stopReason == .unsupportedInstruction)
        precondition(movImmediateOtherExtension.guestBytesConsumed == 0)

        // LEA r64, [base + index*4 + disp8] emits flag-preserving AArch64 ADDs.
        let lea64Code = Data([0x48, 0x8D, 0x54, 0x88, 0x10])
        let lea64 = translator.translate(lea64Code)
        precondition(lea64.isComplete && lea64.guestBytesConsumed == 5 && lea64.instructionCount == 1)
        precondition(word(lea64.machineCode, 0) == 0x8B010802) // ADD X2, X0, X1, LSL #2
        precondition(word(lea64.machineCode, 1) == 0x91004042) // ADD X2, X2, #16

        let leaNegative = translator.translate(Data([0x48, 0x8D, 0x50, 0xF0]))
        precondition(leaNegative.isComplete && leaNegative.instructionCount == 1)
        precondition(word(leaNegative.machineCode, 0) == 0xD1004002) // SUB X2, X0, #16

        let lea32 = translator.translate(Data([0x8D, 0x54, 0x48, 0x10]))
        precondition(lea32.isComplete && lea32.instructionCount == 1)
        precondition(word(lea32.machineCode, 0) == 0x0B010402) // ADD W2, W0, W1, LSL #1
        precondition(word(lea32.machineCode, 1) == 0x11004042) // ADD W2, W2, #16

        let leaExtended = translator.translate(Data([0x4F, 0x8D, 0x54, 0x88, 0x10]))
        precondition(leaExtended.isComplete && leaExtended.instructionCount == 1)
        precondition(word(leaExtended.machineCode, 0) == 0x8B09090A) // ADD X10, X8, X9, LSL #2
        precondition(word(leaExtended.machineCode, 1) == 0x9100414A) // ADD X10, X10, #16

        let leaIndexOnly = translator.translate(Data([0x48, 0x8D, 0x14, 0x8D, 0x10, 0, 0, 0]))
        precondition(leaIndexOnly.isComplete && leaIndexOnly.instructionCount == 1)
        precondition(word(leaIndexOnly.machineCode, 0) == 0x8B010BE2) // ADD X2, XZR, X1, LSL #2
        precondition(word(leaIndexOnly.machineCode, 1) == 0x91004042)

        let leaAbsolute = translator.translate(Data([0x48, 0x8D, 0x14, 0x25, 0x00, 0x10, 0x00, 0x00]))
        precondition(leaAbsolute.isComplete && leaAbsolute.instructionCount == 1)
        precondition(word(leaAbsolute.machineCode, 0) == 0xD2820002) // MOVZ X2, #0x1000

        let leaRipRelativeBytes = Data([0x48, 0x8D, 0x35, 0xEF, 0x00, 0x00, 0x00])
        let leaRipRelative = translator.translate(leaRipRelativeBytes, guestRIP: 0x40020A)
        precondition(leaRipRelative.isComplete && leaRipRelative.instructionCount == 1)
        precondition(leaRipRelative.guestBytesConsumed == 7)
        precondition(word(leaRipRelative.machineCode, 0) == 0xD2806006)
        precondition(word(leaRipRelative.machineCode, 1) == 0xF2A00806)
        let leaRipAtAnotherAddress = translator.translate(leaRipRelativeBytes, guestRIP: 0x50020A)
        precondition(leaRipAtAnotherAddress.machineCode != leaRipRelative.machineCode)
        let leaRipWithoutAddress = translator.translate(leaRipRelativeBytes)
        precondition(leaRipWithoutAddress.stopReason == .unsupportedInstruction)
        precondition(leaRipWithoutAddress.guestBytesConsumed == 0)

        let leaLargeDisplacement = translator.translate(Data([0x48, 0x8D, 0x94, 0x88, 0x00, 0x10, 0, 0]))
        precondition(leaLargeDisplacement.stopReason == .unsupportedInstruction)
        precondition(leaLargeDisplacement.guestBytesConsumed == 0 && leaLargeDisplacement.fallbackOpcode == 0x48)

        let leaRegisterMode = translator.translate(Data([0x48, 0x8D, 0xD0]))
        precondition(leaRegisterMode.stopReason == .unsupportedInstruction)
        precondition(leaRegisterMode.guestBytesConsumed == 0 && leaRegisterMode.fallbackOpcode == 0x48)

        let leaTruncated = translator.translate(Data([0x48, 0x8D, 0x14, 0x25, 0x01]))
        precondition(leaTruncated.stopReason == .truncatedInstruction)
        precondition(leaTruncated.guestBytesConsumed == 0 && leaTruncated.fallbackOpcode == 0x48)

        let leaOutputLimited = translator.translate(lea64Code, maximumOutputBytes: 4)
        precondition(leaOutputLimited.stopReason == .outputLimit)
        precondition(leaOutputLimited.guestBytesConsumed == 0 && leaOutputLimited.machineCode.isEmpty)

        // Both REX.B variants of 90 are XCHG, not NOP.
        for rex in [UInt8(0x41), UInt8(0x49)] {
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

        // Multiple x86 instructions may form one block even though no single
        // instruction may exceed the architectural 15-byte limit.
        let multiInstructionBlock = translator.translate(Data([
            0xB8,1,0,0,0, 0xBB,2,0,0,0, 0xB9,3,0,0,0, 0xBA,4,0,0,0, 0x0F,0x0B
        ]))
        precondition(multiInstructionBlock.stopReason == .unsupportedInstruction)
        precondition(multiInstructionBlock.guestBytesConsumed == 20)
        precondition(multiInstructionBlock.instructionCount == 4)
        precondition(multiInstructionBlock.fallbackOpcode == 0x0F)
        precondition(X86_64AOTTranslator.translatorVersion == "6")
        let oversizedBudgets = translator.translate(
            guest, maximumInstructions: Int.max,
            maximumOutputBytes: Int.max & ~3,
            maximumGuestBytes: Int.max
        )
        precondition(oversizedBudgets.isComplete)
        precondition(oversizedBudgets.instructionCount == 3)

        print("Kenran Butō AOT decoder, AArch64 emission, 15-byte bounds and interpreter fallback passed")
    }
}
