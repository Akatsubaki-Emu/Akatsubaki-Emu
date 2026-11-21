import Foundation

/// Portable, user-editable compatibility notes inspired by game compatibility
/// databases. Ratings are advisory and never imply that a game can execute.
struct GameCompatibilityRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case unknown, runs, runsWithIssues, doesNotRun, blockedByAntiCheat
    }

    var id: String { appID }
    let appID: String
    var title: String
    var status: Status
    var testedRuntime: String
    var testedDevice: String
    var notes: String
    var updatedAt: Date

    func validate() throws {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              appID.count <= 128, !appID.contains("\0"),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 256, !testedRuntime.contains("\0"),
              testedRuntime.utf8.count <= 256,
              !testedDevice.contains("\0"), testedDevice.utf8.count <= 256,
              !notes.contains("\0"), notes.utf8.count <= 16_384 else {
            throw DatabaseError.invalidRecord
        }
    }

    enum DatabaseError: LocalizedError {
        case invalidRecord
        var errorDescription: String? { "The compatibility record contains invalid or oversized fields." }
    }
}

/// Atomic local storage; records are not represented as verified test results
/// unless the user supplies the test details.
final class GameCompatibilityDatabase {
    static let shared = GameCompatibilityDatabase()
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private init() { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }

    private var fileURL: URL {
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("game-compatibility.json")
    }

    private func loadRecords() throws -> [GameCompatibilityRecord] {
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize <= 5 * 1024 * 1024 else {
            throw DatabaseError.corruptDatabase
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 5 * 1024 * 1024,
              let records = try? decoder.decode([GameCompatibilityRecord].self, from: data),
              records.count <= 20_000,
              Set(records.map { $0.appID.lowercased() }).count == records.count,
              records.allSatisfy({ (try? $0.validate()) != nil }) else {
            throw DatabaseError.corruptDatabase
        }
        return records
    }

    var records: [GameCompatibilityRecord] {
        let loaded = (try? loadRecords()) ?? []
        return loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func record(for appID: String) -> GameCompatibilityRecord? {
        records.first { $0.appID.caseInsensitiveCompare(appID) == .orderedSame }
    }

    func save(_ record: GameCompatibilityRecord) throws {
        try record.validate()
        var current = try loadRecords()
        if let index = current.firstIndex(where: { $0.appID.caseInsensitiveCompare(record.appID) == .orderedSame }) {
            current[index] = record
        } else {
            guard current.count < 20_000 else { throw DatabaseError.tooManyRecords }
            current.append(record)
        }
        let data = try encoder.encode(current)
        guard data.count <= 5 * 1024 * 1024 else { throw DatabaseError.databaseTooLarge }
        try data.write(to: fileURL, options: .atomic)
        EmulationLog.shared.write("Saved compatibility note for \(record.title)")
    }

    func remove(appID: String) throws {
        let remaining = try loadRecords().filter { $0.appID.caseInsensitiveCompare(appID) != .orderedSame }
        try encoder.encode(remaining).write(to: fileURL, options: .atomic)
    }

    enum DatabaseError: LocalizedError {
        case tooManyRecords, databaseTooLarge, corruptDatabase
        var errorDescription: String? {
            switch self {
            case .tooManyRecords: return "The compatibility database has reached its record limit."
            case .databaseTooLarge: return "The compatibility database exceeds the 5 MB safety limit."
            case .corruptDatabase: return "The existing compatibility database is unreadable; it was preserved rather than overwritten."
            }
        }
    }
}
