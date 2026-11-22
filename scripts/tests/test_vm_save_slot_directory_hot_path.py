import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Core" / "VMSaveSlotStore.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class VMSaveSlotDirectoryHotPathTests(unittest.TestCase):
    def test_directory_url_is_cached(self):
        self.assertIn("private let directory: URL", SOURCE)
        self.assertNotIn("private var directory: URL", SOURCE)
        initializer = section("    private init() {", "    private func ensureDirectory()")
        self.assertIn('directory = root.appendingPathComponent("VMSlots", isDirectory: true)', initializer)

    def test_directory_creation_is_explicit(self):
        helper = section("    private func ensureDirectory()", "    enum StoreError")
        self.assertIn("fm.createDirectory(at: directory", helper)

    def test_configuration_and_session_saves_ensure_directory(self):
        config = section("    func saveConfiguration(", "    func configuration(named:")
        session = section("    func saveSessionMetadata(", "    func lastSession()")
        self.assertIn("try ensureDirectory()", config)
        self.assertIn("try ensureDirectory()", session)

    def test_read_paths_do_not_create_directories(self):
        config = section("    func configuration(named:", "    var configurationNames:")
        names = section("    var configurationNames:", "    func saveSessionMetadata(")
        last = section("    func lastSession()", "    func lastSessionConfiguration()")
        self.assertNotIn("ensureDirectory()", config)
        self.assertNotIn("ensureDirectory()", names)
        self.assertNotIn("ensureDirectory()", last)


if __name__ == "__main__":
    unittest.main()
