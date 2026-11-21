import unittest
from pathlib import Path


class VNCMovementMaskTests(unittest.TestCase):
    def test_movement_updates_use_mask_and_preserve_button_overlap(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        self.assertIn("private var movementMask: UInt8 = 0", source)
        self.assertNotIn("private var movementKeys = Set<UInt32>()", source)
        stop = source.split("func stop()", 1)[1].split("func sendKey", 1)[0]
        self.assertIn("movementMask = 0", stop)
        send_key = source.split("func sendKey", 1)[1].split("func setMovement", 1)[0]
        self.assertIn("movementKeyIsActive(keysym)", send_key)
        movement = source.split("func setMovement", 1)[1].split("private func updateMovementKey", 1)[0]
        self.assertIn("movementMask ^ desiredMask", movement)
        self.assertNotIn("Set(", movement)
        helpers = source.split("private func updateMovementKey", 1)[1].split("func movePointer", 1)[0]
        self.assertIn("active || buttonKeys.contains(keysym)", helpers)


if __name__ == "__main__":
    unittest.main()
