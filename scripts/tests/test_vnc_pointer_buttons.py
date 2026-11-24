import unittest
from pathlib import Path


class VNCPointerButtonTests(unittest.TestCase):
    def test_pointer_motion_preserves_current_button_mask(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        position = source.split("private struct VNCPointerPosition", 1)[1].split("}", 1)[0]
        movement = source.split("func movePointer", 1)[1].split("func sendPointerButton", 1)[0]
        self.assertIn("let buttonMask: UInt8", position)
        self.assertIn("buttonMask: pointerButtonMask", movement)
        self.assertIn("buttonMask: latestPosition.buttonMask", movement)
        self.assertIn("private static func pointerEvent(buttonMask: UInt8", source)

    def test_pointer_tap_sends_ordered_press_and_release_without_mutating_held_state(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        tap = source.split("func tapPointer", 1)[1].split("func sendButton", 1)[0]
        self.assertIn("let pressedMask = pointerButtonMask | buttonMask", tap)
        self.assertIn("let releasedMask = pointerButtonMask", tap)
        self.assertIn("buttonMask: pressedMask", tap)
        self.assertIn("buttonMask: releasedMask", tap)

    def test_stop_releases_held_pointer_buttons_before_cancelling_connection(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        stop = source.split("func stop()", 1)[1].split("private func waitUntilReady", 1)[0]
        self.assertIn("let releasePointerButtons = pointerButtonMask != 0", stop)
        self.assertIn("pointerButtonMask = 0", stop)
        self.assertIn("buttonMask: 0", stop)
        self.assertLess(stop.index("enqueueSend(Self.pointerEvent"), stop.index("previousGroup.notify"))

    def test_touch_toolbar_exposes_left_and_right_pointer_clicks(self):
        root = Path(__file__).resolve().parents[2]
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn('configurePointerClickButton(pointerLeftClick, title: "L Click", buttonMask: 0x01)', display)
        self.assertIn('configurePointerClickButton(pointerRightClick, title: "R Click", buttonMask: 0x04)', display)
        helper = display.split("private func configurePointerClickButton", 1)[1].split("@objc", 1)[0]
        self.assertIn("sendPointerButton(buttonMask: buttonMask, down: true)", helper)
        self.assertIn("sendPointerButton(buttonMask: buttonMask, down: false)", helper)
        self.assertIn("for: .touchDown", helper)
        self.assertIn("for: [.touchUpInside, .touchUpOutside, .touchCancel]", helper)


if __name__ == "__main__":
    unittest.main()
