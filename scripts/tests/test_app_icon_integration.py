import json
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARCHIVES = {
    "AkatsubakiDefault": "Akatsubaki emu default icon .icon.zip",
    "AkatsubakiHaloPetals": "Akatsubaki emu halo-petals icon.icon.zip",
    "AkatsubakiPetals": "Akatsubaki emu petals icon .icon.zip",
    "AkatsubakiSimple": "Akatsubaki emu simple icon .icon.zip",
}


class AppIconIntegrationTests(unittest.TestCase):
    def test_icon_composer_archives_are_complete(self):
        for icon_name, archive_name in ARCHIVES.items():
            with self.subTest(icon=icon_name):
                archive_path = ROOT / "Icons" / archive_name
                self.assertTrue(archive_path.is_file(), archive_path)
                with zipfile.ZipFile(archive_path) as archive:
                    self.assertIsNone(archive.testzip())
                    metadata = json.loads(archive.read("Untitled.icon/icon.json"))
                    referenced = {
                        layer["image-name"]
                        for group in metadata.get("groups", [])
                        for layer in group.get("layers", [])
                    }
                    for image_name in referenced:
                        self.assertIn(f"Untitled.icon/Assets/{image_name}", archive.namelist())

    def test_project_selects_channel_specific_primary_icons(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME: AkatsubakiDefault", project)
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME: AkatsubakiSimple", project)
        self.assertIn("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES:", project)
        self.assertIn("INFOPLIST_KEY_AkatsubakiPrimaryIconName: AkatsubakiDefault", project)
        self.assertIn("INFOPLIST_KEY_AkatsubakiPrimaryIconName: AkatsubakiSimple", project)

    def test_settings_expose_all_four_icons_and_apply_system_icon(self):
        settings = (ROOT / "iSteam/SettingsViewController.swift").read_text(encoding="utf-8")
        for icon_name in ARCHIVES:
            self.assertIn(icon_name, settings)
        self.assertIn("UIApplication.shared.setAlternateIconName(alternateName)", settings)
        self.assertIn("UIApplication.shared.alternateIconName", settings)

    def test_release_workflow_prepares_icons_before_project_generation(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/prepare-app-icons.sh", workflow)
        self.assertLess(workflow.index("bash scripts/prepare-app-icons.sh"), workflow.index("xcodegen generate --spec project.yml"))
        self.assertIn('EXPECTED_PRIMARY_ICON="AkatsubakiDefault"', workflow)
        self.assertIn('EXPECTED_PRIMARY_ICON="AkatsubakiSimple"', workflow)
        self.assertIn("CFBundleAlternateIcons", workflow)

    def test_all_xcodegen_build_paths_prepare_icon_composer_files(self):
        for workflow_path in (
            ".github/workflows/validate-ios-build.yml",
            ".github/workflows/build-core-only-ios.yml",
            "scripts.sh",
        ):
            with self.subTest(path=workflow_path):
                build_workflow = (ROOT / workflow_path).read_text(encoding="utf-8")
                self.assertIn("bash scripts/prepare-app-icons.sh", build_workflow)
                self.assertLess(
                    build_workflow.index("bash scripts/prepare-app-icons.sh"),
                    build_workflow.index("xcodegen generate"),
                )

    def test_extraction_script_uses_expected_archive_names(self):
        script = (ROOT / "scripts/prepare-app-icons.sh").read_text(encoding="utf-8")
        for archive_name in ARCHIVES.values():
            self.assertIn(archive_name, script)
        self.assertIn('unzip -tq', script)
        self.assertIn('mv "$source_icon" "$DEST_DIR/$icon_name.icon"', script)


if __name__ == "__main__":
    unittest.main()
