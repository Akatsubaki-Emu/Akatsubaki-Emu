import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "iSteam" / "GameStore.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GameStoreMutationHotPathTests(unittest.TestCase):
    def test_single_load_mutation_path(self):
        mutation = section("    private func mutate(id: UUID", "    var isReadable:")
        self.assertEqual(mutation.count("readableGames()"), 1)
        self.assertIn("persist(current)", mutation)
        self.assertNotIn("save(", mutation)

    def test_add_and_remove_do_not_decode_twice(self):
        add = section("    func add(_ game: GameEntry)", "    func update(")
        remove = section("    func remove(id: UUID)", "    func game(id: UUID)")
        for body in (add, remove):
            self.assertEqual(body.count("readableGames()"), 1)
            self.assertIn("persist(current)", body)
            self.assertNotIn("save(", body)

    def test_update_favorite_and_launch_share_the_single_load_mutator(self):
        for body in (
            section("    func update(_ game: GameEntry)", "    func remove("),
            section("    func setFavorite(_ favorite: Bool", "    /// Records a launch attempt;"),
            section("    func recordLaunchAccepted(id: UUID)", "\n}"),
        ):
            self.assertIn("mutate(id:", body)
            self.assertNotIn("game(id:", body)
            self.assertNotIn("save(", body)

    def test_library_validation_uses_one_reserved_identifier_set(self):
        validator = section("    private static func isValidLibrary", "    private func persist(")
        self.assertIn("identifiers.reserveCapacity(games.count)", validator)
        self.assertIn("identifiers.insert(game.id).inserted", validator)
        self.assertIn("game.validate()", validator)
        self.assertNotIn("games.map(\\.id)", validator)

    def test_public_save_still_preserves_unreadable_existing_data(self):
        save = section("    func save(_ games: [GameEntry]) -> Bool", "    @discardableResult\n    func add(")
        self.assertIn("readableGames() != nil", save)
        self.assertIn("return persist(games)", save)

    def test_reads_share_the_validated_loader(self):
        loader = section("    private func loadGames()", "    private func readableGames()")
        self.assertIn("Self.isValidLibrary(decoded)", loader)


if __name__ == "__main__":
    unittest.main()
