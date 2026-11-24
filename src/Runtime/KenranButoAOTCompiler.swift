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

    static let executionABIVersion: UInt32 = 1

    static func cacheGuestABI(
        _ guestABI: String,
        abiVersion: UInt32 = executionABIVersion,
        guestRIP: UInt64? = nil,
        maximumInstructions: Int = X86_64AOTTranslator.maximumInstructionBudget,
        maximumGuestBytes: Int = X86_64AOTTranslator.maximumGuestByteBudget,
        maximumOutputBytes: Int = X86_64AOTTranslator.maximumOutputBudget
    ) -> String {
        let ripIdentity = guestRIP.map { String($0, radix: 16) } ?? "none"
        return "\(guestABI)-abi\(abiVersion)-rip\(ripIdentity)-i\(maximumInstructions)-g\(maximumGuestBytes)-o\(maximumOutputBytes)"
    }

    func compile(_ guestCode: Data, guestABI: String,
                 guestRIP: UInt64? = nil,
                 maximumInstructions: Int = 4096,
                 maximumGuestBytes: Int = 65_536,
                 maximumOutputBytes: Int = 1_048_576) throws -> Compilation {
        guard maximumInstructions > 0, maximumGuestBytes > 0,
              maximumOutputBytes >= 4, maximumOutputBytes.isMultiple(of: 4) else {
            throw NSError(domain: "KenranButoAOTCompiler", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AOT translation budgets are invalid."])
        }
        let budget = min(maximumInstructions, X86_64AOTTranslator.maximumInstructionBudget)
        let guestByteBudget = min(maximumGuestBytes, X86_64AOTTranslator.maximumGuestByteBudget)
        let outputByteBudget = min(maximumOutputBytes, X86_64AOTTranslator.maximumOutputBudget)
        let identity = TranslationCacheIdentity(
            guestCodeSHA256: SHA256Hex.digest(guestCode),
            guestArchitecture: "x86_64",
            translatorIdentifier: X86_64AOTTranslator.translatorIdentifier,
            translatorVersion: X86_64AOTTranslator.translatorVersion,
            hostArchitecture: X86_64AOTTranslator.hostArchitecture,
            cpuFeatures: X86_64AOTTranslator.cpuFeatures,
            guestABI: Self.cacheGuestABI(guestABI, abiVersion: Self.executionABIVersion,
                                        guestRIP: guestRIP,
                                        maximumInstructions: budget,
                                        maximumGuestBytes: guestByteBudget,
                                        maximumOutputBytes: outputByteBudget)
        )
        // Cache I/O is an optimization; failure must not disable fresh translation.
        if let cached = try? cache.load(identity) {
            if let translation = try? JSONDecoder().decode(X86_64AOTTranslation.self, from: cached),
               translation.isCacheable && translation.isValid(for: guestCode, maximumOutputBytes: outputByteBudget) {
                // Structural validation alone cannot authenticate cached machine code.
                let canonical = translator.translate(guestCode, guestRIP: guestRIP, maximumInstructions: budget,
                                                    maximumOutputBytes: outputByteBudget,
                                                    maximumGuestBytes: guestByteBudget)
                if translation == canonical {
                    return Compilation(translation: translation, cacheHit: true)
                }
            }
            try? cache.invalidate(identity)
        }
        let translation = translator.translate(guestCode, guestRIP: guestRIP, maximumInstructions: budget,
                                                    maximumOutputBytes: outputByteBudget,
                                                    maximumGuestBytes: guestByteBudget)
        if translation.isCacheable {
            try? cache.store(try JSONEncoder().encode(translation), for: identity)
        }
        return Compilation(translation: translation, cacheHit: false)
    }

}
