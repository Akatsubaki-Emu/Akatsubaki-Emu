import Foundation

/// A library entry is metadata only; it does not imply that the executable can run.
struct GameEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var executablePath: String
    var workingDirectory: String
    var launchArguments: [String] = []
    var coverArtPath: String? = nil
    var isFavorite: Bool = false
    var tags: [String] = []
    var lastPlayedAt: Date? = nil
    var addedAt: Date = Date()
    var notes: String? = nil

    init(
        id: UUID = UUID(),
        name: String,
        executablePath: String,
        workingDirectory: String,
        launchArguments: [String] = [],
        coverArtPath: String? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        lastPlayedAt: Date? = nil,
        addedAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
        self.coverArtPath = coverArtPath
        self.isFavorite = isFavorite
        self.tags = tags
        self.lastPlayedAt = lastPlayedAt
        self.addedAt = addedAt
        self.notes = notes
    }

    func validate() -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 256 && !name.contains("\0")
            && executablePath.utf8.count <= 4096 && !executablePath.contains("\0")
            && workingDirectory.utf8.count <= 4096 && !workingDirectory.contains("\0")
            && launchArguments.count <= 256
            && launchArguments.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") }
            && tags.count <= 128
            && tags.allSatisfy { $0.utf8.count <= 128 && !$0.contains("\0") }
            && (notes?.utf8.count ?? 0) <= 16_384
            && !(notes?.contains("\0") ?? false)
            && (coverArtPath?.utf8.count ?? 0) <= 4096
            && !(coverArtPath?.contains("\0") ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, executablePath, workingDirectory, launchArguments
        case coverArtPath, isFavorite, tags, lastPlayedAt, addedAt, notes
    }

    /// Backward-compatible decoding for entries created by older i-Steam builds.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        executablePath = try values.decode(String.self, forKey: .executablePath)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        launchArguments = try values.decodeIfPresent([String].self, forKey: .launchArguments) ?? []
        coverArtPath = try values.decodeIfPresent(String.self, forKey: .coverArtPath)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        addedAt = try values.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
        notes = try values.decodeIfPresent(String.self, forKey: .notes)
    }
}

final class GameStore {
    static let shared = GameStore()

    private let key = "iSteam.games"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    private func loadGames() -> [GameEntry]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard data.count <= 20 * 1024 * 1024,
              let decoded = try? decoder.decode([GameEntry].self, from: data),
              decoded.count <= 10_000 else { return nil }

        var identifiers = Set<UUID>()
        identifiers.reserveCapacity(decoded.count)
        for game in decoded {
            guard game.validate(), identifiers.insert(game.id).inserted else { return nil }
        }
        return decoded
    }

    private func loadGamesForMutation() -> [GameEntry]? {
        guard let value = loadGames() else {
            EmulationLog.shared.write("Game library data is unreadable; preserving the original data instead of treating it as an empty library")
            return nil
        }
        return value
    }

    private func persistValidated(_ games: [GameEntry]) -> Bool {
        guard games.count <= 10_000 else {
            EmulationLog.shared.write("Game library could not be encoded; existing saved data was left unchanged")
            return false
        }
        var identifiers = Set<UUID>()
        identifiers.reserveCapacity(games.count)
        for game in games {
            guard game.validate(), identifiers.insert(game.id).inserted else {
                EmulationLog.shared.write("Game library could not be encoded; existing saved data was left unchanged")
                return false
            }
        }
        guard let data = try? encoder.encode(games), data.count <= 20 * 1024 * 1024 else {
            EmulationLog.shared.write("Game library could not be encoded; existing saved data was left unchanged")
            return false
        }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    var isReadable: Bool { loadGames() != nil }

    var games: [GameEntry] {
        loadGamesForMutation() ?? []
    }

    @discardableResult
    func save(_ games: [GameEntry]) -> Bool {
        // Never replace a corrupt existing library with an empty or partial one.
        guard loadGames() != nil else {
            EmulationLog.shared.write("Game library save blocked because existing data could not be decoded")
            return false
        }
        return persistValidated(games)
    }

    func add(_ game: GameEntry) {
        guard var current = loadGamesForMutation(),
              !current.contains(where: { $0.id == game.id }) else { return }
        current.append(game)
        _ = persistValidated(current)
    }

    func update(_ game: GameEntry) {
        guard var current = loadGamesForMutation(),
              let index = current.firstIndex(where: { $0.id == game.id }) else { return }
        current[index] = game
        _ = persistValidated(current)
    }

    func remove(id: UUID) {
        guard let current = loadGamesForMutation(),
              persistValidated(current.filter { $0.id != id }) else { return }
        // Remove metadata and artwork only after the library entry is safely
        // removed, avoiding orphaned profile records in future backups.
        try? GameRuntimeProfileStore.shared.removeProfile(for: id)
        try? GameArtworkStore.shared.removeArtwork(for: id)
    }

    func game(id: UUID) -> GameEntry? {
        loadGamesForMutation()?.first { $0.id == id }
    }

    func search(_ query: String, favoritesOnly: Bool = false) -> [GameEntry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = loadGamesForMutation() ?? []
        results.removeAll { game in
            (favoritesOnly && !game.isFavorite) ||
            (!normalized.isEmpty &&
             !game.name.localizedCaseInsensitiveContains(normalized) &&
             !game.tags.contains(where: { $0.localizedCaseInsensitiveContains(normalized) }))
        }
        results.sort {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return results
    }

    func setFavorite(_ favorite: Bool, id: UUID) {
        guard var current = loadGamesForMutation(),
              let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].isFavorite = favorite
        _ = persistValidated(current)
    }

    /// Records a launch attempt; callers must only call this after a backend accepts it.
    func recordLaunchAccepted(id: UUID) {
        guard var current = loadGamesForMutation(),
              let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].lastPlayedAt = Date()
        _ = persistValidated(current)
    }
}
