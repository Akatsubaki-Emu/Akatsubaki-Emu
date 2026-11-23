import unittest
from pathlib import Path


class QEMUJITPolicyTests(unittest.TestCase):
    def test_physical_ios_runtime_requires_confirmed_jit_and_fails_closed(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        gate = runtime.split(
            "#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)",
            1,
        )[1].split("#endif", 1)[0]
        self.assertIn("guard JITCoordinator.shared.isQEMUJITReady else", gate)
        self.assertIn("The selected QEMU JIT runtime requires physical iOS 26+", gate)
        self.assertIn("get-task-allow entitlement", gate)
        self.assertIn("supported StikDebug protocol", gate)
        self.assertIn("The no-JIT TCI runtime is packaged but remains unavailable until a physical iOS guest boot is verified", gate)
        self.assertLess(
            runtime.index("guard JITCoordinator.shared.isQEMUJITReady else"),
            runtime.index("switch QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)"),
        )
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn(
            "return isStikDebugAvailable && hasGetTaskAllow && isQEMUProtocolAvailable && isJITReady",
            coordinator,
        )

    def test_unsupported_accelerators_are_not_offered_and_legacy_values_migrate(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        ui = (root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.assertIn("case .qemuInterpreter, .hypervisor: return false", settings)
        self.assertIn("return stored.isAvailable ? stored : .automatic", settings)
        self.assertIn("Unavailable until a physical iOS guest boot validates the packaged no-JIT TCI runtime.", settings)
        self.assertIn("if mode.isAvailable", ui)
        self.assertIn("guard mode.isAvailable else { return }", ui)
        self.assertIn("the no-JIT TCI runtime is packaged but remains unavailable until a physical iOS guest boot is verified", ui)

    def test_build_documentation_records_packaged_but_unverified_tci(self):
        root = Path(__file__).resolve().parents[2]
        docs = (root / "docs" / "QEMU_BUILD_WORKFLOW.md").read_text(encoding="utf-8")
        self.assertIn("Both the JIT-backed and no-JIT TCI runtime variants are built and packaged", docs)
        self.assertIn("Settings UI intentionally keeps TCI unavailable until a physical iOS guest boot", docs)
        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn('TCI_RUNTIME_DIR="$RUNTIME_DIR/QEMU/TCI"', release)
        self.assertIn('test -s "$APP/QEMU/TCI/runtime-library-path.txt"', release)


if __name__ == "__main__":
    unittest.main()
