import unittest
from pathlib import Path


class ControllerProfileHotPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.manager = (root / "src" / "Display" / "ControllerInputManager.swift").read_text(encoding="utf-8")
        cls.store = (root / "src" / "Display" / "ControllerMappingStore.swift").read_text(encoding="utf-8")

    def test_stick_handlers_capture_one_immutable_profile_snapshot(self):
        configure = self.manager.split("private func configure(_ controller:", 1)[1]
        self.assertIn("let profile = ControllerMappingStore.shared.profile", configure)
        self.assertIn("deadzone: profile.leftDeadzone", configure)
        self.assertIn("deadzone: profile.rightDeadzone", configure)
        self.assertNotIn("ControllerMappingStore.shared.profile", configure.split("private func buttonInputs", 1)[0].replace(
            "let profile = ControllerMappingStore.shared.profile", ""
        ))

    def test_profile_changes_reconfigure_connected_controller_handlers(self):
        self.assertIn("ControllerMappingStore.profileDidChangeNotification", self.manager)
        self.assertIn("mappingProfileObserver = NotificationCenter.default.addObserver(", self.manager)
        self.assertIn("queue: .main", self.manager)
        self.assertIn("GCController.controllers().forEach(self.configure)", self.manager)
        self.assertIn("NotificationCenter.default.removeObserver(mappingProfileObserver)", self.manager)

    def test_button_mapping_uses_the_captured_profile(self):
        self.assertIn("profile: ControllerMappingProfile", self.manager)
        mapped = self.manager.split("private func mappedAction", 1)[1].split("private func sourceID", 1)[0]
        self.assertIn("profile.action(for: name)", mapped)
        self.assertNotIn("ControllerMappingStore.shared.profile", mapped)

    def test_held_button_release_keeps_the_action_chosen_on_press(self):
        mapped = self.manager.split("private func mappedAction", 1)[1].split("private func sourceID", 1)[0]
        self.assertIn("activeButtonActions[source] = action", mapped)
        self.assertIn("activeButtonActions.removeValue(forKey: source) ?? profile.action(for: name)", mapped)

    def test_store_posts_changes_after_releasing_its_lock(self):
        self.assertIn("static let profileDidChangeNotification", self.store)
        setter = self.store.split("set {", 1)[1].split("\n        }", 1)[0]
        self.assertLess(setter.index("lock.unlock()"), setter.index("NotificationCenter.default.post"))
        reset = self.store.split("func reset()", 1)[1].split("private func loadProfile", 1)[0]
        self.assertLess(reset.index("lock.unlock()"), reset.index("NotificationCenter.default.post"))


if __name__ == "__main__":
    unittest.main()
