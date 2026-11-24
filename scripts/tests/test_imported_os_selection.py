from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ImportedOSSelectionTests(unittest.TestCase):
    def test_imported_os_image_is_preselected_in_launch_setup(self) -> None:
        source = (ROOT / "iSteam" / "LaunchSetupViewController.swift").read_text(encoding="utf-8")
        self.assertIn("restoreImportedOperatingSystem()", source)
        self.assertIn('UserDefaults.standard.string(forKey: "iSteam.customOSPath")', source)
        self.assertIn("selectedDiskURL = url", source)
        self.assertIn("values.isRegularFile == true", source)
        self.assertIn("values.fileSize", source)
        self.assertIn("Boot media:", source)

    def test_import_action_persists_image_and_explains_boot_requirements(self) -> None:
        source = (ROOT / "iSteam" / "LibraryViewController.swift").read_text(encoding="utf-8")
        self.assertIn('UserDefaults.standard.set(destination.path, forKey: "iSteam.customOSPath")', source)
        self.assertIn("Launch Setup will preselect it as boot media", source)
        self.assertIn("compatible bundled QEMU runtime and UEFI firmware are required", source)
        self.assertNotIn("The current VM engine does not yet boot imported ISO/disk images", source)


if __name__ == "__main__":
    unittest.main()
