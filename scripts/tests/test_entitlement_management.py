import unittest
from pathlib import Path


class EntitlementManagementSourceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.view = (self.root / "iSteam" / "EntitlementSettingsView.swift").read_text(encoding="utf-8")
        self.settings = (self.root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.project = (self.root / "project.yml").read_text(encoding="utf-8")
        self.entitlements = (self.root / "iSteam" / "iSteam.entitlements").read_text(encoding="utf-8")

    def test_only_the_current_bundle_id_is_modified(self):
        self.assertIn("$0.bundleIdentifier == bundleIdentifier", self.view)
        self.assertIn('capabilities: ["INCREASED_MEMORY_LIMIT"]', self.view)
        self.assertIn("No App ID for \\(bundleIdentifier) was found", self.view)

    def test_uses_stossign_authentication_and_developer_api(self):
        self.assertIn("AnisetteDataHelper.shared.getAnisetteData()", self.view)
        self.assertIn("AppleAPI.shared.authenticate", self.view)
        self.assertIn("AppleAPI.shared.fetchAppIDsForTeam", self.view)
        self.assertIn("AppleAPI.shared.updateAppID", self.view)
        self.assertIn("prepareForVerification(using:", self.view)

    def test_reinstall_is_required_after_capability_change(self):
        self.assertIn("Reinstall this app through SideStore or AltStore", self.view)
        self.assertIn("cannot update its own code signature", self.view)

    def test_no_password_is_written_to_user_defaults(self):
        self.assertNotIn("UserDefaults.standard.set(password", self.view)
        self.assertNotIn("appleIDPassword", self.view)
        keychain = (self.root / "iSteam" / "Keychain.swift").read_text(encoding="utf-8")
        self.assertNotIn("appleIDPassword", keychain)
        self.assertNotIn("patreon", keychain.lower())

    def test_settings_exposes_entitlement_screen(self):
        self.assertIn("case 6, 7, 8, 9, 10, 11: return 1", self.settings)
        self.assertIn("case 11:", self.settings)
        self.assertIn('"Entitlements"', self.settings)
        self.assertIn("EntitlementSettingsView()", self.settings)

    def test_stossign_is_attached_to_all_targets_that_compile_its_sources(self):
        self.assertEqual(self.project.count("product: StosSign_API"), 3)
        self.assertEqual(self.project.count("product: StosSign_Auth"), 3)
        self.assertEqual(self.project.count("product: StosSign_Common"), 3)
        vision = self.project.split("  iSteamVision:", 1)[1]
        self.assertNotIn("EntitlementSettingsView.swift", vision.split("    settings:", 1)[0])

    def test_anisette_dependencies_are_present_and_initialized_before_use(self):
        shared = (self.root / "iSteam" / "Shared.swift").read_text(encoding="utf-8")
        keychain = (self.root / "iSteam" / "Keychain.swift").read_text(encoding="utf-8")
        anisette = (self.root / "iSteam" / "AnisetteDataHelper.swift").read_text(encoding="utf-8")
        self.assertIn("class DataManager", shared)
        self.assertIn("AnisetteDataHelper.shared.url = URL(string: anisetteServerURL)", shared)
        self.assertIn("class Keychain", keychain)
        self.assertIn("class AnisetteDataHelper", anisette)
        self.assertIn("import Security", anisette)
        self.assertIn("_ = DataManager.shared.model", self.view)
        self.assertLess(self.view.index("_ = DataManager.shared.model"), self.view.index("AnisetteDataHelper.shared.getAnisetteData()"))

    def test_anisette_sensitive_headers_are_not_written_to_logs(self):
        anisette = (self.root / "iSteam" / "AnisetteDataHelper.swift").read_text(encoding="utf-8")
        for token in ["Anisette used:", "Original JSON:", "X-Apple-I-MD-LU:", "X-Mme-Device-Id:"]:
            self.assertNotIn(token, anisette)
        self.assertIn("sensitive headers redacted", anisette)

    def test_existing_memory_entitlement_declarations_are_preserved(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", self.entitlements)
        self.assertIn("com.apple.developer.kernel.extended-virtual-addressing", self.entitlements)


if __name__ == "__main__":
    unittest.main()
