import Foundation

@main
struct TranslationCacheTests {
    static func main() throws {
        let cache = TranslationCache.shared
        try cache.removeAll()

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

        try cache.store(translated, for: identity)
        guard try cache.load(identity) == translated else {
            fatalError("Stored translation did not round-trip")
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

        let artifact = try cache.path(for: identity)
        try Data("corrupt".utf8).write(to: artifact, options: .atomic)
        guard try cache.load(identity) == nil else {
            fatalError("Corrupt translation was accepted")
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
        print("Translation cache integrity, version isolation, corruption rejection, and bounds tests passed.")
    }
}
