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

        // A structurally valid cache entry with forged machine words must be
        // re-decoded from guest bytes and rejected before executable use.
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: SHA256.hash(data: guest).map { String(format: "%02x", $0) }.joined(),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: "sysv-linux-x86_64|maxInstructions=4096"
        )
        let forged = X86_64AOTTranslation(
            machineCode: Data(repeating: 0, count: first.translation.machineCode.count),
            guestBytesConsumed: first.translation.guestBytesConsumed,
            instructionCount: first.translation.instructionCount,
            stopReason: first.translation.stopReason,
            fallbackOffset: first.translation.fallbackOffset,
            fallbackOpcode: first.translation.fallbackOpcode
        )
        precondition(forged.isCacheable && forged.isValid(for: guest))
        try cache.store(try JSONEncoder().encode(forged), for: identity)
        let repaired = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!repaired.cacheHit)
        precondition(repaired.translation == first.translation)

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

        print("Kenran Butō AOT artifact cache round-trip, ABI isolation and fallback passed")
    }
}
