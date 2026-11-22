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

    func compile(
        _ guestCode: Data,
        guestABI: String,
        maximumInstructions: Int = X86_64AOTTranslator.maximumInstructionBudget
    ) throws -> Compilation {
        let instructionBudget = max(1, min(maximumInstructions, X86_64AOTTranslator.maximumInstructionBudget))
        // The budget is part of the cache identity: a 4,096-instruction
        // artifact must never be reused for a 16-instruction dispatch slice.
        let cacheABI = "\(guestABI)|maxInstructions=\(instructionBudget)"
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: Self.sha256(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: cacheABI
        )

        var verifiedTranslation: X86_64AOTTranslation?
        if let cached = try cache.load(identity),
           let cachedTranslation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
           cachedTranslation.isCacheable,
           cachedTranslation.isValid(for: guestCode),
           cachedTranslation.instructionCount <= instructionBudget {
            // Re-decode and compare the complete artifact before executable use.
            // A valid checksum and structurally valid JSON do not prove that
            // cached ARM64 words correspond to the current guest instruction stream.
            let redecoded = translator.translate(guestCode, maximumInstructions: instructionBudget)
            if redecoded.isCacheable,
               redecoded.isValid(for: guestCode),
               redecoded == cachedTranslation {
                return Compilation(translation: cachedTranslation, cacheHit: true)
            }
            verifiedTranslation = redecoded
        }

        try? cache.invalidate(identity)
        let translation = verifiedTranslation
            ?? translator.translate(guestCode, maximumInstructions: instructionBudget)
        if translation.isCacheable {
            try cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
