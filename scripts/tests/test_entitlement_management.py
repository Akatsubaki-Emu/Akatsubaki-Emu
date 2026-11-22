import unittest
from pathlib import Path


class EntitlementManagementSourceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.view = (self.root / "iSteam" / "EntitlementSettingsView.swift").read_text(encoding="utf-8")
        self.anisette = (self.root / "iSteam" / "AnisetteDataHelper.swift").read_text(encoding="utf-8")
        self.keychain = (self.root / "iSteam" / "EntitlementAnisetteKeychain.swift").read_text(encoding="utf-8")
        self.settings = (self.root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.project = (self.root / "project.yml").read_text(encoding="utf-8")
        self.entitlements = (self.root / "iSteam" / "iSteam.entitlements").read_text(encoding="utf-8")

    def test_only_the_current_bundle_id_is_modified(self):
        self.assertIn("$0.bundleIdentifier == bundleIdentifier", self.view)
        self.assertIn('capabilities: ["INCREASED_MEMORY_LIMIT"]', self.view)
        self.assertIn("No App ID for \\(bundleIdentifier) was found", self.view)

    def test_uses_stossign_authentication_and_developer_api(self):
        self.assertIn("AnisetteDataHelper.shared.getAnisetteData()", self.view)
        self.assertIn("AnisetteDataHelper.shared.url = anisetteURL", self.view)
        self.assertIn('?? "https://ani.sidestore.io"', self.view)
        self.assertIn('anisetteURL.scheme?.lowercased() == "https"', self.view)
        self.assertIn('UserDefaults.standard.set(configuredURL, forKey: "iSteam.anisetteServerURL")', self.view)
        self.assertIn("AppleAPI.shared.authenticate", self.view)
        self.assertIn("AppleAPI.shared.fetchAppIDsForTeam", self.view)
        self.assertIn("AppleAPI.shared.updateAppID", self.view)
        self.assertIn("prepareForVerification(using:", self.view)

    def test_anisette_helper_uses_secure_device_state(self):
        self.assertIn("class AnisetteDataHelper", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.identifier", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.adiPb", self.anisette)
        self.assertNotRegex(self.anisette, r"(?<!EntitlementAnisette)Keychain\.shared\.")
        self.assertIn("SecItemCopyMatching", self.keychain)
        self.assertIn("SecItemAdd", self.keychain)

    def test_reinstall_is_required_after_capability_change(self):
        self.assertIn("Reinstall this app through SideStore or AltStore", self.view)
        self.assertIn("cannot update its own code signature", self.view)

    def test_no_password_is_written_to_user_defaults(self):
        self.assertNotIn("UserDefaults.standard.set(password", self.view)
        self.assertNotIn("appleIDPassword", self.view)
        self.assertNotIn("DataManager.shared", self.view)
        self.assertIn('password = ""', self.view)

    def test_anisette_logs_do_not_expose_authentication_material(self):
        for sensitive_log in ("Anisette used:", "Original JSON:", "startProvisioningURL:", "endProvisioningURL:", "Anisette URL:", "Client-Info:", "User-Agent:", "X-Apple-I-MD-LU:", "X-Mme-Device-Id:"):
            self.assertNotIn(sensitive_log, self.anisette)

    def test_anisette_identifier_uses_checked_uuid_construction(self):
        self.assertIn("decoded.count == 16", self.anisette)
        self.assertIn("UUID(uuid:", self.anisette)
        self.assertNotIn("decoded.object()", self.anisette)
        self.assertNotIn("load(as: T.self)", self.anisette)

    def test_anisette_refresh_discards_cached_provisioning_data(self):
        self.assertIn("if refresh { EntitlementAnisetteKeychain.shared.adiPb = nil }", self.anisette)

    def test_anisette_v3_timestamp_uses_utc(self):
        self.assertIn('formatter.timeZone = TimeZone(identifier: "UTC")', self.anisette)

    def test_settings_exposes_entitlement_screen(self):
        self.assertIn("case 6, 7, 8, 9, 10, 11: return 1", self.settings)
        self.assertIn("case 11:", self.settings)
        self.assertIn('"Entitlements"', self.settings)
        self.assertIn("EntitlementSettingsView()", self.settings)

    def test_stossign_is_only_attached_to_ios_targets(self):
        self.assertEqual(self.project.count("product: StosSign_API"), 2)
        self.assertEqual(self.project.count("product: StosSign_Auth"), 2)
        self.assertEqual(self.project.count("product: StosSign_Common"), 2)
        vision = self.project.split("  iSteamVision:", 1)[1]
        self.assertIn("EntitlementSettingsView.swift", vision)
        self.assertIn("AnisetteDataHelper.swift", vision)
        self.assertIn("EntitlementAnisetteKeychain.swift", vision)

    def test_existing_memory_entitlement_declarations_are_preserved(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", self.entitlements)
        self.assertIn("com.apple.developer.kernel.extended-virtual-addressing", self.entitlements)


if __name__ == "__main__":
    unittest.main()
