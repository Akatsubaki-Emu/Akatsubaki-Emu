from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class QEMUAccelerationSettingsTests(unittest.TestCase):
    def test_jit_and_tci_options_require_their_packaged_runtime(self):
        source = (ROOT / "src/Core/RuntimeSettings.swift").read_text(encoding="utf-8")
        self.assertIn("QEMURuntimeStatus.locate(requiresJIT: true)", source)
        self.assertIn("QEMURuntimeStatus.locate(requiresJIT: false)", source)
        self.assertIn("case .automatic:", source)
        self.assertIn("case .hypervisor:", source)

    def test_automatic_mode_falls_back_but_explicit_jit_does_not(self):
        source = (ROOT / "iSteam/LaunchSetupViewController.swift").read_text(encoding="utf-8")
        self.assertIn("let permitsTCIFallback = RuntimeSettings.shared.acceleration == .automatic", source)
        self.assertIn("guard permitsTCIFallback else", source)
        self.assertIn("fallbackConfiguration.accelerator = .tcg", source)
        self.assertIn("does not fall back to TCI", source)

    def test_device_compatibility_reports_the_real_tci_load_probe(self):
        source = (ROOT / "iSteam/SettingsViewController.swift").read_text(encoding="utf-8")
        self.assertIn("QEMURuntimeStatus.inspect(requiresJIT: false)", source)
        self.assertIn("passed the library-load/export probe", source)
        self.assertIn("No-JIT QEMU TCI is unavailable in this build", source)


if __name__ == "__main__":
    unittest.main()
