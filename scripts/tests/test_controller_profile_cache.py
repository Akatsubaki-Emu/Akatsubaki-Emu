import unittest
from pathlib import Path


class ControllerProfileCacheTests(unittest.TestCase):
    def test_profile_getter_uses_cache_and_mutators_keep_it_coherent(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "ControllerMappingStore.swift").read_text(encoding="utf-8")
        self.assertIn("private var cachedProfile: ControllerMappingProfile?", source)
        profile = source.split("var profile:", 1)[1].split("func reset", 1)[0]
        self.assertIn("if let cachedProfile { return cachedProfile }", profile)
        self.assertNotIn("JSONDecoder", profile)
        self.assertIn("cachedProfile = newValue", profile)
        reset = source.split("func reset", 1)[1]
        self.assertIn("cachedProfile = .standard", reset)
        self.assertIn("private func loadProfile()", source)


if __name__ == "__main__":
    unittest.main()
