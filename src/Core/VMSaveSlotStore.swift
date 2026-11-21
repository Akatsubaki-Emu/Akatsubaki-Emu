import Foundation

/// Persists named VM configuration slots and resumable session metadata.
/// This stores configuration, not guest RAM or actual game-save contents.
final class VMSaveSlotStore {
    static let shared = VMSaveSlotStore()
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Session: Codable {
        let configuration: VMConfiguration
        let gameID: UUID?
        let savedAt: Date
        // Optional so sessions written by earlier builds still decode.
        let diskImageBookmark: Data?
    }

    private var directory: URL {
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("VMSlots", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let maximumMetadataBytes = 1 * 1024 * 1024

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    enum StoreError: LocalizedError {
        case metadataTooLarge
        case invalidName
        var errorDescription: String? {
            switch self {
            case .metadataTooLarge:
                return "Saved VM metadata exceeds the 1 MiB safety limit."
            case .invalidName:
                return "VM configuration names must be non-empty, contain no NUL characters, and be at most 256 UTF-8 bytes."
            }
        }
    }

    private func legacySafeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let clean = String(name.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? "VM" : clean).prefix(64))
    }

    private func safeFilename(_ name: String) -> String {
        let hash = name.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return "\(legacySafeFilename(name))-\(String(format: "%016llx", hash))"
    }

    private func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 256 && !name.contains("\\0")
    }

    private func readConfiguration(at url: URL, expectedName: String) -> VMConfiguration? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maximumMetadataBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumMetadataBytes,
              let configuration = try? decoder.decode(VMConfiguration.self, from: data),
              configuration.name == expectedName else { return nil }
        return configuration
    }

    func saveConfiguration(_ configuration: VMConfiguration, name: String) throws {
        guard isValidName(name) else { throw StoreError.invalidName }
        var saved = configuration
        saved.name = name
        let url = directory.appendingPathComponent(safeFilename(name) + ".json")
        let data = try encoder.encode(saved)
        guard data.count <= maximumMetadataBytes else { throw StoreError.metadataTooLarge }
        try data.write(to: url, options: .atomic)
    }

    func configuration(named name: String) -> VMConfiguration? {
        guard isValidName(name) else { return nil }
        let current = directory.appendingPathComponent(safeFilename(name) + ".json")
        if let configuration = readConfiguration(at: current, expectedName: name) {
            return configuration
        }
        // Read legacy sanitized filenames for configurations saved before the
        // collision-resistant suffix was introduced.
        let legacy = directory.appendingPathComponent(legacySafeFilename(name) + ".json")
        return readConfiguration(at: legacy, expectedName: name)
    }

    var configurationNames: [String] {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter {
            $0.pathExtension == "json" && $0.lastPathComponent != "last-session.json"
        }.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size <= maximumMetadataBytes,
                  let data = try? Data(contentsOf: url), data.count <= maximumMetadataBytes,
                  let configuration = try? decoder.decode(VMConfiguration.self, from: data),
                  isValidName(configuration.name) else { return nil }
            return configuration.name
        }).sorted()
    }

    func saveSessionMetadata(configuration: VMConfiguration, diskImageURL: URL, gameID: UUID? = nil) throws {
        // Document-picker URLs may be security scoped. Keep the grant active
        // while the bookmark is created so Continue Last Session can resolve it.
        let scoped = diskImageURL.startAccessingSecurityScopedResource()
        defer { if scoped { diskImageURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try diskImageURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        guard bookmark.count <= maximumMetadataBytes / 2 else { throw StoreError.metadataTooLarge }
        let session = Session(
            configuration: configuration,
            gameID: gameID,
            savedAt: Date(),
            diskImageBookmark: bookmark
        )
        let data = try encoder.encode(session)
        guard data.count <= maximumMetadataBytes else { throw StoreError.metadataTooLarge }
        try data.write(to: directory.appendingPathComponent("last-session.json"), options: .atomic)
    }

    func lastSession() -> (configuration: VMConfiguration, diskImageURL: URL)? {
        let url = directory.appendingPathComponent("last-session.json")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maximumMetadataBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumMetadataBytes,
              let session = try? decoder.decode(Session.self, from: data),
              let bookmark = session.diskImageBookmark else { return nil }
        var stale = false
        guard let diskURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            // A resolvable stale bookmark is still useful. Refresh it now so
            // the next launch does not lose Continue Last Session.
            try? saveSessionMetadata(
                configuration: session.configuration,
                diskImageURL: diskURL,
                gameID: session.gameID
            )
        }
        return (session.configuration, diskURL)
    }

    func lastSessionConfiguration() -> VMConfiguration? {
        let url = directory.appendingPathComponent("last-session.json")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maximumMetadataBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumMetadataBytes,
              let session = try? decoder.decode(Session.self, from: data) else { return nil }
        return session.configuration
    }
}