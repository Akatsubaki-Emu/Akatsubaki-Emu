import unittest
from pathlib import Path


class GameStoreHotPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.source = (root / "iSteam" / "GameStore.swift").read_text(encoding="utf-8")

    def test_decode_validation_uses_one_reserved_identifier_set(self):
        load = self.source.split("private func loadGames()", 1)[1].split("private func loadGamesForMutation", 1)[0]
        self.assertIn("identifiers.reserveCapacity(decoded.count)", load)
        self.assertIn("identifiers.insert(game.id).inserted", load)
        self.assertNotIn("decoded.map(\\.id)", load)

    def test_persistence_validation_uses_one_reserved_identifier_set(self):
        persist = self.source.split("private func persistValidated", 1)[1].split("var isReadable", 1)[0]
        self.assertIn("identifiers.reserveCapacity(games.count)", persist)
        self.assertIn("identifiers.insert(game.id).inserted", persist)
        self.assertNotIn("games.map(\\.id)", persist)

    def test_mutations_reuse_the_validated_snapshot(self):
        for method in ("add", "update", "remove", "setFavorite", "recordLaunchAccepted"):
            body = self.source.split("func " + method, 1)[1].split("\n    }", 1)[0]
            self.assertIn("loadGamesForMutation()", body)
            self.assertIn("persistValidated", body)
            self.assertNotIn("save(", body)

    def test_library_search_filters_and_sorts_in_place(self):
        search = self.source.split("func search(_ query:", 1)[1].split("func setFavorite", 1)[0]
        self.assertIn("results.removeAll { game in", search)
        self.assertIn("results.sort {", search)
        self.assertNotIn("games.filter", search)
        self.assertNotIn(".sorted", search)


if __name__ == "__main__":
    unittest.main()
