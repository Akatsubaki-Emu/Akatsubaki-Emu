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
            guestCodeSHA256: SHA256Hex.digest(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: guestABI
        )

        if let cached = try cache.load(identity) {
            if let translation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               translation.isCacheable,
               translation.isValid(for: guestCode) {
                return Compilation(translation: translation, cacheHit: true)
            }
            try cache.invalidate(identity)
        }

        let translation = translator.translate(guestCode)
        if translation.isCacheable {
            try cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }


}
