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


    def test_xcode_27_1_is_pinned_for_the_stikjit_release_framework(self):
        project = self.read("project.yml")
        self.assertIn('xcodeVersion: "27.1"', project)
        for path in (".github/workflows/release.yml", ".github/workflows/validate-ios-build.yml"):
            workflow = self.read(path)
            self.assertIn("runs-on: xcode-27", workflow)
            self.assertIn("/Applications/Xcode_27.1.app", workflow)
            self.assertIn('!= "27.1"', workflow)

    def test_builtin_stikjit_becomes_default_after_pairing_file_import(self):
        coordinator = self.read("iSteam/JITCoordinator.swift")
        settings = self.read("iSteam/SettingsViewController.swift")
        self.assertIn(
            "return isBuiltInStikJITAvailable && hasPairingFile ? .builtInStikJIT : .stikDebug",
            coordinator,
        )
        self.assertIn(
            "Import a StikJIT pairing file before selecting this method.",
            settings,
        )
        self.assertIn(
            "Documents/StikJIT/pairingFile.plist",
            settings,
        )

class StikPairIntegrationTests(unittest.TestCase):
    root=Path(__file__).resolve().parents[2]
    def read(self,p): return (self.root/p).read_text(encoding="utf-8")
    def test_pairing_engine_is_pinned_and_advertises_apple_service(self):
        c=self.read("pairing-ffi/Cargo.toml");r=self.read("pairing-ffi/src/lib.rs")
        self.assertIn("7bd551c16c6dd2e058740d85a2d9399a51a776e9",c)
        self.assertIn("PairableHost::new",r);self.assertIn("mdns_txt_records",r)
    def test_pairing_file_is_protected_and_host_identity_persists(self):
        s=self.read("iSteam/StikJITPairingFileStore.swift")
        self.assertIn(".documentDirectory",s);self.assertIn("FileProtectionType.complete",s);self.assertIn("host-identity.plist",s)
    def test_pairing_requires_physical_ios27_and_wildcard_background_registration(self):
        s=self.read("iSteam/StikPairingCoordinator.swift")
        self.assertIn("if #available(iOS 27.0,*)",s);self.assertIn("targetEnvironment(simulator)",s)
        self.assertIn('prefix+".*"',s);self.assertIn('prefix+"."+UUID().uuidString',s)
    def test_pairing_info_plist_declares_services_and_task_wildcard(self):
        import plistlib
        with (self.root/"iSteam/Info.plist").open("rb") as f: p=plistlib.load(f)
        self.assertIn("_remotepairing-pairable-host._tcp",p["NSBonjourServices"])
        self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*",p["BGTaskSchedulerPermittedIdentifiers"])
    def test_workflows_build_pairing_before_xcodegen(self):
        for p in (".github/workflows/release.yml",".github/workflows/validate-ios-build.yml"):
            s=self.read(p);self.assertLess(s.index("bash scripts/build_stikpair_ffi.sh"),s.index("xcodegen generate --spec project.yml"))
    def test_jit_uses_shared_pairing_file_store(self):
        s=self.read("iSteam/JITCoordinator.swift")
        self.assertIn("StikJITPairingFileStore.hasPairingFile",s);self.assertIn("StikJITPairingFileStore.load()",s)
    def test_pairing_pin_callback_uses_the_callback_function(self):
        rust=self.read("pairing-ffi/src/lib.rs")
        self.assertIn('let pin_callback=pin.ok_or("Missing pairing PIN callback")?;',rust)
        self.assertIn("unsafe{pin_callback(ctx,p.as_ptr())}",rust)
        self.assertNotIn("pin.ok_or(()).unwrap()",rust)


if __name__ == "__main__":
    unittest.main()
