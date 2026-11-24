import unittest
from pathlib import Path


class LinuxMappingOrderTests(unittest.TestCase):
    def test_mapped_ranges_stay_sorted_and_updates_are_transactional(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")

        self.assertIn("private func mappedRangesAfterMapping(", source)
        self.assertIn("private func mappedRangesAfterRemoving(", source)
        self.assertIn("private func firstMappedRangeEnding(after address: UInt64) -> Int", source)
        self.assertIn("result.insert(newRange, at: lower)", source)
        self.assertIn("result.append(range.lowerBound..<newRange.lowerBound)", source)
        self.assertIn("result.append(newRange.upperBound..<range.upperBound)", source)
        self.assertIn("result.append(range.lowerBound..<removed.lowerBound)", source)
        self.assertIn("result.append(removed.upperBound..<range.upperBound)", source)
        self.assertIn("firstMappedRangeEnding(after: candidate)", source)
        self.assertIn("firstMappedRangeEnding(after: initialProgramBreak)", source)
        self.assertNotIn("mappedRanges.sorted", source)
        self.assertNotIn("mappedRanges.firstIndex(where:", source)

        mapping = source.split("private func mapAnonymous", 1)[1].split(
            "private func mappedRangesAfterMapping", 1
        )[0]
        self.assertIn("let nextMappedRanges = mappedRangesAfterMapping(", mapping)
        self.assertIn("memory.mapTransaction(", mapping)
        self.assertLess(mapping.index("let nextMappedRanges"), mapping.index("memory.mapTransaction("))
        self.assertIn("mappedRanges = nextMappedRanges", mapping)

        unmapping = source.split("private func unmap", 1)[1].split(
            "private func protect", 1
        )[0]
        self.assertIn("let nextMappedRanges = mappedRangesAfterRemoving(address..<end)", unmapping)
        self.assertIn("memory.unmap(offset: address, length: size)", unmapping)
        self.assertLess(
            unmapping.index("let nextMappedRanges"),
            unmapping.index("memory.unmap(offset: address, length: size)"),
        )
        self.assertIn("mappedRanges = nextMappedRanges", unmapping)


if __name__ == "__main__":
    unittest.main()
