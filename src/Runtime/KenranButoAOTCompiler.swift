import CryptoKit
import Foundation

/// Couples the AOT translator to Kenran Butō's validated artifact cache.
/// The result is a prepared artifact only; executable-memory allocation and
/// dispatch remain the responsibility of a platform-verified runtime adapter.
final class KenranButoAOTCompiler {
    struct Compilation {
        let translation: X86_64AOTTranslation
        let cacheHit: Bool
    }

    private let translator: X86_64AOTTranslator
    private let cache: TranslationCache

    init(cache: TranslationCache = .shared, translator: X86_64AOTTranslator = X86_64AOTTranslator()) {
        self.cache = cache
        self.translator = translator
    }

    func compile(_ guestCode: Data, guestABI: String) throws -> Compilation {
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: Self.sha256(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: guestABI
        )

        // The cache is an optimization, never an authority for native code.
        // Re-decode the guest bytes and compare the complete artifact before a
        // cached translation can be handed to an executable-memory provider.
        let translation = translator.translate(guestCode)
        if let cached = try cache.load(identity) {
            if let cachedTranslation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               cachedTranslation == translation,
               cachedTranslation.isCacheable,
               cachedTranslation.isValid(for: guestCode) {
                return Compilation(translation: cachedTranslation, cacheHit: true)
            }
            try cache.invalidate(identity)
        }
        if translation.isCacheable {
            try cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
