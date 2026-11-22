import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PairingGenerationTests(unittest.TestCase):
    def test_rust_engine_uses_idevice_remote_pairing_and_safe_pin_callback(self):
        cargo = (ROOT / "pairing-ffi" / "Cargo.toml").read_text()
        source = (ROOT / "pairing-ffi" / "src" / "lib.rs").read_text()
        self.assertIn('features = ["remote_pairing", "aws-lc"]', cargo)
        self.assertIn('"time"', cargo)
        self.assertIn("PairableHostInfo::generate", source)
        self.assertIn("PairableHost::new", source)
        self.assertRegex(source, r"host\\.accept\\(&mut pairing,?\\s*pin_cb\\)")
        self.assertIn("write_to_file(&out)", source)
        self.assertIn("PAIRABLE_HOST_SERVICE_TYPE", source)
        self.assertIn('pin.ok_or("Missing pairing PIN callback")', source)
        self.assertIn("pin_callback(ctx,p.as_ptr())", source)
        self.assertNotIn("pin.ok_or(()).unwrap()", source)

    def test_pairing_storage_matches_jit_and_is_protected(self):
        source = (ROOT / "iSteam" / "StikJITPairingFileStore.swift").read_text()
        self.assertIn('support.appendingPathComponent("pairingFile.plist")', source)
        self.assertIn('support.appendingPathComponent("host-identity.plist")', source)
        self.assertIn(".completeFileProtection", source)
        self.assertIn("isExcludedFromBackup", source)
        self.assertIn("static func reset()", source)
        self.assertNotIn(".documentDirectory", source)

    def test_swift_coordinator_advertises_and_replaces_pairing_identity(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        self.assertIn('_remotepairing-pairable-host._tcp.', source)
        self.assertIn("NetService.data(fromTXTRecord:txt)", source)
        self.assertIn("akatsubaki_pairing_run", source)
        self.assertIn("BGContinuedProcessingTaskRequest", source)
        self.assertIn("StikJITPairingFileStore.save", source)
        self.assertIn("StikJITPairingFileStore.reset()", source)
        self.assertIn("akatsubaki_pairing_session_cancel", source)

    def test_app_and_info_register_continued_pairing_task(self):
        app = (ROOT / "iSteam" / "AppDelegate.swift").read_text()
        self.assertIn("StikPairingCoordinator.shared.registerBackgroundTask()", app)
        with (ROOT / "iSteam" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertIn("_remotepairing-pairable-host._tcp", info["NSBonjourServices"])
        self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*", info["BGTaskSchedulerPermittedIdentifiers"])
        self.assertIn("processing", info["UIBackgroundModes"])

    def test_xcode_links_static_pairing_xcframework(self):
        project = (ROOT / "project.yml").read_text()
        self.assertEqual(project.count("build/dependencies/AkatsubakiPairingFFI.xcframework"), 2)
        modulemap = (ROOT / "pairing-ffi" / "include" / "module.modulemap").read_text()
        self.assertIn("module AkatsubakiPairingFFI", modulemap)

    def test_build_runs_rust_tests_and_both_apple_targets(self):
        build = (ROOT / "scripts" / "build_stikpair_ffi.sh").read_text()
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text()
        validation = (ROOT / ".github" / "workflows" / "validate-ios-build.yml").read_text()
        self.assertIn("rustup component add rustfmt", build)
        self.assertIn("cargo fmt --manifest-path", build)
        self.assertIn("cargo test --manifest-path", build)
        self.assertIn("aarch64-apple-ios", build)
        self.assertIn("aarch64-apple-ios-sim", build)
        self.assertIn("xcodebuild -create-xcframework", build)
        self.assertIn("run: bash scripts/build_stikpair_ffi.sh", release)
        self.assertIn("run: bash scripts/build_stikpair_ffi.sh", validation)

    def test_settings_exposes_pairing_generation_and_import(self):
        source = (ROOT / "iSteam" / "SettingsViewController.swift").read_text()
        self.assertIn("StikPairingCoordinator.shared.startPairing(from: self)", source)
        self.assertIn('c.text = "Import existing pairing file"', source)
        self.assertIn("canGeneratePairingFile", source)
        self.assertIn("Application Support/StikJIT/pairingFile.plist", source)


if __name__ == "__main__":
    unittest.main()
