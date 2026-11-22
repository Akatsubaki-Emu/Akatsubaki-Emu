import unittest
from pathlib import Path


class GameStoreImportFailureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.store = (root / "iSteam" / "GameStore.swift").read_text(encoding="utf-8")
        cls.library = (root / "iSteam" / "LibraryViewController.swift").read_text(encoding="utf-8")

    def test_add_returns_the_library_persistence_result(self):
        method = self.store.split("func add(_ game:", 1)[1].split("func update", 1)[0]
        self.assertIn("@discardableResult\n    func add(_ game: GameEntry) -> Bool", self.store)
        self.assertIn("return save(current)", method)

    def test_failed_import_removes_the_staged_executable_and_reports_failure(self):
        import_flow = self.library.split("let gameDir = dir.appendingPathComponent", 1)[1].split(
            'showMessage("Game imported"', 1
        )[0]
        self.assertIn("var keepGameDirectory = false", import_flow)
        self.assertIn("if !keepGameDirectory { try? fm.removeItem(at: gameDir) }", import_flow)
        self.assertIn("guard GameStore.shared.add(entry) else", import_flow)
        self.assertIn("keepGameDirectory = true", import_flow)


if __name__ == "__main__":
    unittest.main()
