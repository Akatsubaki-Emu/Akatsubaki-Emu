import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Windows" / "GameCompatibilityDatabase.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class CompatibilityDatabaseHotPathTests(unittest.TestCase):
    def test_database_url_is_cached(self):
        self.assertIn("private let fileURL: URL", SOURCE)
        self.assertNotIn("private var fileURL: URL", SOURCE)

    def test_record_lookup_does_not_sort_the_entire_database(self):
        lookup = section("    func record(for appID: String)", "    func save(")
        self.assertIn("try? loadRecords()", lookup)
        self.assertNotIn("records.first", lookup)

    def test_validation_uses_one_reserved_identifier_set(self):
        validation = section("    private static func areValid(", "    private func loadRecords()")
        self.assertIn("identifiers.reserveCapacity(records.count)", validation)
        self.assertIn("identifiers.insert(record.appID.lowercased()).inserted", validation)
        self.assertIn("record.validate()", validation)
        self.assertNotIn("records.map", validation)

    def test_writes_ensure_directory_without_read_side_effects(self):
        save = section("    func save(", "    func remove(")
        remove = section("    func remove(", "    enum DatabaseError")
        load = section("    private func loadRecords()", "    var records:")
        self.assertIn("try ensureDirectory()", save)
        self.assertIn("try ensureDirectory()", remove)
        self.assertNotIn("ensureDirectory()", load)


if __name__ == "__main__":
    unittest.main()
