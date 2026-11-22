import unittest
from pathlib import Path


class MotionSensitivityCacheTests(unittest.TestCase):
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
