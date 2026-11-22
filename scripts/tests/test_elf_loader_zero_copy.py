import unittest
from pathlib import Path


class ELFLoaderCopyTests(unittest.TestCase):
    def test_static_pie_relocations_batch_data_access(self):
        root = Path(__file__).resolve().parents[2]
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        relocations = loader.split("let relocationCount = Int(relaSize / 24)", 1)[1].split("private func u16", 1)[0]
        self.assertEqual(relocations.count("data.withUnsafeBytes"), 1)
        self.assertIn("raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)", relocations)
        self.assertNotIn("u64(data, offset", relocations)

    def test_load_segments_use_bounded_zero_copy_guest_memory_write(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        ranged_write = memory.split("func write(_ data: Data, sourceRange:", 1)[1].split("func write(_ data: Data, offset:", 1)[0]
        self.assertIn("sourceRange.upperBound <= data.count", ranged_write)
        self.assertIn("UInt64(sourceRange.count) <= size - offset", ranged_write)
        self.assertIn("base.advanced(by: sourceRange.lowerBound)", ranged_write)
        self.assertIn("isteam_guest_memory_write(native, offset, source, sourceRange.count)", ranged_write)
        copy_loop = loader.split("for (segment, fileOffset) in pending where segment.fileSize > 0", 1)[1].split("let maximumGuestAddress", 1)[0]
        self.assertIn("memory.write(data, sourceRange: fileOffset..<sourceEnd", copy_loop)
        self.assertNotIn("subdata(in:", copy_loop)
        self.assertNotIn("chunkSize", copy_loop)


    def test_static_pie_relocation_segment_lookup_uses_binary_search(self):
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
