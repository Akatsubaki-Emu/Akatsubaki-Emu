import CryptoKit
import Foundation

/// Couples the AOT translator to Kenran Butō's validated artifact cache.
/// Produces a validated translation artifact. Platform-specific executable-memory
/// allocation and dispatch are handled by KenranButoAOTExecutor.
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

    static func cacheGuestABI(_ guestABI: String, maximumInstructions: Int,
                              maximumGuestBytes: Int, maximumOutputBytes: Int) -> String {
        "\(guestABI)-i\(maximumInstructions)-g\(maximumGuestBytes)-o\(maximumOutputBytes)"
    }

    func compile(_ guestCode: Data, guestABI: String,
                 maximumInstructions: Int = 4096,
                 maximumGuestBytes: Int = 65_536,
                 maximumOutputBytes: Int = 1_048_576) throws -> Compilation {
        let budget = min(maximumInstructions, 4096)
        let guestByteBudget = min(max(maximumGuestBytes, 1), 65_536)
        let outputByteBudget = min(max(maximumOutputBytes, 4), 1_048_576)
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: Self.sha256(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: Self.cacheGuestABI(guestABI, maximumInstructions: budget,
                                        maximumGuestBytes: guestByteBudget,
                                        maximumOutputBytes: outputByteBudget)
        )
        if let cached = try cache.load(identity) {
            if let translation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               translation.isCacheable && translation.isValid(for: guestCode, maximumOutputBytes: outputByteBudget) {
                // Structural validation alone cannot authenticate cached machine code.
                let canonical = translator.translate(guestCode, maximumInstructions: budget,
                                                    maximumOutputBytes: outputByteBudget,
                                                    maximumGuestBytes: guestByteBudget)
                if translation == canonical {
                    return Compilation(translation: translation, cacheHit: true)
                }
            }
            try cache.invalidate(identity)
        }
        let translation = translator.translate(guestCode, maximumInstructions: budget,
                                                    maximumOutputBytes: outputByteBudget,
                                                    maximumGuestBytes: guestByteBudget)
        if translation.isCacheable {
            try cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
