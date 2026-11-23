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
        self.assertIn("Select QEMU TCI (no JIT)", gate)
        self.assertLess(
            runtime.index("guard JITCoordinator.shared.isQEMUJITReady else"),
            runtime.index("switch QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)"),
        )
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn(
            "return isStikDebugAvailable && hasGetTaskAllow && isQEMUProtocolAvailable && isJITReady",
            coordinator,
        )

    def test_tci_is_offered_and_retired_accelerators_migrate_to_tci(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        ui = (root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        self.assertIn("case .automatic, .qemuJIT, .qemuInterpreter: return true", settings)
        self.assertIn("case .hypervisor: return false", settings)
        self.assertIn("return stored.isAvailable ? stored : .qemuInterpreter", settings)
        self.assertIn("Threaded TCG interpreter (TCI); does not require executable-memory JIT", settings)
        self.assertIn("if mode.isAvailable", ui)
        self.assertIn("guard mode.isAvailable else { return }", ui)
        self.assertIn("QEMU TCI interpreter runs without executable-memory JIT", ui)

    def test_build_documentation_describes_both_packaged_runtime_modes(self):
        root = Path(__file__).resolve().parents[2]
        docs = (root / "docs" / "QEMU_BUILD_WORKFLOW.md").read_text(encoding="utf-8")
        self.assertIn("runtime workflow builds and packages both the native TCG/JIT archive and the no-JIT `iOS-TCI` archive", docs)
        self.assertIn("separate `QEMU/JIT` and `QEMU/TCI` manifests", docs)
        self.assertIn("Settings exposes it as an explicit choice", docs)


    def test_release_workflow_validates_and_embeds_both_qemu_modes(self):
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        merge = (root / "scripts" / "merge-qemu-runtime-variants.sh").read_text(encoding="utf-8")
        for token in (
            'TCI_RUNTIME_DIR="$RUNTIME_DIR/QEMU/TCI"',
            'test -s "$TCI_RUNTIME_DIR/runtime-library-path.txt"',
            'test -s "$TCI_RUNTIME_DIR/exports.txt"',
            'TCI_RUNTIME_REL="$(head -n 1 "$TCI_RUNTIME_DIR/runtime-library-path.txt")"',
            'test -s "$RUNTIME_DIR/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/TCI/runtime-library-path.txt"',
            'test -s "$APP/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/TCI/exports.txt"',
        ):
            self.assertIn(token, release)
        self.assertIn('cp "$JIT_DIR/QEMU/runtime-library-path.txt" "$TEMP_OUT/QEMU/runtime-library-path.txt"', merge)


if __name__ == "__main__":
    unittest.main()
