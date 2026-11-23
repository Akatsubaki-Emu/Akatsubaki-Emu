import unittest
from pathlib import Path


class VMSaveSlotBookmarkRetentionTests(unittest.TestCase):
    def test_unresolved_writable_bookmark_is_not_erased_by_refresh(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Core" / "VMSaveSlotStore.swift").read_text(encoding="utf-8")
        self.assertIn(
            "let canRefreshWritableBookmark = session.writableDiskImageBookmark == nil || writableDiskURL != nil",
            source,
        )
        self.assertIn("if (stale || writableBookmarkStale) && canRefreshWritableBookmark", source)
        self.assertNotIn("session.writableDiskImageBookmark != nil && writableDiskURL == nil", source)


if __name__ == "__main__":
    unittest.main()
