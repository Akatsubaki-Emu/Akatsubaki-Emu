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
        if limit == 0 || source.isEmpty { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = requiredTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = source
        result.removeAll { game in
            if favoritesOnly && !game.isFavorite { return true }
            if let tag, !tag.isEmpty,
               !game.tags.contains(where: {
                   $0.trimmingCharacters(in: .whitespacesAndNewlines)
                       .localizedCaseInsensitiveCompare(tag) == .orderedSame
               }) {
                return true
            }
            guard !query.isEmpty else { return false }
            return !game.name.localizedCaseInsensitiveContains(query)
                && !game.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                && !(game.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }

        let orderedBefore: (GameEntry, GameEntry) -> Bool = { lhs, rhs in
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

        if limit == 1 {
            guard let best = result.min(by: orderedBefore) else { return [] }
            return [best]
        }

        if result.count > 1 {
            result.sort(by: orderedBefore)
        }
        if let limit, limit > 1, result.count > limit {
            result.removeLast(result.count - limit)
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
        tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return tags
    }

    var recentlyPlayed: [GameEntry] {
        var result = games
        result.removeAll { $0.lastPlayedAt == nil }
        if result.count > 1 {
            result.sort {
                ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
        }
        return result
    }
}
