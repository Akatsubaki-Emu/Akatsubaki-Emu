import Foundation
import CryptoKit
import CryptoKit

final class TranslationCache {
    static let shared = TranslationCache()
    private let fm = FileManager.default
    private init() {}

    var directory: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("iSteam/TranslationCache", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func prepare() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        EmulationLog.shared.write("Translation cache: \(directory.path)")
    }

    func path(for key: String) -> URL {
        // Cache keys may contain arbitrary guest-controlled strings. Never
        // interpolate them into a filesystem path (".." could escape root).
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest, isDirectory: false)
    }
}
