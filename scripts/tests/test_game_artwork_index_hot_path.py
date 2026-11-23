import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Steam" / "GameArtworkStore.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GameArtworkIndexHotPathTests(unittest.TestCase):
    def test_known_extensions_match_imported_image_formats(self):
        self.assertIn('supportedExtensions = ["jpg", "png", "heic", "webp", "gif"]', SOURCE)

    def test_per_game_lookup_checks_only_its_candidate_paths(self):
        lookup = section("    private func artworkFiles(for gameID: UUID)", "    @discardableResult")
        self.assertIn("Self.supportedExtensions", lookup)
        self.assertIn("fm.fileExists(atPath: $0.path)", lookup)
        self.assertNotIn("contentsOfDirectory", lookup)

    def test_artwork_lookup_does_not_scan_or_sort_the_entire_cache(self):
        lookup = section("    func artworkURL(for gameID: UUID)", "    func removeArtwork(")
        self.assertIn("artworkFiles(for: gameID)", lookup)
        self.assertIn("files.max", lookup)
        self.assertNotIn("contentsOfDirectory", lookup)
        self.assertNotIn(".sorted", lookup)

    def test_import_cleanup_checks_only_the_five_supported_extensions(self):
        importer = section("    func importArtwork(", "    func artworkURL(")
        self.assertIn("artworkFiles(for: gameID)", importer)
        self.assertNotIn("contentsOfDirectory", importer)

    def test_remove_does_not_enumerate_every_games_artwork(self):
        remover = section("    func removeArtwork(", "    enum ArtworkError")
        self.assertIn("artworkFiles(for: gameID)", remover)
        self.assertNotIn("contentsOfDirectory", remover)


if __name__ == "__main__":
    unittest.main()
