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

        // MOV r8, imm8 preserves the other 56 guest-register bits.
        let movALImmediate = translator.translate(Data([0xB0, 0x7F]))
        precondition(movALImmediate.isComplete && movALImmediate.guestBytesConsumed == 2
                     && movALImmediate.instructionCount == 1)
        precondition(word(movALImmediate.machineCode, 0) == 0xD2800FF0)
        precondition(word(movALImmediate.machineCode, 1) == 0xB3401E00)

        // Without REX, B4-B7 address AH/CH/DH/BH rather than SPL/BPL/SIL/DIL.
        let movAHImmediate = translator.translate(Data([0xB4, 0x80]))
        precondition(movAHImmediate.isComplete && movAHImmediate.guestBytesConsumed == 2)
        precondition(word(movAHImmediate.machineCode, 0) == 0xD2801010)
        precondition(word(movAHImmediate.machineCode, 1) == 0xB3781E00)
        let movBHImmediate = translator.translate(Data([0xB7, 0xFF]))
        precondition(movBHImmediate.isComplete && movBHImmediate.guestBytesConsumed == 2)
        precondition(word(movBHImmediate.machineCode, 0) == 0xD2801FF0)
        precondition(word(movBHImmediate.machineCode, 1) == 0xB3781E03)

        // Any REX prefix disables high-byte registers; REX.B extends the low-byte register.
        let movSPLImmediate = translator.translate(Data([0x40, 0xB4, 0x42]))
        precondition(movSPLImmediate.isComplete && movSPLImmediate.guestBytesConsumed == 3)
        precondition(word(movSPLImmediate.machineCode, 0) == 0xD2800850)
        precondition(word(movSPLImmediate.machineCode, 1) == 0xB3401E04)
        let movR12BImmediate = translator.translate(Data([0x41, 0xB4, 0x42]))
        precondition(movR12BImmediate.isComplete && movR12BImmediate.guestBytesConsumed == 3)
        precondition(word(movR12BImmediate.machineCode, 1) == 0xB3401E0C)
        let movR15BImmediate = translator.translate(Data([0x41, 0xB7, 0xAB]))
        precondition(movR15BImmediate.isComplete && movR15BImmediate.guestBytesConsumed == 3)
        precondition(word(movR15BImmediate.machineCode, 0) == 0xD2801570)
        precondition(word(movR15BImmediate.machineCode, 1) == 0xB3401E0F)
        let movREXRImmediate = translator.translate(Data([0x44, 0xB4, 0x42]))
        precondition(movREXRImmediate.isComplete && movREXRImmediate.guestBytesConsumed == 3)
        precondition(word(movREXRImmediate.machineCode, 1) == 0xB3401E04)

        let movByteTruncated = translator.translate(Data([0xB0]))
        precondition(movByteTruncated.stopReason == .truncatedInstruction)
        precondition(movByteTruncated.guestBytesConsumed == 0)
        let movByteInputLimited = translator.translate(Data([0xB0, 0x7F]), maximumGuestBytes: 1)
        precondition(movByteInputLimited.stopReason == .inputLimit)
        precondition(movByteInputLimited.guestBytesConsumed == 0)
        let movByteOutputLimited = translator.translate(Data([0xB0, 0x7F]), maximumOutputBytes: 4)
        precondition(movByteOutputLimited.stopReason == .outputLimit)
        precondition(movByteOutputLimited.guestBytesConsumed == 0)
        let movByteThenUnsupported = translator.translate(Data([0xB0, 0x7F, 0x0F, 0x0B]))
        precondition(movByteThenUnsupported.stopReason == .unsupportedInstruction)
        precondition(movByteThenUnsupported.guestBytesConsumed == 2)
        precondition(movByteThenUnsupported.instructionCount == 1)
        precondition(movByteThenUnsupported.fallbackOpcode == 0x0F)

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

        // CWDE/CDQE and CDQ/CQO preserve x86 flags and use the fixed accumulator registers.
        let cwde = translator.translate(Data([0x98]))
        precondition(cwde.isComplete && cwde.instructionCount == 1)
        precondition(word(cwde.machineCode, 0) == 0x13003C00) // SXTH W0, W0
        let cdqe = translator.translate(Data([0x48, 0x98]))
        precondition(cdqe.isComplete && cdqe.instructionCount == 1)
        precondition(word(cdqe.machineCode, 0) == 0x93407C00) // SXTW X0, W0
        let cdq = translator.translate(Data([0x99]))
        precondition(cdq.isComplete && cdq.instructionCount == 1)
        precondition(word(cdq.machineCode, 0) == 0x131F7C02) // ASR W2, W0, #31
        let cqo = translator.translate(Data([0x48, 0x99]))
        precondition(cqo.isComplete && cqo.instructionCount == 1)
        precondition(word(cqo.machineCode, 0) == 0x937FFC02) // ASR X2, X0, #63
        let signExtensionBlock = translator.translate(Data([0xB8, 0x00, 0x80, 0x00, 0x00, 0x98, 0x99]))
        precondition(signExtensionBlock.isComplete && signExtensionBlock.instructionCount == 3)
        // 16-bit CBW/CWD are deliberately left to the interpreter, not miscompiled as 32-bit forms.
        let cbwSideExit = translator.translate(Data([0x66, 0x98]))
        precondition(cbwSideExit.stopReason == .unsupportedInstruction)
        precondition(cbwSideExit.guestBytesConsumed == 0 && cbwSideExit.fallbackOpcode == 0x66)
        let cwdSideExit = translator.translate(Data([0x66, 0x99]))
        precondition(cwdSideExit.stopReason == .unsupportedInstruction)
        precondition(cwdSideExit.guestBytesConsumed == 0 && cwdSideExit.fallbackOpcode == 0x66)

        // Register-only accumulator XCHG forms preserve 32/64-bit semantics.
        let exchanges = translator.translate(Data([0x91, 0x49, 0x90]))
        precondition(exchanges.isComplete && exchanges.instructionCount == 2)
        precondition(word(exchanges.machineCode, 0) == 0x4A010000)
        precondition(word(exchanges.machineCode, 1) == 0x4A010001)
        precondition(word(exchanges.machineCode, 2) == 0x4A010000)
        precondition(word(exchanges.machineCode, 3) == 0xCA080000)
        precondition(word(exchanges.machineCode, 4) == 0xCA080008)
        precondition(word(exchanges.machineCode, 5) == 0xCA080000)

        let exchange32High = translator.translate(Data([0x41, 0x90]))
        precondition(exchange32High.isComplete && exchange32High.instructionCount == 1)
        precondition(word(exchange32High.machineCode, 0) == 0x4A080000)
        precondition(word(exchange32High.machineCode, 1) == 0x4A080008)
        precondition(word(exchange32High.machineCode, 2) == 0x4A080000)
        // REX.X is ignored for register-only ModRM forms; REX.B still selects R8D.
        let exchange32HighWithIgnoredIndex = translator.translate(Data([0x43, 0x87, 0xC0]))
        precondition(exchange32HighWithIgnoredIndex.isComplete && exchange32HighWithIgnoredIndex.instructionCount == 1)
        precondition(exchange32HighWithIgnoredIndex.guestBytesConsumed == 3)
        precondition(exchange32HighWithIgnoredIndex.machineCode.count == 12)
        precondition(word(exchange32HighWithIgnoredIndex.machineCode, 0) == 0x4A000108)
        precondition(word(exchange32HighWithIgnoredIndex.machineCode, 1) == 0x4A000100)
        precondition(word(exchange32HighWithIgnoredIndex.machineCode, 2) == 0x4A000108)

        let extendedAccumulatorExchange = translator.translate(Data([0x4D, 0x97]))
        precondition(extendedAccumulatorExchange.isComplete && extendedAccumulatorExchange.instructionCount == 1)
        precondition(word(extendedAccumulatorExchange.machineCode, 0) == 0xCA0F0000)
        precondition(word(extendedAccumulatorExchange.machineCode, 1) == 0xCA0F000F)
        precondition(word(extendedAccumulatorExchange.machineCode, 2) == 0xCA0F0000)

        let nop = translator.translate(Data([0x90]))
        precondition(nop.isComplete && nop.instructionCount == 1)
        precondition(word(nop.machineCode, 0) == 0xD503201F)

        let xchg64 = translator.translate(Data([0x48, 0x87, 0xD8]))
        precondition(xchg64.isComplete && xchg64.guestBytesConsumed == 3 && xchg64.instructionCount == 1)
        precondition(word(xchg64.machineCode, 0) == 0xCA030000)
        precondition(word(xchg64.machineCode, 1) == 0xCA030003)
        precondition(word(xchg64.machineCode, 2) == 0xCA030000)

        let xchg32 = translator.translate(Data([0x87, 0xD8]))
        precondition(xchg32.isComplete && xchg32.instructionCount == 1)
        precondition(word(xchg32.machineCode, 0) == 0x4A030000)
        precondition(word(xchg32.machineCode, 1) == 0x4A030003)
        precondition(word(xchg32.machineCode, 2) == 0x4A030000)

        let xchgExtended = translator.translate(Data([0x4D, 0x87, 0xC8]))
        precondition(xchgExtended.isComplete && xchgExtended.instructionCount == 1)
        precondition(word(xchgExtended.machineCode, 0) == 0xCA090108)
        precondition(word(xchgExtended.machineCode, 1) == 0xCA090109)
        precondition(word(xchgExtended.machineCode, 2) == 0xCA090108)

        let xchgSameRegister = translator.translate(Data([0x87, 0xC0]))
        precondition(xchgSameRegister.isComplete && xchgSameRegister.instructionCount == 1)
        precondition(word(xchgSameRegister.machineCode, 0) == 0x2A0003E0)

        // Register-only MOVZX/MOVSX byte and word sources to 32/64-bit destinations.
        let movzxByte = translator.translate(Data([0x0F, 0xB6, 0xC3]))
        precondition(movzxByte.isComplete && movzxByte.instructionCount == 1)
        precondition(word(movzxByte.machineCode, 0) == 0x53001C60)
        let movzxWord = translator.translate(Data([0x0F, 0xB7, 0xC3]))
        precondition(movzxWord.isComplete && word(movzxWord.machineCode, 0) == 0x53003C60)
        let movzxByte64 = translator.translate(Data([0x48, 0x0F, 0xB6, 0xC3]))
        precondition(movzxByte64.isComplete && word(movzxByte64.machineCode, 0) == 0xD3401C60)
        let movzxWord64 = translator.translate(Data([0x48, 0x0F, 0xB7, 0xC3]))
        precondition(movzxWord64.isComplete && word(movzxWord64.machineCode, 0) == 0xD3403C60)
        let movsxByte = translator.translate(Data([0x0F, 0xBE, 0xC3]))
        precondition(movsxByte.isComplete && word(movsxByte.machineCode, 0) == 0x13001C60)
        let movsxWord = translator.translate(Data([0x0F, 0xBF, 0xC3]))
        precondition(movsxWord.isComplete && word(movsxWord.machineCode, 0) == 0x13003C60)
        let movsxByte64 = translator.translate(Data([0x48, 0x0F, 0xBE, 0xC3]))
        precondition(movsxByte64.isComplete && word(movsxByte64.machineCode, 0) == 0x93401C60)
        let movsxWord64 = translator.translate(Data([0x48, 0x0F, 0xBF, 0xC3]))
        precondition(movsxWord64.isComplete && word(movsxWord64.machineCode, 0) == 0x93403C60)

        // Without REX, rm=4 is AH. Any REX prefix selects SPL instead.
        let movzxHighByte = translator.translate(Data([0x0F, 0xB6, 0xC4]))
        precondition(movzxHighByte.isComplete && word(movzxHighByte.machineCode, 0) == 0x53083C00)
        let movsxHighByte = translator.translate(Data([0x0F, 0xBE, 0xC4]))
        precondition(movsxHighByte.isComplete && word(movsxHighByte.machineCode, 0) == 0x13083C00)
        let movzxREXByte = translator.translate(Data([0x40, 0x0F, 0xB6, 0xC4]))
        precondition(movzxREXByte.isComplete && word(movzxREXByte.machineCode, 0) == 0x53001C80)
        let movzxREXExtended = translator.translate(Data([0x4D, 0x0F, 0xB6, 0xC8]))
        precondition(movzxREXExtended.isComplete && word(movzxREXExtended.machineCode, 0) == 0xD3401D09)

        // MOVSXD r64,r/m32 uses a 64-bit SBFM and honours REX.R/REX.B.
        let movsxd64 = translator.translate(Data([0x48, 0x63, 0xC3]))
        precondition(movsxd64.isComplete && word(movsxd64.machineCode, 0) == 0x93407C60)
        let movsxdExtended = translator.translate(Data([0x4D, 0x63, 0xC8]))
        precondition(movsxdExtended.isComplete && word(movsxdExtended.machineCode, 0) == 0x93407D09)
        let movsxdMemory = translator.translate(Data([0x48, 0x63, 0x00]))
        precondition(movsxdMemory.stopReason == .unsupportedInstruction && movsxdMemory.guestBytesConsumed == 0)
        let movsxdWithoutREXW = translator.translate(Data([0x63, 0xC3]))
        precondition(movsxdWithoutREXW.stopReason == .unsupportedInstruction && movsxdWithoutREXW.guestBytesConsumed == 0)

        // MOVZX/SX can follow an eligible block-start MOV in one translated block.
        let movThenExtend = translator.translate(Data([0xB8, 1, 0, 0, 0, 0x0F, 0xB6, 0xC0, 0x0F, 0x0B]))
        precondition(movThenExtend.stopReason == .unsupportedInstruction)
        precondition(movThenExtend.guestBytesConsumed == 8 && movThenExtend.instructionCount == 2)
        precondition(word(movThenExtend.machineCode, 1) == 0x53001C00)

        let movzxMemory = translator.translate(Data([0x0F, 0xB6, 0x00]))
        precondition(movzxMemory.stopReason == .unsupportedInstruction && movzxMemory.guestBytesConsumed == 0)
        let movzxTruncated = translator.translate(Data([0x0F, 0xB6]))
        precondition(movzxTruncated.stopReason == .truncatedInstruction && movzxTruncated.guestBytesConsumed == 0)
        let movzxUnknown = translator.translate(Data([0x0F, 0x0B]))
        precondition(movzxUnknown.stopReason == .unsupportedInstruction && movzxUnknown.guestBytesConsumed == 0)

        let xchgMemory = translator.translate(Data([0x48, 0x87, 0x08]))
        precondition(xchgMemory.stopReason == .unsupportedInstruction)
        precondition(xchgMemory.guestBytesConsumed == 0 && xchgMemory.fallbackOpcode == 0x48)

        let xchgTruncated = translator.translate(Data([0x48, 0x87]))
        precondition(xchgTruncated.stopReason == .truncatedInstruction)
        precondition(xchgTruncated.guestBytesConsumed == 0 && xchgTruncated.fallbackOpcode == 0x48)

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
        precondition(X86_64AOTTranslator.translatorVersion == "11")
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
