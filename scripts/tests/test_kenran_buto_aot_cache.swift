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


        let sha256ABC: [UInt8] = [
            0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
            0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
            0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
            0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD
        ]
        precondition(SHA256Hex.encode(sha256ABC) ==
                     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let first = try compiler.compile(guest, guestABI: "sysv-linux-x86_64")
        precondition(!first.cacheHit)
        precondition(first.translation.isComplete)
        precondition(first.translation.instructionCount == 2)
        precondition(first.translation.isValid(for: guest))


        let untouchedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kenran-cache-no-create-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: untouchedRoot) }
        let untouched = TranslationCache(directory: untouchedRoot)
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: SHA256Hex.digest(guest),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: KenranButoAOTCompiler.cacheGuestABI("sysv-linux-x86_64")
        )
        guard try untouched.load(identity) == nil else {
            fatalError("A missing cache directory unexpectedly returned an entry")
        }
        guard !FileManager.default.fileExists(atPath: untouchedRoot.path) else {
            fatalError("A cache read created the directory")
        }
        _ = try untouched.path(for: identity)
        _ = untouched.path(for: "read-only-path")
        guard try untouched.statistics().entryCount == 0 else {
            fatalError("Missing cache directory did not report empty statistics")
        }
        try untouched.removeAll()
        guard !FileManager.default.fileExists(atPath: untouchedRoot.path) else {
            fatalError("Read-only cache operations created the directory")
        }
        try untouched.store(try JSONEncoder().encode(first.translation), for: identity)
        guard FileManager.default.fileExists(atPath: untouchedRoot.path) else {
            fatalError("Cache store did not create the directory")
        }

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

        // Execution budgets are part of the cache identity; an artifact
        // compiled under a smaller budget must never alias the default block.
        let instructionLimited = try compiler.compile(
            guest, guestABI: "sysv-linux-x86_64", maximumInstructions: 1
        )
        precondition(!instructionLimited.cacheHit)
        precondition(instructionLimited.translation.stopReason == .instructionLimit)
        let instructionLimitedAgain = try compiler.compile(
            guest, guestABI: "sysv-linux-x86_64", maximumInstructions: 1
        )
        precondition(instructionLimitedAgain.cacheHit)

        let inputLimited = try compiler.compile(
            guest, guestABI: "sysv-linux-x86_64", maximumGuestBytes: 5
        )
        precondition(!inputLimited.cacheHit)
        precondition(inputLimited.translation.stopReason == .inputLimit)

        let outputLimited = try compiler.compile(
            guest, guestABI: "sysv-linux-x86_64", maximumOutputBytes: 4
        )
        precondition(!outputLimited.cacheHit)
        precondition(outputLimited.translation.stopReason == .outputLimit)
        let statisticsAfterBudgets = try cache.statistics()
        precondition(statisticsAfterBudgets.entryCount == 5)

        print("Kenran Butō AOT artifact cache round-trip, ABI isolation and fallback passed")
    }
}
