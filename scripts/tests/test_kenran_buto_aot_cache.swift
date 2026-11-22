import CryptoKit
import Foundation

@main
struct KenranButoAOTCacheTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenran-buto-aot-cache-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TranslationCache(directory: directory)
        let compiler = KenranButoAOTCompiler(cache: cache)
        let guest = Data([0xB8, 0x2A, 0x00, 0x00, 0x00, 0x90])

        let first = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!first.cacheHit)
        precondition(first.translation.isComplete)
        precondition(first.translation.instructionCount == 2)
        precondition(first.translation.isValid(for: guest))

        let second = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(second.cacheHit)
        precondition(second.translation == first.translation)

        // Guest ABI is part of the cache identity and cannot alias another ABI.
        let otherABI = try compiler.compile(guest, guestABI: "custom-x86_64")
        precondition(!otherABI.cacheHit)
        let statisticsAfterABI = try cache.statistics()
        precondition(statisticsAfterABI.entryCount == 2)

        // A block with no supported instructions is not stored as an empty artifact.
        let unsupported = try compiler.compile(Data([0x01, 0xD8]), guestABI: "sysv-linux-x86_64")
        precondition(!unsupported.translation.isCacheable)
        let statisticsAfterFallback = try cache.statistics()
        precondition(statisticsAfterFallback.entryCount == 2)


        let budgetOne = try compiler.compile(guest, guestABI: "sysv-linux-x86_64", maximumInstructions: 1)
        precondition(!budgetOne.cacheHit && budgetOne.translation.instructionCount == 1)
        precondition(budgetOne.translation.stopReason == .instructionLimit)
        let budgetOneHit = try compiler.compile(guest, guestABI: "sysv-linux-x86_64", maximumInstructions: 1)
        precondition(budgetOneHit.cacheHit)

        let forged = X86_64AOTTranslation(machineCode: Data([0,0,0,0]),
            guestBytesConsumed: guest.count, instructionCount: 2, stopReason: .endOfInput,
            fallbackOffset: nil, fallbackOpcode: nil)
        let forgedIdentity = TranslationCacheIdentity(
            guestCodeSHA256: SHA256.hash(data: guest).map { String(format: "%02x", $0) }.joined(),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: KenranButoAOTCompiler.cacheGuestABI("sysv-linux-x86_64", maximumInstructions: 4096)
        )
        try cache.store(try JSONEncoder().encode(forged), for: forgedIdentity)
        let revalidated = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!revalidated.cacheHit && revalidated.translation == first.translation)
        precondition(try cache.statistics().entryCount == 3)
        print("Kenran Butō AOT cache budget isolation, forged-artifact rejection and fallback passed")
    }
}
