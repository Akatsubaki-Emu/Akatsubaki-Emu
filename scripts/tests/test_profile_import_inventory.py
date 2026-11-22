import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROFILE_STORE = (ROOT / "src" / "Steam" / "GameRuntimeProfile.swift").read_text(encoding="utf-8")
TRANSFER = (ROOT / "src" / "Steam" / "DroidDeckFeatureServices.swift").read_text(encoding="utf-8")


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class ProfileImportInventoryTests(unittest.TestCase):
    def test_small_imports_use_direct_profile_checks(self):
        inventory = section(PROFILE_STORE, "    func existingProfileIDs(", "    private func profileFiles()")
        self.assertIn("if gameIDs.count <= 64", inventory)
        self.assertIn("readProfile(at: file)", inventory)
        self.assertIn("fm.fileExists(atPath: file.path)", inventory)

    def test_large_imports_enumerate_the_profile_directory_once(self):
        inventory = section(PROFILE_STORE, "    func existingProfileIDs(", "    private func profileFiles()")
        self.assertEqual(inventory.count("try profileFiles()"), 1)
        self.assertIn("for file in files", inventory)
        self.assertIn("gameIDs.contains(gameID)", inventory)
        self.assertIn("readProfile(at: file)", inventory)

    def test_corrupt_existing_profiles_are_never_overwritten(self):
        inventory = section(PROFILE_STORE, "    func existingProfileIDs(", "    private func profileFiles()")
        self.assertIn("GameRuntimeProfile.ProfileError.corruptStoredProfile", inventory)

    def test_import_uses_one_profile_inventory_not_per_entry_lookup(self):
        importer = section(TRANSFER, "    func importBackup(from source: URL)", "    enum TransferError")
        self.assertIn("existingProfileIDs(for: incomingProfileIDs)", importer)
        self.assertNotIn("GameRuntimeProfileStore.shared.profile(for:", importer)


if __name__ == "__main__":
    unittest.main()
