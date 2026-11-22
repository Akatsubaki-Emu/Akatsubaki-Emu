import unittest
from pathlib import Path


class ELFLoaderCopyTests(unittest.TestCase):
    def test_static_pie_relocations_batch_data_access(self):
        root = Path(__file__).resolve().parents[2]
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        relocations = loader.split("let relocationCount = Int(relaSize / 24)", 1)[1].split("private func u16", 1)[0]
        self.assertIn("let orderedLoadSegments = loadSegments.sorted { $0.virtualAddress < $1.virtualAddress }", loader)
        relocation_setup = loader.split("let orderedLoadSegments =", 1)[1].split("let relocationCount =", 1)[0]
        self.assertIn("forVirtualAddress: relaAddress", relocation_setup)
        self.assertIn("fileOffset(", relocation_setup)
        self.assertIn("containsGuestRange(target, byteCount: 8", relocations)
        segment_lookup = loader.split("private func loadSegment(containing", 1)[1].split("private func containsGuestRange", 1)[0]
        self.assertIn("while lowerBound < upperBound", segment_lookup)
        range_lookup = loader.split("private func containsGuestRange", 1)[1].split("private func u16", 1)[0]
        self.assertIn("loadSegment(containing: address, in: segments)", range_lookup)
        self.assertNotIn("loadSegments.contains(where:", relocations)


if __name__ == "__main__":
    unittest.main()
