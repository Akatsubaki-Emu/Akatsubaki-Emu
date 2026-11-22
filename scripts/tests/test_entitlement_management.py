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

    def test_uses_getmoreram_stossign_developer_api(self):
        self.assertIn("AnisetteDataHelper.shared.getAnisetteData()", self.view)
        self.assertIn("AppleAPI.shared.authenticate", self.view)
        self.assertIn("AppleAPI.shared.fetchTeamsForAccount", self.view)
        self.assertIn("AppleAPI.shared.fetchAppIDsForTeam", self.view)
        self.assertIn("AppleAPI.shared.updateAppID", self.view)
        self.assertIn("prepareForVerification(using:", self.view)
        self.assertIn("await self.prepareForVerification", self.view)

    def test_anisette_helper_is_vendored_and_uses_secure_device_state(self):
        self.assertIn("class AnisetteDataHelper", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.loadIdentifier()", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.loadAdiPb()", self.anisette)
        self.assertNotRegex(self.anisette, r"(?<!EntitlementAnisette)Keychain\.shared\.")
        self.assertIn("SecItemCopyMatching", self.keychain)
        self.assertIn("SecItemAdd", self.keychain)
        self.assertIn("kSecAttrSynchronizable", self.keychain)


    def test_anisette_helper_does_not_log_auth_material_and_uses_safe_load(self):
        self.assertNotIn("loggingFunc", self.anisette)
        self.assertNotIn("print(text!)", self.anisette)
        self.assertIn("decoded.count == 16", self.anisette)
        self.assertIn("UUID(uuid:", self.anisette)
        self.assertNotIn("decoded.object()", self.anisette)

    def test_anisette_server_is_https_and_configurable(self):
        self.assertIn('?? "https://ani.sidestore.io"', self.view)
        self.assertIn('anisetteURL.scheme?.lowercased() == "https"', self.view)
        self.assertIn('UserDefaults.standard.set(configuredURL, forKey: "iSteam.anisetteServerURL")', self.view)

    def test_anisette_secrets_are_not_logged(self):
        for sensitive_log in (
            "Anisette used:",
            "Original JSON:",
            "X-Apple-I-MD-LU:",
            "X-Mme-Device-Id:",
            "Got response:",
        ):
            self.assertNotIn(sensitive_log, self.anisette)

    def test_reinstall_is_required_after_capability_change(self):
        self.assertIn("Reinstall this app through SideStore or AltStore", self.view)
        self.assertIn("cannot update its own code signature", self.view)

    def test_no_password_is_persisted(self):
        self.assertNotIn("UserDefaults.standard.set(password", self.view)
        self.assertNotIn("appleIDPassword", self.view)
        self.assertIn('password = ""', self.view)
        self.assertNotIn("DataManager.shared", self.view)

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
        self.assertIn("AnisetteDataHelper.swift", vision)
        self.assertIn("EntitlementAnisetteKeychain.swift", vision)
        self.assertIn("EntitlementSettingsView.swift", vision)

    def test_existing_memory_entitlement_declarations_are_preserved(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", self.entitlements)
        self.assertIn("com.apple.developer.kernel.extended-virtual-addressing", self.entitlements)


    def test_anisette_v3_timestamp_uses_utc(self):
        self.assertIn('formatter.timeZone = TimeZone(identifier: "UTC")', self.anisette)

    def test_anisette_refresh_discards_cached_provisioning_data(self):
        self.assertIn("if refresh", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.clearAdiPb()", self.anisette)

    def test_anisette_identity_is_device_local_and_keychain_failures_are_reported(self):
        self.assertIn("kSecAttrSynchronizable as String: kCFBooleanFalse as Any", self.keychain)
        self.assertIn("kSecAttrSynchronizableAny", self.keychain)
        self.assertIn("throw KeychainError.deleteFailed(deleteStatus)", self.keychain)
        self.assertIn("throw KeychainError.storeFailed(addStatus)", self.keychain)

    def test_anisette_helper_avoids_unsafe_force_unwraps(self):
        for unsafe in ("self.url!", "identifier!", "adiPb!", "clientInfo!", "userAgent!",
                       "self.mdLu!", "self.deviceId!", "startProvisioningURL!",
                       "endProvisioningURL!", "try!", "decoded.object()"):
            with self.subTest(unsafe=unsafe):
                self.assertNotIn(unsafe, self.anisette)

    def test_cached_anisette_state_is_reloaded_after_identifier_validation(self):
        self.assertIn("func fetchAnisetteV3() async throws", self.anisette)
        self.assertNotIn("fetchAnisetteV3(identifier, adiPb)", self.anisette)
        self.assertIn("try await fetchClientInfo()", self.anisette)
        self.assertIn("EntitlementAnisetteKeychain.shared.loadAdiPb()", self.anisette)



if __name__ == "__main__":
    unittest.main()
