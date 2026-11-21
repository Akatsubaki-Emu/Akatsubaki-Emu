import Foundation
import CryptoKit

struct TranslationCacheIdentity: Codable, Equatable {
    let guestCodeSHA256: String
    let guestArchitecture: String
    let translatorIdentifier: String
    let translatorVersion: String
    let hostArchitecture: String
    let cpuFeatures: [String]
    let guestABI: String

    init(guestCodeSHA256: String,
         guestArchitecture: String,
         translatorIdentifier: String,
         translatorVersion: String,
         hostArchitecture: String,
         cpuFeatures: [String],
         guestABI: String) {
        self.guestCodeSHA256 = guestCodeSHA256.lowercased()
        self.guestArchitecture = guestArchitecture
        self.translatorIdentifier = translatorIdentifier
        self.translatorVersion = translatorVersion
        self.hostArchitecture = hostArchitecture
        self.cpuFeatures = Array(Set(cpuFeatures)).sorted()
        self.guestABI = guestABI
    }

    var isValid: Bool {
        guestCodeSHA256.count == 64
            && guestCodeSHA256.allSatisfy(\.isHexDigit)
            && Self.validToken(guestArchitecture, maximum: 32)
            && Self.validToken(translatorIdentifier, maximum: 96)
            && Self.validToken(translatorVersion, maximum: 64)
            && Self.validToken(hostArchitecture, maximum: 32)
            && Self.validToken(guestABI, maximum: 96)
            && cpuFeatures.count <= 128
            && cpuFeatures.allSatisfy { Self.validToken($0, maximum: 64) }
    }

    private static func validToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }
}

final class TranslationCache {
    struct Statistics: Equatable {
        let entryCount: Int
        let totalBytes: UInt64
    }

    private struct Entry: Codable {
        let schemaVersion: Int
        let identity: TranslationCacheIdentity
        let codeSHA256: String
        let code: Data
        let createdAt: Date
    }

    enum CacheError: LocalizedError {
        case invalidIdentity
        case emptyTranslation
        case translationTooLarge
        case unavailableDirectory

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The translation cache identity is incomplete or invalid."
            case .emptyTranslation: return "An empty translated-code artifact cannot be cached."
            case .translationTooLarge: return "The translated-code artifact exceeds the cache entry limit."
            case .unavailableDirectory: return "The translation cache directory is unavailable."
            }
        }
    }

    static let shared = TranslationCache()

    private static let schemaVersion = 1
    private static let maximumCodeBytes = 8 * 1024 * 1024
    private static let maximumEntryBytes = 12 * 1024 * 1024
    private static let maximumCacheBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumEntries = 512

    private let fm = FileManager.default
    private let lock = NSLock()

    private init() {}

    var directory: URL {
        (try? cacheDirectory()) ?? fm.temporaryDirectory
            .appendingPathComponent("iSteam-TranslationCache", isDirectory: true)
    }

    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? cacheDirectory() else {
            EmulationLog.shared.write("Translation cache unavailable")
            return
        }
        EmulationLog.shared.write("Translation cache: \(url.path)")
    }

    func path(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest + ".translation", isDirectory: false)
    }

    func path(for identity: TranslationCacheIdentity) throws -> URL {
        guard identity.isValid else { throw CacheError.invalidIdentity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try cacheDirectory().appendingPathComponent(
            Self.digest(try encoder.encode(identity)) + ".translation",
            isDirectory: false
        )
    }

    func load(_ identity: TranslationCacheIdentity) throws -> Data? {
        guard identity.isValid else { throw CacheError.invalidIdentity }
        lock.lock()
        defer { lock.unlock() }

        let file = try path(for: identity)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumEntryBytes else {
            try? fm.removeItem(at: file)
            return nil
        }

        let root = try cacheDirectory().resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPrefix) else {
            try? fm.removeItem(at: file)
            return nil
        }

        do {
            let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            let entry = try JSONDecoder().decode(Entry.self, from: data)
            guard entry.schemaVersion == Self.schemaVersion,
                  entry.identity == identity,
                  !entry.code.isEmpty,
                  entry.code.count <= Self.maximumCodeBytes,
                  Self.digest(entry.code) == entry.codeSHA256 else {
                try? fm.removeItem(at: file)
                return nil
            }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return entry.code
        } catch {
            try? fm.removeItem(at: file)
            return nil
        }
    }

    func store(_ translatedCode: Data, for identity: TranslationCacheIdentity) throws {
        guard identity.isValid else { throw CacheError.invalidIdentity }
        guard !translatedCode.isEmpty else { throw CacheError.emptyTranslation }
        guard translatedCode.count <= Self.maximumCodeBytes else {
            throw CacheError.translationTooLarge
        }

        lock.lock()
        defer { lock.unlock() }

        let file = try path(for: identity)
        let entry = Entry(
            schemaVersion: Self.schemaVersion,
            identity: identity,
            codeSHA256: Self.digest(translatedCode),
            code: translatedCode,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(entry)
        guard encoded.count <= Self.maximumEntryBytes else {
            throw CacheError.translationTooLarge
        }
        try encoded.write(to: file, options: .atomic)
        try pruneCache(keeping: file)
    }

    func invalidate(_ identity: TranslationCacheIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        let file = try path(for: identity)
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let root = try cacheDirectory()
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let file as URL in files where file.pathExtension == "translation" {
            try? fm.removeItem(at: file)
        }
    }

    func statistics() throws -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        let root = try cacheDirectory()
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return Statistics(entryCount: 0, totalBytes: 0) }

        var count = 0
        var total: UInt64 = 0
        for case let file as URL in files where file.pathExtension == "translation" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0 else { continue }
            count += 1
            let sum = total.addingReportingOverflow(UInt64(size))
            total = sum.overflow ? UInt64.max : sum.partialValue
        }
        return Statistics(entryCount: count, totalBytes: total)
    }

    private func cacheDirectory() throws -> URL {
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CacheError.unavailableDirectory
        }
        let root = base.appendingPathComponent("iSteam/TranslationCache", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw CacheError.unavailableDirectory }
            return root
        } catch {
            throw CacheError.unavailableDirectory
        }
    }

    private func pruneCache(keeping newestFile: URL) throws {
        let root = try cacheDirectory()
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for case let file as URL in files where file.pathExtension == "translation" {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ), values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                continue
            }
            let bytes = UInt64(size)
            entries.append((file, bytes, values.contentModificationDate ?? .distantPast))
            let sum = total.addingReportingOverflow(bytes)
            total = sum.overflow ? UInt64.max : sum.partialValue
        }

        entries.sort {
            if $0.url == newestFile { return false }
            if $1.url == newestFile { return true }
            if $0.modified != $1.modified { return $0.modified < $1.modified }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        while entries.count > Self.maximumEntries || total > Self.maximumCacheBytes {
            guard let oldest = entries.first, oldest.url != newestFile else { break }
            entries.removeFirst()
            try? fm.removeItem(at: oldest.url)
            total = total >= oldest.size ? total - oldest.size : 0
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
