import unittest
from pathlib import Path


class LinuxMappingOrderTests(unittest.TestCase):
    def test_mapped_ranges_stay_sorted_without_per_call_sort_allocations(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("private func insertMappedRange(_ newRange: Range<UInt64>)", source)
        self.assertIn("private func firstMappedRangeEnding(after address: UInt64) -> Int", source)
        self.assertIn("insertMappedRange(address..<end)", source)
        self.assertIn("firstMappedRangeEnding(after: candidate)", source)
        self.assertIn("firstMappedRangeEnding(after: cursor)", source)
        self.assertIn("let firstPotential = firstMappedRangeEnding(after: address)", source)
        self.assertNotIn("mappedRanges.sorted", source)
        self.assertNotIn("mappedRanges.firstIndex(where:", source)
        self.assertIn("mappedRanges.first?.lowerBound ?? stackGuard", source)
        self.assertIn("private var minimumMmapCursor: UInt64 = 0", source)
        self.assertIn("minimumMmapCursor = minimumCursor", source)
        self.assertIn("mmapCursor = max(minimumMmapCursor, Self.alignUp(requested))", source)
        mapping = source.split("private func mapAnonymous", 1)[1].split("private func insertMappedRange", 1)[0]
        self.assertIn("var overlappingRanges: [Range<UInt64>] = []", mapping)
        self.assertIn("while index < mappedRanges.count && mappedRanges[index].lowerBound < end", mapping)
        self.assertIn("let overlapStart = max(address, overlap.lowerBound)", mapping)
        self.assertIn("let overlapEnd = min(end, overlap.upperBound)", mapping)
        self.assertIn("if zeroCursor < overlapStart", mapping)
        self.assertIn("if zeroCursor < end", mapping)
        self.assertNotIn("rangeWasCleared", mapping)


if __name__ == "__main__":
    unittest.main()
