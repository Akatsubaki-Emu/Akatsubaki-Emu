import unittest
from pathlib import Path


class QEMURuntimePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]

    def read(self, *parts):
        return (self.root.joinpath(*parts)).read_text(encoding="utf-8")

    def test_jit_gate_only_applies_to_explicit_jit_runtime(self):
        runtime = self.read("src", "QEMU", "QEMUNativeRuntime.swift")
        self.assertIn("if requiresJIT && !JITCoordinator.shared.isQEMUJITReady", runtime)
        self.assertIn("Select QEMU TCI (no JIT)", runtime)
        self.assertIn("QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)", runtime)

    def test_automatic_accelerator_falls_back_to_tci(self):
        config = self.read("src", "Core", "VMConfiguration.swift")
        settings = self.read("src", "Core", "RuntimeSettings.swift")
        status = self.read("src", "QEMU", "QEMURuntimeStatus.swift")
        self.assertIn("JITCoordinator.shared.isQEMUJITReady ? .jit : .tcg", config)
        self.assertIn("QEMURuntimeStatus.isPackaged(requiresJIT: false)", settings)
        self.assertIn("static func isPackaged(bundle: Bundle = .main, requiresJIT: Bool = true)", status)

    def test_tci_build_uses_upstream_scheme_product_and_skips_jit_patch(self):
        workflow = self.read(".github", "workflows", "build-qemu-runtime.yml")
        tci_step = workflow.split("Build UTM TCI dependencies", 1)[1].split("Build UTM iOS archive", 1)[0]
        self.assertIn("./scripts/build_dependencies.sh -p ios-tci -a arm64", tci_step)
        self.assertNotIn("ISTEAM_QEMU_JIT_PATCHER", tci_step)
        self.assertIn("./scripts/build_utm.sh -k iphoneos -s iOS-SE -a arm64", workflow)
        self.assertIn("UTMBuildTCI.xcarchive/Products/Applications/UTM SE.app", workflow)
        patcher = self.read("scripts", "patch_utm_qemu_ios.py")
        self.assertIn('if [ "$PLATFORM" = "ios" ]; then', patcher)
        self.assertIn("is required for JIT builds", patcher)

    def test_tci_packaging_and_final_ipa_reject_jit_callback(self):
        package = self.read("scripts", "package-utm-qemu-runtime.sh")
        release = self.read(".github", "workflows", "release.yml")
        validator = self.read("scripts", "validate-apple-package.sh")
        self.assertIn('tci) APP="$ARCHIVE/Products/Applications/UTM SE.app" ;;', package)
        self.assertIn('if grep -Eq \' _?isteam_qemu_set_jit_callbacks$\' "$TCI_EXPORTS"; then', release)
        self.assertIn('validate_runtime_variant "TCI"', validator)
        self.assertIn("TCI runtime unexpectedly exports the JIT callback", validator)

    def test_capability_probe_checks_both_variants(self):
        registry = self.read("src", "Runtime", "RuntimeCapabilityRegistry.swift")
        self.assertIn("requiresJIT: true", registry)
        self.assertIn("requiresJIT: false", registry)
        self.assertIn("jitReady || tciReady", registry)


if __name__ == "__main__":
    unittest.main()
