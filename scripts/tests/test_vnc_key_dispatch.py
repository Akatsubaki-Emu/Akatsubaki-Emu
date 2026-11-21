import unittest
from pathlib import Path


class VNCKeyDispatchTests(unittest.TestCase):
    def test_wasd_direction_lookup_is_constant_time_switch(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "VNCKeyState.swift").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_vnc_key_state.swift").read_text(encoding="utf-8")
        self.assertIn("switch keysym {", source)
        for keysym, mask in (("0x41", "0x01"), ("0x44", "0x02"), ("0x57", "0x04"), ("0x53", "0x08")):
            self.assertIn(f"case {keysym}: return {mask}", source)
        self.assertNotIn("movementKeys.first(where:", source)
        self.assertIn("for (mask, keysym) in", tests)


    def test_tap_key_uses_preallocated_press_release_packet(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        tap = source.split("func tapKey", 1)[1].split("func setMovement", 1)[0]
        helper = source.split("private static func keyTapEvents", 1)[1].split("private static func keyEvents", 1)[0]
        self.assertIn("Self.keyTapEvents(keysym)", tap)
        self.assertNotIn("let events = [", tap)
        self.assertIn("Data(count: 16)", helper)
        self.assertIn("base[1] = 1", helper)
        self.assertIn("base[9] = 0", helper)

if __name__ == "__main__":
    unittest.main()
