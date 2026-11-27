import unittest
from pathlib import Path


class HardwareKeyboardVNCRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        cls.vnc = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")

    def test_ui_key_codes_use_native_cfindex_key_type(self):
        self.assertIn(
            "private var hardwareKeySources: [Int: (key: String, source: String)] = [:]",
            self.display,
        )
        self.assertIn("let code = key.keyCode.rawValue", self.display)

    def test_controller_receives_hardware_keyboard_events(self):
        self.assertIn("override var canBecomeFirstResponder: Bool { true }", self.display)
        self.assertIn("becomeFirstResponder()", self.display)
        self.assertIn("override func pressesBegan(_ presses: Set<UIPress>", self.display)
        self.assertIn("override func pressesEnded(_ presses: Set<UIPress>", self.display)
        self.assertIn("override func pressesCancelled(_ presses: Set<UIPress>", self.display)
        self.assertIn("sendHardwareKey(key, isDown: true)", self.display)
        self.assertIn("sendHardwareKey(key, isDown: false)", self.display)
        self.assertIn("vncClient.sendKey(name, down: true, source: source)", self.display)
        self.assertIn('return "F\\(Int(key.keyCode.rawValue) - 0x39)"', self.display)
        self.assertIn('let source = "hardware-keyboard:\\(code)"', self.display)

    def test_hid_navigation_function_modifier_and_system_keys_are_mapped(self):
        mapping = self.display.split("private func hardwareKeyName", 1)[1].split("private func sendHardwareKey", 1)[0]
        for value in ("0x28, 0x58", "0x29", "0x2A", "0x2B", "0x2C",
                      "0x39", "0x3A...0x45", "0x46", "0x47", "0x48",
                      "0x49", "0x4A", "0x4B", "0x4C", "0x4D", "0x4E",
                      "0x4F", "0x50", "0x51", "0x52", "0x53", "0x65",
                      "0xE0, 0xE4", "0xE1, 0xE5", "0xE2, 0xE6", "0xE3", "0xE7"):
            self.assertIn(value, mapping)

    def test_keyup_cleanup_runs_on_disconnect_stop_background_and_disappear(self):
        release = self.display.split("private func releaseGuestInputs", 1)[1].split("private func registerKeyboardNotifications", 1)[0]
        self.assertIn("releaseHardwareKeyboardKeys()", release)
        refresh = self.display.split("private func refreshHardwareKeyboardState", 1)[1].split("private func addTouchGamepad", 1)[0]
        self.assertIn("if !connected", refresh)
        self.assertIn("releaseHardwareKeyboardKeys()", refresh)
        self.assertIn("UIApplication.willResignActiveNotification", self.display)
        self.assertIn("resignFirstResponder()", self.display)

    def test_observers_are_reinstalled_when_display_reappears(self):
        appear = self.display.split("override func viewDidAppear", 1)[1].split("private func", 1)[0]
        self.assertIn("keyboardObservers.isEmpty", appear)
        self.assertIn("registerKeyboardNotifications()", appear)

    def test_vnc_keysym_preserves_ascii_case_and_maps_navigation(self):
        mapping = self.vnc.split("private static func keysym", 1)[1]
        self.assertIn("key.unicodeScalars.first", mapping)
        for value in ('case "CAPSLOCK": return 0xffe5', 'case "HOME": return 0xff50',
                      'case "PAGEUP": return 0xff55', 'case "PAGEDOWN": return 0xff56',
                      'case "META": return 0xffeb', 'case "META_R": return 0xffec'):
            self.assertIn(value, mapping)
        self.assertNotIn("scalar = value.unicodeScalars.first", mapping)


if __name__ == "__main__":
    unittest.main()
