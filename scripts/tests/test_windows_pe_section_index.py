import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Runtime" / "WindowsPEImage.swift").read_text(encoding="utf-8")
SWIFT_TEST = (ROOT / "scripts" / "tests" / "test_windows_pe_image.swift").read_text(encoding="utf-8")

def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]

class WindowsPESectionIndexTests(unittest.TestCase):
    def test_sorted_index_and_source_order_flag_are_built_once(self):
        self.assertIn("private let virtualSections: [Section]", SOURCE)
        self.assertIn("private let sectionsAreSortedByRVA: Bool", SOURCE)
        self.assertIn("let virtualSections = sections.sorted { $0.virtualAddress < $1.virtualAddress }", SOURCE)
        self.assertIn("let sectionsAreSortedByRVA = zip(sections, sections.dropFirst())", SOURCE)

    def test_small_section_tables_use_linear_fast_path(self):
        lookup = section("private func section(forRVA rva: UInt32, allowEnd: Bool = false)", "private func readImports()")
        self.assertIn("private static let linearSectionLookupThreshold = 16", SOURCE)
        self.assertIn("if sections.count <= Self.linearSectionLookupThreshold", lookup)
        self.assertIn("if sectionsAreSortedByRVA", lookup)
        self.assertIn("if UInt64(rva) < start { return nil }", lookup)
        self.assertIn("for section in sections", lookup)

    def test_large_section_tables_use_binary_search(self):
        lookup = section("private func section(forRVA rva: UInt32, allowEnd: Bool = false)", "private func readImports()")
        self.assertIn("while lower < upper", lookup)
        self.assertIn("virtualSections[middle].virtualAddress <= rva", lookup)
        file_offset = section("func fileOffset(forRVA rva: UInt32, length: Int = 1)", "private func section(forRVA")
        self.assertIn("section(forRVA: rva", file_offset)
        contiguous = section("private func contiguousFileLength(forRVA rva: UInt32)", "private func readCString")
        self.assertIn("section(forRVA: rva)", contiguous)

    def test_zero_length_boundary_keeps_legacy_file_order(self):
        lookup = section("private func section(forRVA rva: UInt32, allowEnd: Bool = false)", "private func readImports()")
        self.assertIn("if allowEnd", lookup)
        self.assertIn("UInt64(rva) <= end", lookup)
        self.assertIn("Zero-length PE boundary mapping changed", SWIFT_TEST)

    def test_section_names_avoid_temporary_subdata_copy(self):
        self.assertIn("String(bytes: data[offset..<(offset + 8)].prefix { $0 != 0 }, encoding: .ascii)", SOURCE)
        self.assertNotIn("data.subdata(in: offset..<(offset + 8))", SOURCE)

    def test_swift_harness_covers_unsorted_and_large_section_tables(self):
        self.assertIn("Deliberately store sections in a different order from their RVAs", SWIFT_TEST)
        self.assertIn("32 sections exercise the binary-search path", SWIFT_TEST)
        self.assertIn("32-section PE binary lookup returned an incorrect file offset", SWIFT_TEST)
        self.assertIn("Raw zero-fill tail was incorrectly treated as file-backed", SWIFT_TEST)

if __name__ == "__main__":
    unittest.main()
