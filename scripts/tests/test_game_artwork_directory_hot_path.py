import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Steam" / "GameArtworkStore.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GameArtworkDirectoryHotPathTests(unittest.TestCase):
    def test_directory_url_is_cached(self):
        self.assertIn("private let directory: URL", SOURCE)
        initializer = section("    private init() {", "    private func ensureDirectory()")
        self.assertIn('directory = base.appendingPathComponent("GameArtwork", isDirectory: true)', initializer)

    def test_import_recreates_directory_before_writing(self):
        importer = section("    func importArtwork(", "    func artworkURL(")
        self.assertIn("try ensureDirectory()", importer)
        self.assertLess(importer.index("try ensureDirectory()"), importer.index("try data.write(to: destination"))

    def test_artwork_lookup_has_no_directory_creation_side_effect(self):
        lookup = section("    private func artworkFiles(for gameID: UUID)", "    @discardableResult")
        self.assertNotIn("ensureDirectory()", lookup)
        self.assertNotIn("createDirectory", lookup)

    def test_ensure_helper_creates_directory(self):
        helper = section("    private func ensureDirectory()", "    private func artworkFiles(")
        self.assertIn("fm.createDirectory(at: directory", helper)


if __name__ == "__main__":
    unittest.main()
