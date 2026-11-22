import unittest
from pathlib import Path


class EmbeddedStikJITIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]

    def read(self, path):
        return (self.root / path).read_text(encoding="utf-8")

    def test_pinned_framework_download_is_sha256_verified(self):
        script = self.read("scripts/fetch_stikjit.sh")
        self.assertIn('VERSION="2.0.1"', script)
        self.assertIn("c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95", script)
        self.assertIn("shasum -a 256 -c", script)
        self.assertIn("StikJIT.xcframework", script)

    def test_release_and_device_validation_fetch_framework_before_xcodegen(self):
        for path in (".github/workflows/release.yml", ".github/workflows/validate-ios-build.yml"):
            workflow = self.read(path)
            self.assertIn("bash scripts/fetch_stikjit.sh", workflow)
            self.assertLess(workflow.index("bash scripts/fetch_stikjit.sh"), workflow.index("xcodegen generate --spec project.yml"))

    def test_extensionkit_helpers_are_ios_26_only(self):
        project = self.read("project.yml")
        self.assertEqual(project.count("type: extensionkit-extension"), 2)
        self.assertEqual(project.count('deploymentTarget: "26.0"'), 2)
        self.assertIn("target: iSteamJITHelper", project)
        self.assertIn("target: iSteamNightlyJITHelper", project)
        self.assertIn("EX_ENABLE_EXTENSION_POINT_GENERATION: YES", project)

    def test_localdevvpn_remains_external_without_unprovisioned_network_extension_entitlements(self):
        info = self.read("iSteam/Info.plist")
        entitlements = self.read("iSteam/iSteam.entitlements")
        docs = self.read("docs/JIT_ACTIVATION.md")
        self.assertIn("<string>localdevvpn</string>", info)
        self.assertNotIn("packet-tunnel-provider", entitlements)
        self.assertIn("Network Extension entitlement", docs)
        self.assertIn("remains a separately installed", docs)

    def test_host_and_helper_share_the_same_extension_point(self):
        host = self.read("iSteam/JITExtensionPoint.swift")
        helper = self.read("iSteamJITHelper/Helper/AkatsubakiJITHelper.swift")
        self.assertIn('Name("AkatsubakiJITHelper")', host)
        self.assertIn('name: "AkatsubakiJITHelper"', helper)
        self.assertIn('host: "com.xthrx.isteam"', helper)
        self.assertIn('host: "com.xthrx.isteam.nightly"', helper)



    def test_late_helper_failure_stops_or_pops_the_guest_display(self):
        launch = self.read("iSteam/LaunchSetupViewController.swift")
        display = self.read("src/Display/VMDisplayViewController.swift")
        self.assertIn("topViewController is VMDisplayViewController", launch)
        self.assertIn("popViewController(animated: true)", launch)
        self.assertIn("func handleJITFailure(_ message: String)", display)
        self.assertIn("vncClient.stop()", display)
        self.assertIn("engine.stop()", display)
        self.assertIn("virtioGPU.stop()", display)

if __name__ == "__main__":
    unittest.main()
