import unittest
from pathlib import Path


class VNCMovementMaskTests(unittest.TestCase):
    def test_movement_updates_use_source_masks_and_preserve_button_overlap(self):
        root = Path(__file__).resolve().parents[2]
        client = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        state = (root / "src" / "QEMU" / "VNCKeyState.swift").read_text(encoding="utf-8")
        self.assertIn("private var keyState = VNCKeyState()", client)
        self.assertIn("let events = keyState.setMovement(desiredMask, source: source)", client)
        self.assertIn("keyState.setKey(keysym, source: source, isDown: down)", client)
        self.assertIn("keyState.releaseAll()", client)
        self.assertIn("private var movementSources: [String: UInt8] = [:]", state)
        self.assertIn("private var movementSourceCounts", state)
        self.assertIn("let changedMask = previousMask ^ movementMask", state)
        self.assertIn("|| keySources[movement.keysym]?.isEmpty == false", state)
        self.assertNotIn("private var movementKeys = Set<UInt32>()", client)


if __name__ == "__main__":
    unittest.main()
