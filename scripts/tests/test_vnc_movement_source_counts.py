import unittest
from pathlib import Path


class VNCMovementSourceCountTests(unittest.TestCase):
    def test_movement_union_is_updated_incrementally(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "VNCKeyState.swift").read_text(encoding="utf-8")
        movement = source.split("mutating func setMovement", 1)[1].split("mutating func releaseAll", 1)[0]
        self.assertIn("movementSourceCounts = [Int](repeating: 0, count: 4)", source)
        self.assertIn("let previousSourceMask = movementSources[source] ?? 0", movement)
        self.assertIn("movementSourceCounts[index] += 1", movement)
        self.assertIn("movementSourceCounts[index] -= 1", movement)
        self.assertNotIn("movementSources.values.reduce", source)
        release = source.split("mutating func releaseAll", 1)[1].split("func isPressed", 1)[0]
        self.assertIn("movementMask = 0", release)
        self.assertIn("movementSourceCounts = [Int](repeating: 0", release)


if __name__ == "__main__":
    unittest.main()
