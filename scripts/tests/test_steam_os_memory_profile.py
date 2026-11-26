import unittest
from pathlib import Path


class SteamOSMemoryProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.launch = (root / "iSteam" / "LaunchSetupViewController.swift").read_text(encoding="utf-8")
        cls.config = (root / "src" / "Core" / "VMConfiguration.swift").read_text(encoding="utf-8")
        cls.validation = (root / "src" / "Core" / "VMConfigurationValidation.swift").read_text(encoding="utf-8")

    def test_default_steam_profile_is_platform_aware(self):
        block = self.config.split("static var defaultSteamOS", 1)[1].split("\n    }", 1)[0]
        self.assertIn("#if os(iOS) || os(tvOS)", block)
        self.assertIn("let memoryMB = 2048", block)
        self.assertIn("let cpuCount = 2", block)
        self.assertIn("#else", block)
        self.assertIn("let memoryMB = 4096", block)
        self.assertIn("let cpuCount = 4", block)

    def test_launch_does_not_apply_desktop_override_on_ios(self):
        block = self.launch.split("if isSteamOS {", 1)[1].split("return config", 1)[0]
        self.assertIn("let profile = VMConfiguration.defaultSteamOS", block)
        self.assertIn("#if os(iOS) || os(tvOS)", block)
        self.assertIn("config.memoryMB = min(config.memoryMB, profile.memoryMB)", block)
        self.assertIn("config.cpuCount = min(max(config.cpuCount, 1), profile.cpuCount)", block)
        self.assertIn("#else", block)
        self.assertIn("config.memoryMB = max(config.memoryMB, profile.memoryMB)", block)
        self.assertIn("config.cpuCount = max(config.cpuCount, profile.cpuCount)", block)
        self.assertNotIn("config.memoryMB = 4096", block)

    def test_intro_describes_the_platform_specific_resource_profile(self):
        intro = self.launch.split("let intro = UILabel()", 1)[1].split("intro.font", 1)[0]
        self.assertIn("#if os(iOS) || os(tvOS)", intro)
        self.assertIn("2 GB RAM, 2 CPUs", intro)
        self.assertIn("4 GB RAM, 4 CPUs", intro)

    def test_memory_validation_keeps_host_headroom(self):
        self.assertIn("availableMemoryBytes", self.validation)
        self.assertIn("reserveMB = max(512, memoryMB / 4)", self.validation)
        self.assertIn("availableMB >= memoryMB + reserveMB", self.validation)


if __name__ == "__main__":
    unittest.main()
