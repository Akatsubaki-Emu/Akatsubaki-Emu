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

        // A structurally valid but forged cached artifact must never become
        // executable native code. The compiler re-decodes the guest bytes and
        // rejects any cache payload that differs from the trusted translator.
        let guestDigest = SHA256.hash(data: guest).map { String(format: "%02x", $0) }.joined()
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: guestDigest,
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: "sysv-linux-x86_64"
        )
        let forged = X86_64AOTTranslation(
            machineCode: Data([0xC0, 0x03, 0x5F, 0xD6]), // RET, not the guest translation
            guestBytesConsumed: guest.count,
            instructionCount: 2,
            stopReason: .endOfInput,
            fallbackOffset: nil,
            fallbackOpcode: nil
        )
        precondition(forged.isValid(for: guest))
        try cache.store(try JSONEncoder().encode(forged), for: identity)
        let repaired = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!repaired.cacheHit)
        precondition(repaired.translation != forged)
        precondition(repaired.translation == first.translation)

        // A block with no supported instructions is not stored as an empty artifact.
        let unsupported = try compiler.compile(Data([0x01, 0xD8]), guestABI: "sysv-linux-x86_64")
        precondition(!unsupported.translation.isCacheable)
        let statisticsAfterFallback = try cache.statistics()
        precondition(statisticsAfterFallback.entryCount == 2)

        print("Kenran Butō AOT artifact cache round-trip, ABI isolation and fallback passed")
    }
}
