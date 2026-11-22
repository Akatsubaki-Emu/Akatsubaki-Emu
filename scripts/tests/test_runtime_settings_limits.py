import unittest
from pathlib import Path


class RuntimeSettingsLimitsTests(unittest.TestCase):
    def test_persisted_custom_resolution_is_clamped_on_read(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        self.assertIn('return v >= 320 ? min(v, 8192) : 1920', source)
        self.assertIn('return v >= 240 ? min(v, 8192) : 1080', source)

    def test_custom_resolution_setters_keep_the_same_bounds(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        self.assertIn('min(max(newValue, 320), 8192)', source)
        self.assertIn('min(max(newValue, 240), 8192)', source)


if __name__ == "__main__":
    unittest.main()
