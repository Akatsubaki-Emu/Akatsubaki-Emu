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
        self.assertIn("MSG_NOSIGNAL", bridge)
        self.assertIn("g_has_started = true", bridge)
        self.assertEqual(bridge.count("g_has_started = false;"), 1)  # declaration only; never reset after launch

    def test_native_bridge_rejects_arbitrary_qmp_commands(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        native_test = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn("Invalid QMP socket path or unsupported command", bridge)
        self.assertIn("isteam_qemu_qmp_command", native_test)
        self.assertIn("unsupported command", native_test)

    def test_qmp_uses_a_sandboxed_socket_and_enforces_af_unix_path_limits(self):
        root = Path(__file__).resolve().parents[2]
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        docs = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        native_test = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn('FileManager.default.temporaryDirectory.appendingPathComponent("q.sock").path', builder)
        self.assertIn("guard QEMUCommandBuilder.qmpSocketPath.utf8.count < 104 else", runtime)
        self.assertIn("q.sock", docs)
        self.assertNotIn("/tmp/akatsubaki-qmp.sock", docs)
        self.assertIn("tooLongSocketPath", native_test)
        self.assertIn("sun_path", native_test)

    def test_qmp_socket_path_failure_releases_scoped_resources(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        guard = runtime.split("guard QEMUCommandBuilder.qmpSocketPath.utf8.count < 104 else {", 1)[1].split("let args =", 1)[0]
        cleanup = "newlyScoped.forEach { $0.stopAccessingSecurityScopedResource() }"
        self.assertIn(cleanup, guard)
        self.assertLess(guard.index(cleanup), guard.index("throw RuntimeError.runtimeUnavailable"))

    def test_native_qmp_protocol_exercises_real_socket_handshake_and_replies(self):
        root = Path(__file__).resolve().parents[2]
        native_test = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        for token in ("qmp_test_server", "qmp_capabilities", "query-status",
                      "system_reset", "event_and_reply", "pthread_join"):
            with self.subTest(token=token):
                self.assertIn(token, native_test)

    def test_runtime_reuses_same_configuration_and_rejects_different_guests(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        backend = (root / "src" / "QEMU" / "QEMUBackend.swift").read_text(encoding="utf-8")
        start = runtime.split("func start(", 1)[1].split("private static func containedRegularFile", 1)[0]
        reset = runtime.split("func reset(sessionGeneration", 1)[1].split("func stop(sessionGeneration", 1)[0]
        self.assertIn("static let shared = QEMUNativeRuntime()", runtime)
        self.assertIn("QEMUNativeRuntime.shared", backend)
        self.assertIn("sessionKey == requestedSessionKey", runtime)
        self.assertIn("guard isPaused else", runtime)
        self.assertNotIn('Self.sendQMP("system_reset")', start)
        self.assertIn('Self.sendQMP("cont")', start)
        self.assertIn('Self.sendQMP("system_reset")', reset)
        self.assertIn('Self.sendQMP("stop")', runtime)
        self.assertIn("private(set) var isPaused = false", runtime)
        self.assertIn("private var sessionGeneration: UInt64 = 0", runtime)
        self.assertIn("advanceSessionGeneration()", runtime)
        self.assertIn("guard expected == sessionGeneration else { return true }", runtime)
        self.assertIn("private var sessionGeneration: UInt64?", backend)
        self.assertIn("sessionGeneration = try runtime.start", backend)
        self.assertIn("runtime.stop(sessionGeneration: sessionGeneration)", backend)
        self.assertIn("runtime.isRunning(sessionGeneration: sessionGeneration)", backend)
        self.assertIn("Restart Akatsubaki Emu to switch guests", runtime)

    def test_vm_engine_stops_by_pausing_instead_of_waiting_for_process_exit(self):
        root = Path(__file__).resolve().parents[2]
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        self.assertIn("guard candidate.stop() else", engine)
        self.assertIn("QEMU process retained for repeat launches", engine)
        self.assertIn("if backend?.stop() ?? true", engine)
        self.assertNotIn("restart requires relaunching Akatsubaki Emu", engine)


if __name__ == "__main__":
    unittest.main()
