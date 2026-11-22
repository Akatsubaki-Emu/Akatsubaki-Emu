import unittest
from pathlib import Path


class JITCoordinatorSourceTests(unittest.TestCase):
    def test_stikdebug_support_starts_at_ios_17_4(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("if #available(iOS 17.4, *)", source)
        self.assertIn("var isStikDebugAvailable: Bool", source)
        self.assertIn("StikDebug JIT requires iOS 17.4 or later", source)

    def test_stikdebug_availability_is_limited_to_physical_ios_devices(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        physical_guard = "#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)"
        self.assertGreaterEqual(source.count(physical_guard), 4)

    def test_jit_ready_uses_the_attached_debugger_status(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("var isJITReady: Bool", source)
        self.assertIn("return iSteamJITIsReady()", source)

    def test_qemu_jit_readiness_requires_every_physical_ios_prerequisite(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("var isQEMUJITReady: Bool", source)
        readiness = source.split("var isQEMUJITReady: Bool", 1)[1].split("func requestJIT", 1)[0]
        self.assertIn("if #available(iOS 17.4, *)", readiness)
        self.assertIn(
            "return isStikDebugAvailable && hasGetTaskAllow && isJITProtocolKnown && isJITReady",
            source,
        )
        self.assertIn("#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)", source)
        self.assertIn("return false", source.split("var isQEMUJITReady: Bool", 1)[1].split("func requestJIT", 1)[0])

    def test_launch_setup_cannot_skip_the_jit_gate_on_unsupported_physical_ios(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "LaunchSetupViewController.swift").read_text(encoding="utf-8")
        self.assertIn("#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)", source)
        self.assertIn("if !JITCoordinator.shared.isQEMUJITReady", source)
        self.assertNotIn(
            "if JITCoordinator.shared.isStikDebugAvailable && !JITCoordinator.shared.isJITReady",
            source,
        )

    def test_native_qemu_runtime_rechecks_jit_readiness_before_loading_qemu(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("guard JITCoordinator.shared.isQEMUJITReady else", source)
        self.assertLess(source.index("isQEMUJITReady"), source.index("QEMURuntimeStatus.inspect()"))
        self.assertNotIn("if #available(iOS 17.4, *), JITCoordinator.shared.isStikDebugAvailable", source)

    def test_vm_display_rechecks_qemu_jit_readiness_before_engine_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn("if !JITCoordinator.shared.isQEMUJITReady", source)
        self.assertLess(source.index("isQEMUJITReady"), source.index("private func startEngine()"))

    def test_stikdebug_request_targets_this_app_process(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn('URLQueryItem(name: "bundle-id", value: bundleID)', source)
        self.assertIn('URLQueryItem(name: "pid", value: String(getpid()))', source)
        self.assertIn('components.scheme = "stikdebug"', source)
        self.assertIn('components.host = "enable-jit"', source)

    def test_ios_26_breakpoint_script_is_gated_to_supported_devices(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("if #available(iOS 26.0, *), isJITProtocolSupported", source)
        self.assertIn('queryItems.append(URLQueryItem(name: "script-name", value: "universal.js"))', source)
        before_protocol = source.split("if #available(iOS 26.0, *), isJITProtocolSupported", 1)[0]
        self.assertNotIn('URLQueryItem(name: "script-name"', before_protocol)

    def test_ios_targets_link_security_exactly_once(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count('"MetalKit", "-framework", "Security",'), 2)
        self.assertNotIn('"Security", "-framework", "Security"', project)

    def test_localdevvpn_starts_before_stikdebug_and_returns_to_this_bundle(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn('components.scheme = "localdevvpn"', source)
        self.assertIn('components.host = "enable"', source)
        self.assertIn('URLQueryItem(name: "scheme", value: bundleID)', source)
        self.assertIn("url.scheme == Bundle.main.bundleIdentifier", source)
        self.assertLess(source.index("private func enableLocalDevVPN"), source.index("private func openStikDebug"))

    def test_jit_requests_require_the_real_signing_entitlement(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        protocol_source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn("guard hasGetTaskAllow else", source)
        self.assertIn('CFSTR("get-task-allow")', protocol_source)
        self.assertNotIn("var hasGetTaskAllow: Bool { false }", source)

    def test_vm_launch_waits_for_jit_before_starting_qemu(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn("JITCoordinator.shared.requestJIT(from: self, onFailure:", source)
        self.assertIn("if !JITCoordinator.shared.isQEMUJITReady", source)
        self.assertIn("override func viewDidAppear", source)
        self.assertIn("guard !startupFlowStarted else { return }", source)
        self.assertIn("self?.startEngine()", source)
        self.assertLess(source.index("JITCoordinator.shared.requestJIT(from: self, onFailure:"), source.index("private func startEngine()"))
        self.assertIn("guard !engineStartRequested else { return }", source)

    def test_jit_failure_callback_reaches_launch_ui(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("onFailure: ((String) -> Void)? = nil", source)
        self.assertIn("onJITFailure = onFailure", source)
        self.assertIn("failure?(message)", source)

    def test_app_registers_localdevvpn_and_its_callback_scheme(self):
        root = Path(__file__).resolve().parents[2]
        info = (root / "iSteam" / "Info.plist").read_text(encoding="utf-8")
        app = (root / "iSteam" / "AppDelegate.swift").read_text(encoding="utf-8")
        self.assertIn("<string>localdevvpn</string>", info)
        self.assertIn("<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>", info)
        self.assertIn("JITCoordinator.shared.handleCallback(url)", app)
        self.assertIn("JITCoordinator.shared.applicationDidBecomeActive()", app)


if __name__ == "__main__":
    unittest.main()
