import unittest
from pathlib import Path


class QEMUPersistentLifecycleTests(unittest.TestCase):
    def test_native_bridge_controls_the_single_process_through_qmp(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        header = (root / "iSteam" / "QEMUNativeBridge.h").read_text(encoding="utf-8")
        self.assertIn("bool isteam_qemu_qmp_command", header)
        self.assertIn("AF_UNIX", bridge)
        self.assertIn("qmp_capabilities", bridge)
        self.assertIn('"stop"', bridge)
        self.assertIn('"cont"', bridge)
        self.assertIn('"system_reset"', bridge)
        self.assertIn("SO_RCVTIMEO", bridge)
        self.assertIn("SO_NOSIGPIPE", bridge)
        self.assertIn("g_has_started = true", bridge)
        self.assertNotIn("g_has_started = false", bridge)

    def test_runtime_reuses_same_configuration_and_rejects_different_guests(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        backend = (root / "src" / "QEMU" / "QEMUBackend.swift").read_text(encoding="utf-8")
        self.assertIn("static let shared = QEMUNativeRuntime()", runtime)
        self.assertIn("QEMUNativeRuntime.shared", backend)
        self.assertIn("sessionKey == requestedSessionKey", runtime)
        self.assertIn('Self.sendQMP("system_reset")', runtime)
        self.assertIn('Self.sendQMP("cont")', runtime)
        self.assertIn('Self.sendQMP("stop")', runtime)
        self.assertIn("private(set) var isPaused = false", runtime)
        self.assertIn("Restart Akatsubaki Emu to switch guests", runtime)

    def test_vm_engine_stops_by_pausing_instead_of_waiting_for_process_exit(self):
        root = Path(__file__).resolve().parents[2]
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        self.assertIn("guard candidate.stop() else", engine)
        self.assertIn("QEMU process retained for repeat launches", engine)
        self.assertNotIn("restart requires relaunching Akatsubaki Emu", engine)


if __name__ == "__main__":
    unittest.main()
