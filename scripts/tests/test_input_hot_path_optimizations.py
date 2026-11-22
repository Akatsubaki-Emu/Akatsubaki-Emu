import math
import unittest
from pathlib import Path


class InputHotPathOptimizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        cls.touch = (cls.root / "src" / "Display" / "TouchGamepadView.swift").read_text(encoding="utf-8")
        cls.controller = (cls.root / "src" / "Display" / "ControllerInputManager.swift").read_text(encoding="utf-8")
        cls.controller_mapping = (cls.root / "src" / "Display" / "ControllerMappingStore.swift").read_text(encoding="utf-8")

    def test_touch_stick_caches_radius_and_skips_in_radius_square_root(self):
        stick = self.touch.split("private final class StickControl", 1)[1]
        self.assertIn("private var stickMath = TouchStickMath(radius: 1)", stick)
        self.assertIn("stickMath = TouchStickMath(radius: max(1, min(bounds.width, bounds.height) * 0.36))", stick)
        update = stick.split("private func update(_ point: CGPoint)", 1)[1]
        self.assertIn("stickMath.transform(dx: dx, dy: dy)", update)
        self.assertNotIn("movementRadius", update)
        self.assertNotIn("sqrt", update)

    def test_touch_stick_math_uses_cached_inverse_radius(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "TouchStickMath.swift").read_text(encoding="utf-8")
        transform = source.split("func transform", 1)[1]
        self.assertIn("inverseRadius = 1 / value", source)
        self.assertIn("offsetX * inverseRadius", transform)
        self.assertIn("offsetY * inverseRadius", transform)
        self.assertIn("distanceSquared <= radiusSquared", transform)

    def test_controller_deadzone_rejects_inside_radius_before_square_root(self):
        if "struct ControllerDeadzone" in self.controller_mapping:
            function = self.controller_mapping.split("struct ControllerDeadzone", 1)[1].split("final class ControllerMappingStore", 1)[0]
            self.assertIn("let magnitudeSquared = x * x + y * y", function)
            self.assertIn("guard magnitudeSquared > deadzoneSquared else { return (0, 0) }", function)
            self.assertIn("let magnitude = min(1, magnitudeSquared.squareRoot())", function)
            self.assertIn("deadzoneSquared = normalized * normalized", function)
            self.assertIn("inverseRange = 1 / (1 - normalized)", function)
        else:
            function = self.controller.split("private static func applyDeadzone", 1)[1]
            self.assertIn("let magnitudeSquared = x * x + y * y", function)
            self.assertIn("guard magnitudeSquared > deadzone * deadzone else { return (0, 0) }", function)
            self.assertIn("let magnitude = min(1, magnitudeSquared.squareRoot())", function)

    def test_touch_stick_formula_matches_previous_clamp(self):
        radius = 34.2
        radius_squared = radius * radius
        for ix in range(-100, 101):
            for iy in range(-100, 101):
                dx = ix * 0.73
                dy = iy * 0.61
                old_length = max(math.sqrt(dx * dx + dy * dy), 1.0)
                old_scale = min(1.0, radius / old_length)
                distance_squared = dx * dx + dy * dy
                new_scale = 1.0 if distance_squared <= radius_squared else radius / math.sqrt(distance_squared)
                self.assertAlmostEqual(old_scale, new_scale, places=12)

    def test_controller_deadzone_matches_previous_mapping(self):
        for deadzone in (0.0, 0.12, 0.35, 0.8):
            for ix in range(-100, 101):
                for iy in range(-100, 101):
                    x = ix / 100
                    y = iy / 100
                    old_magnitude = min(1.0, math.sqrt(x * x + y * y))
                    if old_magnitude <= deadzone:
                        old = (0.0, 0.0)
                    else:
                        scaled = min(1.0, (old_magnitude - deadzone) / max(0.0001, 1 - deadzone))
                        factor = scaled / old_magnitude
                        old = (x * factor, y * factor)

                    magnitude_squared = x * x + y * y
                    if magnitude_squared <= deadzone * deadzone:
                        new = (0.0, 0.0)
                    else:
                        magnitude = min(1.0, math.sqrt(magnitude_squared))
                        scaled = min(1.0, (magnitude - deadzone) / max(0.0001, 1 - deadzone))
                        factor = scaled / magnitude
                        new = (x * factor, y * factor)

                    self.assertAlmostEqual(old[0], new[0], places=12)
                    self.assertAlmostEqual(old[1], new[1], places=12)


if __name__ == "__main__":
    unittest.main()
