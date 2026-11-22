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
        self.assertIn("JITCoordinator.shared.requestJIT(from: self)", source)
        self.assertIn("override func viewDidAppear", source)
        self.assertIn("guard !startupFlowStarted else { return }", source)
        self.assertIn("self?.startEngine()", source)
        self.assertLess(source.index("JITCoordinator.shared.requestJIT(from: self)"), source.index("private func startEngine()"))
        self.assertIn("guard !engineStartRequested else { return }", source)


    def test_wait_for_debugger_polls_immediately_and_closes_alerts(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        wait_case = source.split("case .waitForDebugger:", 1)[1].split("case .stikDebug:", 1)[0]
        complete = source.split("private func completeJITRequest()", 1)[1].split("private func failRequest", 1)[0]
        dismiss = source.split("private func dismissActiveAlert", 1)[1].split("private func show(", 1)[0]
        show = source.split("private func show(", 1)[1]
        self.assertLess(wait_case.index("show("), wait_case.index("checkReadiness()"))
        self.assertIn("private weak var activeAlert: UIAlertController?", source)
        self.assertIn("dismissActiveAlert", complete)
        self.assertIn("alert.dismiss(animated: false", dismiss)
        self.assertIn("dismissActiveAlert", show)
        self.assertIn("show(message, title: title)", source)

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
