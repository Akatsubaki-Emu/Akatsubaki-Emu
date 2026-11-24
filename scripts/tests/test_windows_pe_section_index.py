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
        self.assertIn("fileBackedRange(forRVA: rva, allowEnd: length == 0)", file_offset)
        contiguous = section("private func contiguousFileLength(forRVA rva: UInt32)", "private func readCString")
        self.assertIn("fileBackedRange(forRVA: rva).length", contiguous)


    def test_zero_length_boundary_keeps_legacy_file_order(self):
        lookup = section("private func section(forRVA rva: UInt32, allowEnd: Bool = false)", "private func readImports()")
        self.assertIn("if allowEnd", lookup)
        self.assertIn("address > start && address == end", lookup)
        self.assertIn("Zero-length PE boundary mapping changed", SWIFT_TEST)


    def test_file_backed_range_is_shared(self):
        mapping = section("private func fileBackedRange(forRVA rva: UInt32, allowEnd: Bool = false)", "private struct RVAFileCursor")
        self.assertIn("section(forRVA: rva, allowEnd: allowEnd)", mapping)
        self.assertIn("section.rawSize", mapping)
        self.assertIn("fileBackedRange(forRVA: rva", section("func fileOffset(forRVA rva: UInt32, length: Int = 1)", "private func section(forRVA"))
        self.assertIn("fileBackedRange(forRVA: rva)", section("private func contiguousFileLength", "private func readCString"))

    def test_rva_cursor_reuses_only_contiguous_file_backed_bytes(self):
        cursor = section("private struct RVAFileCursor", "private func readImports()")
        self.assertIn("UInt64(rva) == nextRVA", cursor)
        self.assertIn("length <= remainingBytes", cursor)
        self.assertIn("remainingBytes = mapping.length - length", cursor)
        self.assertIn("image.fileBackedRange(forRVA: rva", cursor)

    def test_import_and_relocation_streams_use_independent_cursors(self):
        imports = section("private func readImports()", "private func readRelocations()")
        relocations = section("private func readRelocations()", "private func contiguousFileLength")
        self.assertIn("var descriptorCursor = RVAFileCursor(image: self)", imports)
        self.assertIn("descriptorCursor.offset(forRVA:", imports)
        self.assertIn("var thunkCursor = RVAFileCursor(image: self)", imports)
        self.assertIn("thunkCursor.offset(forRVA:", imports)
        self.assertIn("var relocationCursor = RVAFileCursor(image: self)", relocations)
        self.assertIn("relocationCursor.offset(forRVA:", relocations)

    def test_section_names_avoid_temporary_subdata_copy(self):
        self.assertIn("String(bytes: data[offset..<(offset + 8)].prefix { $0 != 0 }, encoding: .ascii)", SOURCE)
        self.assertNotIn("data.subdata(in: offset..<(offset + 8))", SOURCE)

    def test_swift_harness_covers_unsorted_and_large_section_tables(self):
        self.assertIn("Deliberately store sections in a different order from their RVAs", SWIFT_TEST)
        self.assertIn("32 sections exercise the binary-search path", SWIFT_TEST)
        self.assertIn("32-section PE binary lookup returned an incorrect file offset", SWIFT_TEST)
        self.assertIn("Sequential import thunk cursor returned incorrect ordinals", SWIFT_TEST)
        self.assertIn("Cross-section import thunk cursor failed to remap", SWIFT_TEST)
        self.assertIn("Cross-section relocation cursor failed to remap", SWIFT_TEST)
        self.assertIn("Raw zero-fill tail was incorrectly treated as file-backed", SWIFT_TEST)

if __name__ == "__main__":
    unittest.main()
