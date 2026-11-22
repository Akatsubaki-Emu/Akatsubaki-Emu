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

        print("Kenran Butō AOT artifact cache round-trip, ABI isolation and fallback passed")
    }
}
