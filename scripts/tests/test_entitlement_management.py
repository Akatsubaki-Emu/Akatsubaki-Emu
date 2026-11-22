import unittest
from pathlib import Path


class EntitlementManagementSourceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.view = (self.root / "iSteam" / "EntitlementSettingsView.swift").read_text(encoding="utf-8")
        self.helper = (self.root / "iSteam" / "AnisetteDataHelper.swift").read_text(encoding="utf-8")
        self.keychain = (self.root / "iSteam" / "EntitlementKeychain.swift").read_text(encoding="utf-8")
        self.settings = (self.root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.project = (self.root / "project.yml").read_text(encoding="utf-8")
        self.entitlements = (self.root / "iSteam" / "iSteam.entitlements").read_text(encoding="utf-8")
        self.docs = (self.root / "docs" / "IOS_ENTITLEMENTS.md").read_text(encoding="utf-8")

    def test_only_the_current_bundle_id_is_modified(self):
        self.assertIn("$0.bundleIdentifier == bundleIdentifier", self.view)
        self.assertIn('capabilities: ["INCREASED_MEMORY_LIMIT"]', self.view)
        self.assertIn("No App ID for \\(bundleIdentifier) was found", self.view)

    def test_stossign_authentication_and_developer_api(self):
        self.assertIn("AppleAPI.shared.authenticate", self.view)
        self.assertIn("AppleAPI.shared.fetchTeamsForAccount", self.view)
        self.assertIn("AppleAPI.shared.fetchAppIDsForTeam", self.view)
        self.assertIn("AppleAPI.shared.updateAppID", self.view)
        self.assertIn("prepareForVerification(using:", self.view)
        self.assertIn("private var session: AppleAPISession?", self.view)
        self.assertNotIn("DataManager.shared", self.view)

    def test_getmoreram_anisette_helper_is_included_and_configurable(self):
        self.assertIn("final class AnisetteDataHelper", self.helper)
        self.assertIn("startProvisioningSession()", self.helper)
        self.assertIn("fetchAnisetteV3", self.helper)
        self.assertIn("EntitlementKeychain.shared.identifier", self.helper)
        self.assertIn("EntitlementKeychain.shared.adiPb", self.helper)
        self.assertIn("AnisetteDataHelper.shared.url = anisetteURL", self.view)
        self.assertIn("https://ani.sidestore.io", self.view)

    def test_only_anisette_provisioning_values_are_stored_in_keychain(self):
        self.assertIn('string(for: "identifier")', self.keychain)
        self.assertIn('string(for: "adiPb")', self.keychain)
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", self.keychain)
        self.assertNotIn("appleIDPassword", self.keychain)
        self.assertNotIn("UserDefaults.standard.set(password", self.view)

    def test_reinstall_is_required_after_capability_change(self):
        self.assertIn("Reinstall or re-provision this app through SideStore or AltStore", self.view)
        self.assertIn("cannot update its own code signature", self.view)

    def test_settings_exposes_entitlement_screen(self):
        self.assertIn("case 6, 7, 8, 9, 10, 11: return 1", self.settings)
        self.assertIn("case 11:", self.settings)
        self.assertIn('\"Entitlements\"', self.settings)
        self.assertIn("EntitlementSettingsView()", self.settings)

    def test_stossign_dependencies_are_limited_to_ios_targets(self):
        self.assertEqual(self.project.count("product: StosSign_API"), 2)
        self.assertEqual(self.project.count("product: StosSign_Auth"), 2)
        self.assertEqual(self.project.count("product: StosSign_Common"), 2)
        vision = self.project.split("  iSteamVision:", 1)[1]
        self.assertIn("EntitlementSettingsView.swift", vision)
        self.assertNotIn("dependencies:", vision)

    def test_existing_memory_entitlement_declarations_are_preserved(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", self.entitlements)
        self.assertIn("com.apple.developer.kernel.extended-virtual-addressing", self.entitlements)

    def test_documentation_has_clean_markdown_and_security_limits(self):
        self.assertNotIn(chr(92) + chr(96), self.docs)
        self.assertIn("GetMoreRam", self.docs)
        self.assertIn("INCREASED_MEMORY_LIMIT", self.docs)
        self.assertIn("provisioning profile", self.docs)


if __name__ == "__main__":
    unittest.main()
