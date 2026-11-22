import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GAME_STORE = (ROOT / "iSteam" / "GameStore.swift").read_text(encoding="utf-8")
PROFILE_STORE = (ROOT / "src" / "Steam" / "GameRuntimeProfile.swift").read_text(encoding="utf-8")
TRANSFER = (ROOT / "src" / "Steam" / "DroidDeckFeatureServices.swift").read_text(encoding="utf-8")


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class GameLibraryTransferSnapshotTests(unittest.TestCase):
    def test_export_reads_each_store_once(self):
        export = section(TRANSFER, "    func export(to destination: URL)", "    @discardableResult\n    func importBackup")
        self.assertEqual(export.count("GameStore.shared.validatedSnapshot()"), 1)
        self.assertEqual(export.count("GameRuntimeProfileStore.shared.validatedProfiles()"), 1)
        self.assertNotIn("GameStore.shared.isReadable", export)
        self.assertNotIn("hasUnreadableProfiles", export)
        self.assertNotIn("allProfiles", export)

    def test_import_reuses_one_game_snapshot_for_validation_and_merge(self):
        importer = section(TRANSFER, "    func importBackup(from source: URL)", "    enum TransferError")
        self.assertEqual(importer.count("GameStore.shared.validatedSnapshot()"), 1)
        self.assertIn("let existingIDs = Set(currentSnapshot.map(\\.id))", importer)
        self.assertIn("var current = currentSnapshot", importer)
        self.assertNotIn("GameStore.shared.games", importer)

    def test_profile_snapshot_enumerates_and_decodes_once(self):
        snapshot = section(PROFILE_STORE, "    func validatedProfiles()", "    var hasUnreadableProfiles:")
        self.assertEqual(snapshot.count("profileFiles()"), 1)
        self.assertIn("for file in files", snapshot)
        self.assertIn("readProfile(at: file)", snapshot)
        self.assertIn("profiles.reserveCapacity(files.count)", snapshot)
        self.assertIn("profiles.sort", snapshot)

    def test_uuid_sets_use_lazy_projection_without_intermediate_arrays(self):
        export = section(TRANSFER, "    func export(to destination: URL)", "    @discardableResult\\n    func importBackup")
        importer = section(TRANSFER, "    func importBackup(from source: URL)", "    enum TransferError")
        self.assertIn("Set(games.lazy.map(\\\\.id))", export)
        self.assertIn("Set(currentSnapshot.lazy.map(\\\\.id))", importer)
        self.assertNotIn("Set(games.map(", export)
        self.assertNotIn("Set(currentSnapshot.map(", importer)

    def test_game_snapshot_uses_existing_corruption_checked_loader(self):
        snapshot = section(GAME_STORE, "    func validatedSnapshot()", "    @discardableResult")
        self.assertIn("readableGames()", snapshot)


if __name__ == "__main__":
    unittest.main()
