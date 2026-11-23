import unittest
from pathlib import Path


class MotionSensitivityCacheTests(unittest.TestCase):
    def test_persisted_sensitivity_is_clamped_to_the_documented_minimum(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "MotionInputManager.swift").read_text(encoding="utf-8")
        self.assertIn("private func normalizedMotionSensitivity(_ value: Double) -> Double", source)
        self.assertIn("return min(max(value, 0.1), 5)", source)
        self.assertIn("private func storedMotionSensitivity() -> Double", source)
        self.assertIn("return stored > 0 ? normalizedMotionSensitivity(stored) : 1", source)
        self.assertIn("private var cachedSensitivity: Double = storedMotionSensitivity()", source)
        self.assertGreaterEqual(source.count("storedMotionSensitivity()"), 3)

    def test_non_finite_sensitivity_values_fall_back_to_default(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "MotionInputManager.swift").read_text(encoding="utf-8")
        self.assertIn("guard value.isFinite else { return 1 }", source)
        self.assertIn("let normalized = normalizedMotionSensitivity(newValue)", source)
        self.assertIn("UserDefaults.standard.set(normalizedMotionSensitivity(newValue), forKey: \"iSteam.motionSensitivity\")", source)

    def test_motion_samples_use_cached_sensitivity_not_user_defaults(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "MotionInputManager.swift").read_text(encoding="utf-8")
        self.assertIn("private var cachedSensitivity: Double", source)
        self.assertIn("get { withStateLock { cachedSensitivity } }", source)
        callback = source.split("motion.startDeviceMotionUpdates", 1)[1].split("\n        }", 1)[0]
        self.assertIn("self.cachedSensitivity", callback)
        self.assertNotIn("self.sensitivity", callback)
        self.assertNotIn("UserDefaults.standard.double", callback)
        self.assertIn('UserDefaults.standard.set(normalized, forKey: "iSteam.motionSensitivity")', source)


if __name__ == "__main__":
    unittest.main()
