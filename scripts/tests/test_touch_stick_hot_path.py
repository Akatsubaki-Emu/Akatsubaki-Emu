import unittest
from pathlib import Path


class TouchStickHotPathTests(unittest.TestCase):
    def test_radius_and_inverse_are_cached_outside_touch_updates(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "TouchGamepadView.swift").read_text(encoding="utf-8")
        stick = source.split("private final class StickControl", 1)[1]

        self.assertIn("private var stickMath = TouchStickMath(radius: 1)", stick)
        self.assertIn("stickMath = TouchStickMath(radius: max(1, min(bounds.width, bounds.height) * 0.36))", stick)
        update = stick.split("private func update(_ point: CGPoint)", 1)[1]
        self.assertIn("stickMath.transform(dx: dx, dy: dy)", update)
        self.assertIn("movement.offsetX", update)
        self.assertIn("movement.normalizedX", update)
        self.assertNotIn("movementRadius", update)
        self.assertNotIn("knob.center.x - touchOrigin.x", update)
        self.assertNotIn("sqrt(", update)

    def test_inverse_radius_is_multiplied_in_the_shared_math_helper(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "TouchStickMath.swift").read_text(encoding="utf-8")
        transform = source.split("func transform", 1)[1]

        self.assertIn("inverseRadius = 1 / value", source)
        self.assertIn("offsetX * inverseRadius", transform)
        self.assertIn("offsetY * inverseRadius", transform)
        self.assertIn("distanceSquared <= radiusSquared", transform)


if __name__ == "__main__":
    unittest.main()
