import CryptoKit
import Foundation

/// Couples the AOT translator to Kenran Butō's validated artifact cache.
/// The compiler returns bounded, canonicalized translation artifacts. The
/// platform executor separately validates guest state and owns W^X dispatch.
final class KenranButoAOTCompiler {
    struct Compilation {
        let translation: X86_64AOTTranslation
        let cacheHit: Bool
    }

    private let translator: X86_64AOTTranslator
    private let cache: TranslationCache

    static let executionABIVersion: UInt32 = 1

    static func cacheGuestABI(_ guestABI: String, abiVersion: UInt32 = executionABIVersion,
                              maximumInstructions: Int = X86_64AOTTranslator.maximumInstructionBudget,
                              maximumGuestBytes: Int = X86_64AOTTranslator.maximumGuestByteBudget,
                              maximumOutputBytes: Int = X86_64AOTTranslator.maximumOutputBudget) -> String {
        "\(guestABI)-abi\(abiVersion)-i\(maximumInstructions)-g\(maximumGuestBytes)-o\(maximumOutputBytes)"
    }

    init(cache: TranslationCache = .shared, translator: X86_64AOTTranslator = X86_64AOTTranslator()) {
        self.cache = cache
        self.translator = translator
    }

    func compile(_ guestCode: Data, guestABI: String,
                  maximumInstructions: Int = X86_64AOTTranslator.maximumInstructionBudget,
                  maximumOutputBytes: Int = X86_64AOTTranslator.maximumOutputBudget,
                  maximumGuestBytes: Int = X86_64AOTTranslator.maximumGuestByteBudget) throws -> Compilation {
        guard maximumInstructions > 0, maximumOutputBytes >= 4,
              maximumOutputBytes.isMultiple(of: 4), maximumGuestBytes > 0 else {
            return Compilation(translation: translator.translate(guestCode,
                maximumInstructions: maximumInstructions, maximumOutputBytes: maximumOutputBytes,
                maximumGuestBytes: maximumGuestBytes), cacheHit: false)
        }
        let instructionBudget = min(maximumInstructions, X86_64AOTTranslator.maximumInstructionBudget)
        let outputBudget = min(maximumOutputBytes, X86_64AOTTranslator.maximumOutputBudget)
        let guestByteBudget = min(maximumGuestBytes, X86_64AOTTranslator.maximumGuestByteBudget)

        let identity = TranslationCacheIdentity(
            guestCodeSHA256: Self.sha256(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: Self.cacheGuestABI(guestABI, maximumInstructions: instructionBudget,
                                         maximumGuestBytes: guestByteBudget,
                                         maximumOutputBytes: outputBudget),
            translationInstructionBudget: instructionBudget,
            translationInputByteBudget: guestByteBudget,
            translationOutputByteBudget: outputBudget
        )

        if let cached = try? cache.load(identity) {
            if let translation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               translation.isCacheable,
               translation.guestBytesConsumed <= guestByteBudget,
               translation.instructionCount <= instructionBudget,
               translation.isValid(for: guestCode, maximumOutputBytes: outputBudget) {
                let canonical = translator.translate(guestCode,
                    maximumInstructions: instructionBudget, maximumOutputBytes: outputBudget,
                    maximumGuestBytes: guestByteBudget)
                if translation == canonical { return Compilation(translation: translation, cacheHit: true) }
            }
            try? cache.invalidate(identity)
        }

        let translation = translator.translate(guestCode,
            maximumInstructions: instructionBudget, maximumOutputBytes: outputBudget,
            maximumGuestBytes: guestByteBudget)
        if translation.isCacheable {
            try? cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
