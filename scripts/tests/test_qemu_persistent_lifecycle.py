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
        self.assertIn('"system_powerdown"', bridge)
        self.assertIn('"quit"', bridge)
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

    def test_qemu_build_pins_the_verified_upstream_utm_revision(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        checkout = workflow.split("- name: Checkout UTM with submodules", 1)[1].split("- name: Select Xcode", 1)[0]
        self.assertIn("repository: utmapp/UTM", checkout)
        self.assertIn("ref: 3d4b8d8cb1ce93a8b1a9610695c12487685f0c15", checkout)
        self.assertNotIn("ref: main", checkout)
        self.assertIn("git -C UTM rev-parse HEAD > build/qemu-runtime-jit/UTM-SOURCE-REVISION.txt", workflow)
        self.assertIn("git -C UTM rev-parse HEAD > build/qemu-runtime-tci/UTM-SOURCE-REVISION.txt", workflow)

    def test_qemu_runtime_records_the_exact_pinned_qemu_source(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        package = workflow.split("- name: Package and verify in-process QEMU runtime", 1)[1].split("- name: Upload verified QEMU runtime artifact", 1)[0]
        expected = "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
        self.assertIn('QEMU_SOURCE_URL="$(sed -n', package)
        self.assertIn(expected, package)
        self.assertIn("QEMU-SOURCE-URL.txt", package)
        self.assertIn("UTM-SOURCE-REVISION.txt", package)

    def test_qemu_runtime_merge_preserves_qemu_source_provenance(self):
        root = Path(__file__).resolve().parents[2]
        merge = (root / "scripts" / "merge-qemu-runtime-variants.sh").read_text(encoding="utf-8")
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        self.assertIn('[[ -s "$package/QEMU-SOURCE-URL.txt" ]]', merge)
        self.assertIn('jit_qemu_source_url="$(tr -d', merge)
        self.assertIn('tci_qemu_source_url="$(tr -d', merge)
        self.assertIn('printf \'%s\\n\' "$jit_qemu_source_url" > "$TEMP_OUT/QEMU-SOURCE-URL.txt"', merge)
        self.assertIn('echo "QEMU_SOURCE_URL=$jit_qemu_source_url"', merge)
        self.assertIn('test -s build/qemu-runtime/QEMU-SOURCE-URL.txt', workflow)
        self.assertIn('grep -Fxq "$EXPECTED_QEMU_SOURCE_URL" build/qemu-runtime/QEMU-SOURCE-URL.txt', workflow)

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
                      "system_reset", "system_powerdown", "quit", "event_and_reply", "pthread_join"):
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

    def test_guest_power_button_is_wired_from_ui_to_the_qmp_runtime(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        backend = (root / "src" / "QEMU" / "QEMUBackend.swift").read_text(encoding="utf-8")
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn('Self.sendQMP("system_powerdown")', runtime)
        self.assertIn("runtime.requestGuestPowerDown(sessionGeneration: sessionGeneration)", backend)
        self.assertIn("backend.requestGuestPowerDown()", engine)
        self.assertIn("engine.requestGuestPowerDown()", display)
        self.assertIn('title: "Power Off"', display)

    def test_acpi_powerdown_waits_for_native_cleanup_and_releases_file_scopes(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        self.assertNotIn('"-no-shutdown"', builder)
        self.assertIn("private var nativeSessionEnded = false", runtime)
        self.assertIn("private var nativeLifecycleMonitor: DispatchSourceTimer?", runtime)
        self.assertIn("powerDownRequestedGeneration", runtime)
        self.assertIn('Self.sendQMP("quit")', runtime)
        self.assertIn(".seconds(120)", runtime)
        self.assertIn("isteam_qemu_request_stop()", runtime)
        self.assertIn("startNativeLifecycleMonitoringLocked()", runtime)
        self.assertIn("refreshCompletedSessionLocked()", runtime)
        self.assertIn("!isteam_qemu_is_active()", runtime)
        self.assertIn("scopedURLs.removeAll(keepingCapacity: false)", runtime)
        self.assertIn("stopAccessingSecurityScopedResource()", runtime)
        self.assertIn("previous QEMU process has exited", runtime)
        self.assertIn("case .poweringDown", engine)
        self.assertIn("candidate.isActive", engine)
        self.assertIn("setState(.poweredOff)", engine)
        self.assertIn("Relaunch Akatsubaki Emu", engine)
        self.assertIn("case .poweredOff", display)
        self.assertIn("restart Akatsubaki Emu to start another guest", display)
        self.assertIn("if case .poweringDown = state { return }", engine)

    def test_vm_engine_stops_by_pausing_instead_of_waiting_for_process_exit(self):
        root = Path(__file__).resolve().parents[2]
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        self.assertIn("guard candidate.stop() else", engine)
        self.assertIn("QEMU process retained for repeat launches", engine)
        self.assertIn("if backend?.stop() ?? true", engine)
        self.assertNotIn("restart requires relaunching Akatsubaki Emu", engine)


if __name__ == "__main__":
    unittest.main()
