import unittest
from pathlib import Path


class LinuxMappingOrderTests(unittest.TestCase):
    def test_mapped_ranges_stay_sorted_without_per_call_sort_allocations(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("private func insertMappedRange(_ newRange: Range<UInt64>)", source)
        self.assertIn("insertMappedRange(address..<end)", source)
        self.assertNotIn("mappedRanges.sorted", source)
        self.assertIn("mappedRanges.first?.lowerBound ?? mmapCursor", source)
        self.assertIn("for range in mappedRanges {", source)


if __name__ == "__main__":
    unittest.main()
