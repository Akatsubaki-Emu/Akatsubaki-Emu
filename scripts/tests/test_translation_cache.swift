import Foundation

@main
struct TranslationCacheTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kenran-cache-tests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranslationCache(directory: root)
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: String(repeating: "a", count: 64),
            guestArchitecture: "x86_64",
            translatorIdentifier: "kenran-buto",
            translatorVersion: "0.1.0",
            hostArchitecture: "arm64",
            cpuFeatures: ["neon", "crc", "neon"],
            guestABI: "linux-x86_64"
        )
        let translated = Data([0x1F, 0x20, 0x03, 0xD5, 0xC0, 0x03, 0x5F, 0xD6])
        let sha256ABC = [UInt8]([
            0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
            0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
            0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
            0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD
        ])
        guard SHA256Hex.encode(sha256ABC) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else {
            fatalError("SHA-256 hexadecimal encoding changed")
        }
        let untouchedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kenran-cache-no-create-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: untouchedRoot) }
        let untouched = TranslationCache(directory: untouchedRoot)
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
        try untouched.store(translated, for: identity)
        guard FileManager.default.fileExists(atPath: untouchedRoot.path) else {
            fatalError("Cache store did not create the directory")
        }

        try cache.store(translated, for: identity)
        guard try cache.load(identity) == translated else {
            fatalError("Stored translation did not round-trip")
        }
        guard try cache.statistics().entryCount == 1 else {
            fatalError("Cache statistics missed the stored entry")
        }

        let changedTranslator = TranslationCacheIdentity(
            guestCodeSHA256: identity.guestCodeSHA256,
            guestArchitecture: identity.guestArchitecture,
            translatorIdentifier: identity.translatorIdentifier,
            translatorVersion: "0.1.1",
            hostArchitecture: identity.hostArchitecture,
            cpuFeatures: identity.cpuFeatures,
            guestABI: identity.guestABI
        )
        guard try cache.load(changedTranslator) == nil else {
            fatalError("A translation from a different translator version was reused")
        }
        let changedABI = TranslationCacheIdentity(
            guestCodeSHA256: identity.guestCodeSHA256,
            guestArchitecture: identity.guestArchitecture,
            translatorIdentifier: identity.translatorIdentifier,
            translatorVersion: identity.translatorVersion,
            hostArchitecture: identity.hostArchitecture,
            cpuFeatures: identity.cpuFeatures,
            guestABI: "linux-x86_64-v2"
        )
        guard try cache.load(changedABI) == nil else {
            fatalError("A translation from a different guest ABI was reused")
        }

        try cache.invalidate(identity)
        guard try cache.load(identity) == nil else {
            fatalError("Invalidated translation was still returned")
        }

        try cache.store(translated, for: identity)
        let artifact = try cache.path(for: identity)
        let original = try Data(contentsOf: artifact)
        guard var envelope = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            fatalError("Translation cache envelope was not a JSON object")
        }
        envelope["code"] = Data([0, 1, 2, 3]).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try tampered.write(to: artifact, options: .atomic)
        guard try cache.load(identity) == nil else {
            fatalError("Translation with modified code was accepted")
        }
        guard try cache.statistics().entryCount == 0 else {
            fatalError("Corrupt cache entry was not removed")
        }

        do {
            try cache.store(Data(), for: identity)
            fatalError("Empty translated code was accepted")
        } catch TranslationCache.CacheError.emptyTranslation {
        }

        let invalidIdentity = TranslationCacheIdentity(
            guestCodeSHA256: "invalid",
            guestArchitecture: "x86_64",
            translatorIdentifier: "kenran-buto",
            translatorVersion: "0.1.0",
            hostArchitecture: "arm64",
            cpuFeatures: [],
            guestABI: "linux-x86_64"
        )
        do {
            try cache.store(translated, for: invalidIdentity)
            fatalError("Invalid cache identity was accepted")
        } catch TranslationCache.CacheError.invalidIdentity {
        }
        try cache.removeAll()

        let boundedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kenran-cache-bounds-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: boundedRoot) }
        let bounded = TranslationCache(
            directory: boundedRoot,
            maximumCodeBytes: 4096,
            maximumEntryBytes: 8192,
            maximumCacheBytes: 3072,
            maximumEntries: 2
        )
        let payload = Data(repeating: 0xA5, count: 1024)
        var firstIdentity: TranslationCacheIdentity?
        var newestIdentity: TranslationCacheIdentity?
        for index in 0..<3 {
            let item = TranslationCacheIdentity(
                guestCodeSHA256: String(repeating: String(index, radix: 16), count: 64),
                guestArchitecture: "x86_64",
                translatorIdentifier: "kenran-buto",
                translatorVersion: "0.1.0",
                hostArchitecture: "arm64",
                cpuFeatures: [],
                guestABI: "linux-x86_64"
            )
            if index == 0 { firstIdentity = item }
            if index == 2 { newestIdentity = item }
            try bounded.store(payload, for: item)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let stats = try bounded.statistics()
        guard stats.entryCount <= 2, stats.totalBytes <= 3072 else {
            fatalError("Cache entry-count or total-byte bounds were not enforced")
        }
        guard let firstIdentity, try bounded.load(firstIdentity) == nil else {
            fatalError("Least-recently-used entry was not evicted")
        }
        guard let newestIdentity, try bounded.load(newestIdentity) == payload else {
            fatalError("Newest translation was evicted")
        }
        try bounded.removeAll()
        print("Translation cache isolation, identity, integrity, invalidation, and capacity tests passed")
    }
}
