import unittest
from pathlib import Path


class CustomOSImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]

    def test_library_import_persists_os_image_for_launch_setup(self):
        library = (self.root / "iSteam" / "LibraryViewController.swift").read_text(encoding="utf-8")
        self.assertIn('UserDefaults.standard.set(destination.path, forKey: "iSteam.customOSPath")', library)
        self.assertIn("Launch Setup automatically preselects it as boot media", library)

    def test_launch_setup_preselects_only_existing_regular_image(self):
        launch = (self.root / "iSteam" / "LaunchSetupViewController.swift").read_text(encoding="utf-8")
        self.assertIn('UserDefaults.standard.string(forKey: "iSteam.customOSPath")', launch)
        self.assertIn("url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])", launch)
        self.assertIn("values?.isRegularFile == true", launch)
        self.assertIn("(values?.fileSize ?? 0) > 0", launch)
        self.assertIn("selectedDiskURL = url", launch)
        self.assertIn("Imported OS image preselected", launch)
        self.assertIn('UserDefaults.standard.removeObject(forKey: "iSteam.customOSPath")', launch)


if __name__ == "__main__":
    unittest.main()
