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
        self.assertRegex(source, r"host\.accept\(&mut pairing,?\s*pin_cb\)")
        self.assertIn("write_to_file(&out)", source)
        self.assertIn("PAIRABLE_HOST_SERVICE_TYPE", source)
        self.assertIn('pin.ok_or("Missing pairing PIN callback")', source)
        self.assertIn("pin_callback(callback_context as *mut c_void, p.as_ptr())", source)
        self.assertNotIn("pin.ok_or(()).unwrap()", source)

    def test_pairing_storage_matches_jit_and_is_protected(self):
        source = (ROOT / "iSteam" / "StikJITPairingFileStore.swift").read_text()
        self.assertIn('support.appendingPathComponent("pairingFile.plist")', source)
        self.assertIn('support.appendingPathComponent("host-identity.plist")', source)
        self.assertIn(".completeFileProtection", source)
        self.assertIn("isExcludedFromBackup", source)
        self.assertIn("static func reset()", source)
        self.assertNotIn(".documentDirectory", source)

    def test_swift_coordinator_advertises_and_refreshes_pairing_identity_without_deleting_it(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        self.assertIn('_remotepairing-pairable-host._tcp.', source)
        self.assertIn("NetService.data(fromTXTRecord:txt)", source)
        self.assertIn("akatsubaki_pairing_run", source)
        self.assertIn("BGContinuedProcessingTaskRequest", source)
        self.assertIn("StikJITPairingFileStore.save", source)
        self.assertNotIn("StikJITPairingFileStore.reset()", source)
        self.assertIn("akatsubaki_pairing_session_cancel", source)

    def test_session_handle_is_freed_only_after_worker_returns_on_main_queue(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        main_dispatch = source.index("DispatchQueue.main.async { [weak self] in")
        session_clear = source.index("self?.session = nil", main_dispatch)
        session_free = source.index("akatsubaki_pairing_session_free(handle)", main_dispatch)
        result_free = source.index("akatsubaki_pairing_result_free(&result)")
        self.assertLess(result_free, main_dispatch)
        self.assertLess(session_clear, session_free)
        self.assertNotIn("akatsubaki_pairing_session_free(handle);DispatchQueue.main.async", source)

    def test_refresh_keeps_existing_pairing_until_success(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        start_pairing = source.split("func startPairing", 1)[1].split("func applicationDidBecomeActive", 1)[0]
        self.assertIn("keeps this iPad's existing host identity", start_pairing)
        self.assertNotIn("StikJITPairingFileStore.reset()", start_pairing)

    def test_pairing_uses_empty_host_udid(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        self.assertIn('let udid = ""', source)

    def test_failed_pairing_cleans_pending_file(self):
        source = (ROOT / "iSteam" / "StikPairingCoordinator.swift").read_text()
        self.assertIn("if !ok, let pendingFileURL", source)
        self.assertIn("StikJITPairingFileStore.cleanPending(pendingFileURL)", source)

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

    def test_pairing_path_is_consistent_across_app_and_documentation(self):
        settings = (ROOT / "iSteam" / "SettingsViewController.swift").read_text()
        store = (ROOT / "iSteam" / "StikJITPairingFileStore.swift").read_text()
        expected = "Application Support/StikJIT/pairingFile.plist"
        self.assertIn(expected, settings)
        self.assertIn('appendingPathComponent("StikJIT"', store)
        for path in ("README.md", "docs/JIT_ACTIVATION.md", "docs/PAIRING_GENERATION.md"):
            document = (ROOT / path).read_text()
            with self.subTest(path=path):
                self.assertIn(expected, document)
                self.assertNotIn("Documents/StikJIT/pairingFile.plist", document)

    def test_settings_exposes_pairing_generation_and_import(self):
        source = (ROOT / "iSteam" / "SettingsViewController.swift").read_text()
        self.assertIn("StikPairingCoordinator.shared.startPairing(from: self)", source)
        self.assertIn('c.text = "Import existing pairing file"', source)
        self.assertIn("canGeneratePairingFile", source)
        self.assertIn("Application Support/StikJIT/pairingFile.plist", source)


if __name__ == "__main__":
    unittest.main()
