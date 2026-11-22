import Foundation

@main
struct KenranButoAOTTests {
    static func word(_ data: Data, _ index: Int) -> UInt32 {
        let offset = index * 4
        precondition(offset >= 0 && data.count - offset >= 4)
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    static func testTranslator() {
        let translator = X86_64AOTTranslator()
        let guest = Data([0xB8, 0x01, 0, 0, 0, 0x49, 0xB9,
                          0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x90])
        let translated = translator.translate(guest)
        precondition(translated.isComplete && translated.isCacheable)
        precondition(translated.guestBytesConsumed == guest.count && translated.instructionCount == 3)
        precondition(word(translated.machineCode, 0) == 0x52800020)
        precondition(word(translated.machineCode, 1) == 0xD28EF109)
        precondition(word(translated.machineCode, 2) == 0xF2AAACC9)
        precondition(word(translated.machineCode, 3) == 0xF2C66889)
        precondition(word(translated.machineCode, 4) == 0xF2E22449)
        precondition(word(translated.machineCode, 5) == 0xD503201F)
        precondition(translated.isValid(for: guest))

        let registerMoves = translator.translate(Data([0x89, 0xD8, 0x48, 0x89, 0xC3]))
        precondition(registerMoves.isComplete && registerMoves.instructionCount == 2)
        precondition(word(registerMoves.machineCode, 0) == 0x2A0303E0)
        precondition(word(registerMoves.machineCode, 1) == 0xAA0003E3)

        let endbr = translator.translate(Data([0xF3, 0x0F, 0x1E, 0xFA]))
        precondition(endbr.isComplete && word(endbr.machineCode, 0) == 0xD503201F)
        let malformedEndbr = translator.translate(Data([0xF3, 0x0F, 0x1E, 0xFB]))
        precondition(malformedEndbr.stopReason == .unsupportedInstruction && malformedEndbr.guestBytesConsumed == 0)

        let unsupportedGuest = Data([0xB8, 1, 0, 0, 0, 0x01, 0xD8])
        let fallback = translator.translate(unsupportedGuest)
        precondition(fallback.stopReason == .unsupportedInstruction && fallback.guestBytesConsumed == 5)
        precondition(fallback.fallbackOffset == 5 && fallback.fallbackOpcode == 0x01)
        precondition(fallback.isCacheable && fallback.isValid(for: unsupportedGuest))

        let truncatedCode = Data([0xB8, 1, 2])
        let truncated = translator.translate(truncatedCode)
        precondition(truncated.stopReason == .truncatedInstruction && truncated.guestBytesConsumed == 0)
        precondition(truncated.machineCode.isEmpty && truncated.isValid(for: truncatedCode))

        let limitedCode = Data([0x90, 0x90])
        let instructionLimited = translator.translate(limitedCode, maximumInstructions: 1)
        precondition(instructionLimited.stopReason == .instructionLimit && instructionLimited.guestBytesConsumed == 1)
        precondition(instructionLimited.isValid(for: limitedCode))

        let outputLimitedCode = Data([0x48, 0xB8, 0xEF, 0xCD, 0xAB, 0x90, 0x78, 0x56, 0x34, 0x12])
        let outputLimited = translator.translate(outputLimitedCode, maximumOutputBytes: 4)
        precondition(outputLimited.stopReason == .outputLimit && outputLimited.guestBytesConsumed == 0)
        precondition(outputLimited.isValid(for: outputLimitedCode))

        for code in [Data([0x41, 0x90]), Data([0x49, 0x90])] {
            let rexExchange = translator.translate(code)
            precondition(rexExchange.stopReason == .unsupportedInstruction)
            precondition(rexExchange.guestBytesConsumed == 0 && rexExchange.fallbackOpcode == code[0])
            precondition(rexExchange.machineCode.isEmpty && rexExchange.isValid(for: code))
        }

        let overlongCode = Data(Array(repeating: 0x48, count: 14) + [0xB8] + Array(repeating: 0x00, count: 8))
        let overlong = translator.translate(overlongCode)
        precondition(overlong.stopReason == .unsupportedInstruction && overlong.guestBytesConsumed == 0)

        let inputCode = Data([0x90, 0x90])
        let inputLimited = translator.translate(inputCode, maximumInputBytes: 1)
        precondition(inputLimited.stopReason == .inputLimit && inputLimited.guestBytesConsumed == 1)
        precondition(inputLimited.isValid(for: inputCode))

        let partialInputCode = Data([0x48, 0xB8, 1, 2, 3, 4, 5, 6, 7, 8])
        let partialInput = translator.translate(partialInputCode, maximumInputBytes: 5)
        precondition(partialInput.stopReason == .inputLimit && partialInput.guestBytesConsumed == 0)
        precondition(partialInput.fallbackOpcode == nil && partialInput.isValid(for: partialInputCode))

        let bounded = translator.translate(Data([0x90, 0x90]), maximumInstructions: Int.max,
                                           maximumOutputBytes: Int.max, maximumInputBytes: Int.max)
        precondition(bounded.isComplete && bounded.instructionCount == 2)
    }

    #if canImport(CryptoKit)
    static func testCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenran-buto-aot-cache-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TranslationCache(directory: directory)
        let compiler = KenranButoAOTCompiler(cache: cache)
        let guest = Data([0xB8, 0x2A, 0, 0, 0, 0x90])
        let first = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!first.cacheHit && first.translation.isComplete)
        precondition(first.translation.instructionCount == 2 && first.translation.isValid(for: guest))

        let second = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(second.cacheHit && second.translation == first.translation)

        let otherABI = try compiler.compile(guest, guestABI: "custom-x86_64")
        precondition(!otherABI.cacheHit)
        let statisticsAfterABI = try cache.statistics()
        precondition(statisticsAfterABI.entryCount == 2)

        let unsupported = try compiler.compile(Data([0x01, 0xD8]), guestABI: "sysv-linux-x86_64")
        precondition(!unsupported.translation.isCacheable)
        let statisticsAfterFallback = try cache.statistics()
        precondition(statisticsAfterFallback.entryCount == 2)
    }
    #endif

    static func main() throws {
        testTranslator()
        #if canImport(CryptoKit)
        try testCache()
        #endif
        print("Kenran Butō AOT translation, fallback, bounds and cache checks passed")
    }
}
