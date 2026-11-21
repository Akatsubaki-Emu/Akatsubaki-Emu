import Foundation

/// Search and ordering options for a controller-friendly library screen.
/// Query results are metadata; a matching game is not necessarily executable.
struct GameLibraryQuery {
    enum SortOrder {
        case title
        case recentlyPlayed
        case recentlyAdded
    }

    var searchText: String = ""
    var favoritesOnly: Bool = false
    var requiredTag: String?
    var sortOrder: SortOrder = .title
    var limit: Int?

    func apply(to source: [GameEntry]) -> [GameEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = requiredTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = source.filter { game in
            if favoritesOnly && !game.isFavorite { return false }
            if let tag, !tag.isEmpty,
               !game.tags.contains(where: {
                   $0.trimmingCharacters(in: .whitespacesAndNewlines)
                       .localizedCaseInsensitiveCompare(tag) == .orderedSame
               }) {
                return false
            }
            guard !query.isEmpty else { return true }
            return game.name.localizedCaseInsensitiveContains(query)
                || game.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || (game.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }

        result.sort { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            switch sortOrder {
            case .title:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .recentlyPlayed:
                let left = lhs.lastPlayedAt ?? .distantPast
                let right = rhs.lastPlayedAt ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .recentlyAdded:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        if let limit, limit >= 0, result.count > limit {
            result = Array(result.prefix(limit))
        }
        return result
    }
}

/// A small facade shared by library UI and import/export flows.
extension GameStore {
    func query(_ query: GameLibraryQuery) -> [GameEntry] {
        query.apply(to: games)
    }

    var allTags: [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for game in games {
            for rawTag in game.tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                let key = tag.folding(options: .caseInsensitive, locale: .current)
                if seen.insert(key).inserted {
                    tags.append(tag)
                }
            }
        }
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var recentlyPlayed: [GameEntry] {
        games.filter { $0.lastPlayedAt != nil }.sorted {
            ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
        }
    }
}
