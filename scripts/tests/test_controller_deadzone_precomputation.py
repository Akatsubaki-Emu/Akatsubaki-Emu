import unittest
from pathlib import Path


class ControllerDeadzonePrecomputationTests(unittest.TestCase):
    def test_deadzone_parameters_are_precomputed_before_stick_callbacks(self):
        root = Path(__file__).resolve().parents[2]
        manager = (root / "src" / "Display" / "ControllerInputManager.swift").read_text(encoding="utf-8")
        configure = manager.split("private func configure(_ controller:", 1)[1].split("private func buttonInputs", 1)[0]

        left = configure.index("let leftDeadzone = ControllerDeadzone(profile.leftDeadzone)")
        right = configure.index("let rightDeadzone = ControllerDeadzone(profile.rightDeadzone)")
        left_handler = configure.index("pad.leftThumbstick.valueChangedHandler")
        right_handler = configure.index("pad.rightThumbstick.valueChangedHandler")
        self.assertLess(left, left_handler)
        self.assertLess(right, right_handler)
        self.assertIn("leftDeadzone.apply(x: x, y: y)", configure)
        self.assertIn("rightDeadzone.apply(x: x, y: y)", configure)
        self.assertNotIn("Self.applyDeadzone", configure)

    def test_threshold_and_inverse_range_are_not_recomputed_per_sample(self):
        root = Path(__file__).resolve().parents[2]
        store = (root / "src" / "Display" / "ControllerMappingStore.swift").read_text(encoding="utf-8")
        helper = store.split("struct ControllerDeadzone", 1)[1].split("final class ControllerMappingStore", 1)[0]
        apply = helper.split("func apply", 1)[1]

        self.assertIn("deadzoneSquared = normalized * normalized", helper)
        self.assertIn("inverseRange = 1 / (1 - normalized)", helper)
        self.assertIn("magnitudeSquared > deadzoneSquared", apply)
        self.assertIn("(magnitude - deadzone) * inverseRange", apply)
        self.assertNotIn("deadzone * deadzone", apply)
        self.assertNotIn("1 - deadzone", apply)
        self.assertNotIn("max(0.0001", apply)


if __name__ == "__main__":
    unittest.main()
