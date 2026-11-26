import unittest
from pathlib import Path


class QEMUJITPolicyTests(unittest.TestCase):
    def test_physical_ios_runtime_falls_back_to_tci_when_jit_is_unavailable(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        gate = runtime.split(
            "#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)",
            1,
        )[1].split("#endif", 1)[0]
        self.assertIn("if requiresJIT && !JITCoordinator.shared.isQEMUJITReady", gate)
        self.assertIn("requiresJIT = false", gate)
        self.assertIn("var runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)", runtime)
        self.assertIn("runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: false)", runtime)
        self.assertIn("QEMU JIT is unavailable; falling back to the TCI no-JIT runtime.", runtime)
        self.assertNotIn("The no-JIT TCI runtime is not packaged yet", runtime)
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("return isStikDebugAvailable && hasGetTaskAllow && isQEMUProtocolAvailable && isJITReady", coordinator)

    def test_display_retries_automatic_tci_fallback_if_jit_is_lost_at_launch(self):
        root = Path(__file__).resolve().parents[2]
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn("startTCIFallbackIfAllowed(reason: JITCoordinator.shared.unavailableReason)", display)
        self.assertIn("RuntimeSettings.shared.acceleration.allowsTCIFallback", display)
        self.assertIn("QEMURuntimeStatus.inspect(requiresJIT: false)", display)
        self.assertIn("case .ready:", display)
        self.assertIn("case .unavailable(let tciReason):", display)
        self.assertIn("self?.startTCIFallbackIfAllowed(reason: message)", display)
        self.assertIn("guard RuntimeSettings.shared.acceleration.allowsTCIFallback else", display)

    def test_tci_is_selectable_and_legacy_tci_values_are_preserved(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        ui = (root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.assertIn("case .automatic, .qemuJIT, .qemuInterpreter: return true", settings)
        self.assertIn("return stored.isAvailable ? stored : .automatic", settings)
        self.assertIn("experimental TCTI", settings)
        self.assertIn("threaded-dispatch TCG bytecode", settings)
        self.assertIn("if mode.isAvailable", ui)
        self.assertIn("guard mode.isAvailable else { return }", ui)
        self.assertIn("experimental TCTI", ui)
        self.assertNotIn("the no-JIT TCI runtime is not packaged yet", ui)

    def test_build_documentation_describes_both_runtime_variants_without_claiming_a_boot(self):
        root = Path(__file__).resolve().parents[2]
        docs = (root / "docs" / "QEMU_BUILD_WORKFLOW.md").read_text(encoding="utf-8")
        self.assertIn("ios-tci", docs)
        self.assertIn("QEMU/TCI", docs)
        self.assertIn("experimental TCTI", docs)
        self.assertIn("--enable-tcg-threaded-interpreter", docs)
        self.assertIn("physical-device startup have not yet been recorded", docs)
        self.assertNotIn("Only the JIT-backed QEMU runtime is currently built and packaged.", docs)


if __name__ == "__main__":
    unittest.main()
