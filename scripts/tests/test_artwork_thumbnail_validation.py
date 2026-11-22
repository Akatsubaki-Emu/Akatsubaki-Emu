import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Steam" / "GameArtworkStore.swift").read_text(encoding="utf-8")
VALIDATOR = (ROOT / "scripts" / "validate-qemu-source.py").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class ArtworkThumbnailValidationTests(unittest.TestCase):
    def test_import_uses_downsampled_thumbnail_instead_of_full_image_decode(self):
        importer = section("    func importArtwork(", "    func artworkURL(")
        self.assertIn("CGImageSourceCreateThumbnailAtIndex(image, 0, thumbnailOptions)", importer)
        self.assertNotIn("CGImageSourceCreateImageAtIndex", importer)

    def test_thumbnail_decode_is_bounded_to_512_pixels(self):
        importer = section("    func importArtwork(", "    func artworkURL(")
        self.assertIn("kCGImageSourceCreateThumbnailFromImageAlways: true", importer)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: 512", importer)
        self.assertIn("kCGImageSourceShouldCacheImmediately: true", importer)

    def test_original_image_dimension_and_pixel_safety_limits_remain(self):
        importer = section("    func importArtwork(", "    func artworkURL(")
        self.assertIn("width <= 8192, height <= 8192", importer)
        self.assertIn("width <= (16 * 1024 * 1024) / height", importer)
        self.assertIn("data.count <= maxBytes", importer)

    def test_source_validator_tracks_the_thumbnail_path(self):
        self.assertIn("CGImageSourceCreateThumbnailAtIndex(image, 0, thumbnailOptions) != nil", VALIDATOR)
        self.assertNotIn("CGImageSourceCreateImageAtIndex(image, 0, nil) != nil", VALIDATOR)


if __name__ == "__main__":
    unittest.main()
