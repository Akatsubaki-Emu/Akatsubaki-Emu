import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Steam" / "GameRuntimeProfile.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GameProfileDirectoryHotPathTests(unittest.TestCase):
    def test_directory_url_is_cached_as_a_stored_property(self):
        self.assertIn("private let directory: URL", SOURCE)
        initializer = section("    private init() {", "    private func ensureDirectory()")
        self.assertIn('directory = base.appendingPathComponent("GameProfiles", isDirectory: true)', initializer)

    def test_directory_creation_is_explicit_and_reusable(self):
        ensure = section("    private func ensureDirectory()", "    private func url(for id:")
        self.assertIn("fm.createDirectory(at: directory", ensure)

    def test_profile_lookup_does_not_create_the_directory_per_read(self):
        lookup = section("    func profile(for gameID: UUID)", "    func removeProfile(")
        self.assertIn("readProfile(at: url(for: gameID))", lookup)
        self.assertNotIn("ensureDirectory()", lookup)

    def test_save_and_enumeration_ensure_the_directory_when_needed(self):
        save = section("    func save(_ profile: GameRuntimeProfile)", "    private func readProfile(")
        files = section("    private func profileFiles()", "    func validatedProfiles()")
        self.assertIn("try ensureDirectory()", save)
        self.assertIn("try ensureDirectory()", files)


if __name__ == "__main__":
    unittest.main()
