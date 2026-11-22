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

    def test_import_rolls_back_only_profiles_created_by_this_import(self):
        importer = section(TRANSFER, "    func importBackup(from source: URL)", "    enum TransferError")
        self.assertIn("if try GameRuntimeProfileStore.shared.saveIfAbsent(profile)", importer)
        self.assertIn("savedProfileIDs.append(profile.gameID)", importer)
        self.assertIn("for gameID in savedProfileIDs", importer)
        self.assertNotIn("try GameRuntimeProfileStore.shared.save(profile)", importer)

    def test_save_if_absent_preserves_existing_profiles_and_reports_creation(self):
        save = section(PROFILE_STORE, "    func saveIfAbsent(", "    func profile(for gameID:")
        self.assertIn("lock.lock()", save)
        self.assertIn("defer { lock.unlock() }", save)
        self.assertIn("if fm.fileExists(atPath: destination.path)", save)
        self.assertIn("return false", save)
        self.assertIn("return true", save)
        self.assertIn("GameRuntimeProfile.ProfileError.corruptStoredProfile", save)

    def test_profile_inventory_and_mutations_are_serialized(self):
        inventory = section(PROFILE_STORE, "    func existingProfileIDs(", "    func removeProfile(")
        remove = section(PROFILE_STORE, "    func removeProfile(", "    private func profileFiles()")
        save = section(PROFILE_STORE, "    func save(_ profile:", "    func saveIfAbsent(")
        self.assertIn("lock.lock()", inventory)
        self.assertIn("lock.lock()", remove)
        self.assertIn("lock.lock()", save)

        importer = section(TRANSFER, "    func importBackup(from source: URL)", "    enum TransferError")
        self.assertIn("existingProfileIDs(for: incomingProfileIDs)", importer)
        self.assertNotIn("GameRuntimeProfileStore.shared.profile(for:", importer)


if __name__ == "__main__":
    unittest.main()
