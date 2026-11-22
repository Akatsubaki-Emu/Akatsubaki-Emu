import Foundation

struct GameEntry {
    let name: String
    let tags: [String]
    let notes: String?
    let isFavorite: Bool
    let lastPlayedAt: Date?
    let addedAt: Date
}

final class GameStore {
    var games: [GameEntry]
    init(_ games: [GameEntry]) { self.games = games }
}

@main
enum GameLibraryQueryTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let games = [
            GameEntry(name: "Portal", tags: [" Puzzle ", "Science"], notes: "A science game",
                      isFavorite: false, lastPlayedAt: now, addedAt: now),
            GameEntry(name: "Zelda", tags: ["Action", " RPG "], notes: nil,
                      isFavorite: true, lastPlayedAt: nil, addedAt: now.addingTimeInterval(10)),
            GameEntry(name: "Another Portal", tags: ["puzzle", "ACTION", "  "], notes: "Science fiction",
                      isFavorite: true, lastPlayedAt: now.addingTimeInterval(20), addedAt: now)
        ]
        let store = GameStore(games)
        let tags = store.allTags
        precondition(tags.count == 4)
        precondition(Set(tags.map { $0.lowercased() }) == Set(["puzzle", "science", "action", "rpg"]))

        let filtered = store.query(GameLibraryQuery(
            searchText: "science",
            requiredTag: " puzzle ",
            sortOrder: .title
        ))
        precondition(Set(filtered.map(\.name)) == Set(["Another Portal", "Portal"]))

        let favorites = store.query(GameLibraryQuery(favoritesOnly: true, sortOrder: .title, limit: 1))
        precondition(favorites.count == 1)
        precondition(favorites[0].name == "Another Portal")

        let recent = store.recentlyPlayed
        precondition(recent.first?.name == "Another Portal")
        print("Game library query and single-pass tag collection tests passed")
    }
}
