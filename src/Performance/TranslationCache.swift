import Foundation
import CryptoKit

enum SHA256Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        var encoded = [UInt8]()
        encoded.reserveCapacity(digest.underestimatedCount * 2)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func digest(_ data: Data) -> String {
        encode(SHA256.hash(data: data))
    }
}

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
        if cpuFeatures.count < 2 {
            self.cpuFeatures = cpuFeatures
        } else {
            self.cpuFeatures = Array(Set(cpuFeatures)).sorted()
        }
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
    private static let defaultMaximumCodeBytes = 8 * 1024 * 1024
    private static let defaultMaximumEntryBytes = 12 * 1024 * 1024
    private static let defaultMaximumCacheBytes: UInt64 = 256 * 1024 * 1024
    private static let defaultMaximumEntries = 512

    private let fm: FileManager
    private let lock = NSLock()
    private let rootDirectory: URL?
    private let maximumCodeBytes: Int
    private let maximumEntryBytes: Int
    private let maximumCacheBytes: UInt64
    private let maximumEntries: Int

    private init() {
        let manager = FileManager.default
        fm = manager
        rootDirectory = manager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iSteam/TranslationCache", isDirectory: true)
        maximumCodeBytes = Self.defaultMaximumCodeBytes
        maximumEntryBytes = Self.defaultMaximumEntryBytes
        maximumCacheBytes = Self.defaultMaximumCacheBytes
        maximumEntries = Self.defaultMaximumEntries
    }

    init(directory: URL, maximumCodeBytes: Int = TranslationCache.defaultMaximumCodeBytes,
         maximumEntryBytes: Int = TranslationCache.defaultMaximumEntryBytes,
         maximumCacheBytes: UInt64 = TranslationCache.defaultMaximumCacheBytes,
         maximumEntries: Int = TranslationCache.defaultMaximumEntries,
         fileManager: FileManager = .default) {
        fm = fileManager
        rootDirectory = directory.standardizedFileURL
        self.maximumCodeBytes = min(max(1, maximumCodeBytes), 64 * 1024 * 1024)
        self.maximumEntryBytes = min(max(self.maximumCodeBytes, maximumEntryBytes), 80 * 1024 * 1024)
        self.maximumCacheBytes = max(1, maximumCacheBytes)
        self.maximumEntries = max(1, maximumEntries)
    }

    var directory: URL {
        rootDirectory ?? fm.temporaryDirectory
            .appendingPathComponent("iSteam-TranslationCache", isDirectory: true)
    }

    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? ensureCacheDirectory() else {
            EmulationLog.shared.write("Translation cache unavailable")
            return
        }
        EmulationLog.shared.write("Translation cache: \(url.path)")
    }

    func path(for key: String) -> URL {
        let digest = SHA256Hex.digest(Data(key.utf8))
        return directory.appendingPathComponent(digest + ".translation", isDirectory: false)
    }

    func path(for identity: TranslationCacheIdentity) throws -> URL {
        guard identity.isValid else { throw CacheError.invalidIdentity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let rootDirectory else { throw CacheError.unavailableDirectory }
        return rootDirectory.appendingPathComponent(
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
              fileSize <= maximumEntryBytes else {
            try? fm.removeItem(at: file)
            return nil
        }

        guard let rootDirectory else { throw CacheError.unavailableDirectory }
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
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
                  entry.code.count <= maximumCodeBytes,
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
        guard translatedCode.count <= maximumCodeBytes else {
            throw CacheError.translationTooLarge
        }

        lock.lock()
        defer { lock.unlock() }

        let root = try ensureCacheDirectory()
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
        guard encoded.count <= maximumEntryBytes else {
            throw CacheError.translationTooLarge
        }
        guard UInt64(encoded.count) <= maximumCacheBytes else {
            throw CacheError.translationTooLarge
        }
        try encoded.write(to: file, options: .atomic)
        do {
            try pruneCache(keeping: file, in: root)
        } catch {
            try? fm.removeItem(at: file)
            throw error
        }
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
        guard let root = rootDirectory else { throw CacheError.unavailableDirectory }
        guard fm.fileExists(atPath: root.path) else { return }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw CacheError.unavailableDirectory }
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw CacheError.unavailableDirectory }
        for case let file as URL in files where file.pathExtension == "translation" {
            try? fm.removeItem(at: file)
        }
    }

    func statistics() throws -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        guard let root = rootDirectory else { throw CacheError.unavailableDirectory }
        guard fm.fileExists(atPath: root.path) else {
            return Statistics(entryCount: 0, totalBytes: 0)
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw CacheError.unavailableDirectory }
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw CacheError.unavailableDirectory }

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

    private func ensureCacheDirectory() throws -> URL {
        guard let rootDirectory else { throw CacheError.unavailableDirectory }
        do {
            try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let values = try rootDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw CacheError.unavailableDirectory }
            return rootDirectory
        } catch {
            throw CacheError.unavailableDirectory
        }
    }

    private func pruneCache(keeping newestFile: URL, in root: URL) throws {
        guard let files = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { throw CacheError.unavailableDirectory }

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
        while entries.count > maximumEntries || total > maximumCacheBytes {
            guard let oldest = entries.first, oldest.url != newestFile else { break }
            entries.removeFirst()
            try fm.removeItem(at: oldest.url)
            total = total >= oldest.size ? total - oldest.size : 0
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256Hex.digest(data)
    }
}
