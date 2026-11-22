import unittest
from pathlib import Path


class GuestProcessInspectionTests(unittest.TestCase):
    def test_executable_format_probe_reads_only_the_required_magic_bytes(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestProcess.swift").read_text(encoding="utf-8")
        inspect = source.split("func inspect(_ url: URL)", 1)[1].split("enum GuestProcessFormatResult", 1)[0]

        self.assertIn("size >= 2", inspect)
        self.assertIn("handle.read(upToCount: min(4, size))", inspect)
        self.assertIn("data.count >= 2", inspect)
        self.assertIn("data.count >= 4", inspect)
        self.assertNotIn("min(4096, size)", inspect)


if __name__ == "__main__":
    unittest.main()
