import unittest
from pathlib import Path


class VNCPointerNoopTests(unittest.TestCase):
    def test_pointer_packets_are_skipped_when_integer_position_does_not_change(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        movement = source.split("func movePointer", 1)[1].split("func sendButton", 1)[0]
        self.assertIn("let deltaX = Int(boundedX)", movement)
        self.assertIn("let deltaY = Int(boundedY)", movement)
        self.assertIn("guard deltaX != 0 || deltaY != 0 else { return }", movement)
        self.assertIn("guard nextX != pointerX || nextY != pointerY else { return }", movement)
        self.assertLess(movement.index("guard nextX"), movement.index("let message = Data"))


if __name__ == "__main__":
    unittest.main()
