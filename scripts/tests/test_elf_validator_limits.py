import unittest
from pathlib import Path


class ELFValidatorLimitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.validator = (root / "iSteam" / "ELFValidator.swift").read_text(encoding="utf-8")
        cls.loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")

    def test_validator_matches_loader_file_size_limit(self):
        self.assertIn("static let maximumFileSize = 512 * 1024 * 1024", self.validator)
        self.assertIn("case tooLarge", self.validator)
        self.assertIn("512 * 1024 * 1024", self.loader)

    def test_validator_rejects_oversized_files_before_opening_them(self):
        self.assertIn("let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])", self.validator)
        self.assertIn("guard values.isRegularFile == true, let fileSize = values.fileSize", self.validator)
        self.assertIn("guard fileSize <= Self.maximumFileSize else { throw ValidationError.tooLarge }", self.validator)
        self.assertLess(self.validator.index("guard fileSize <= Self.maximumFileSize"),
                        self.validator.index("FileHandle(forReadingFrom: url)"))


if __name__ == "__main__":
    unittest.main()
