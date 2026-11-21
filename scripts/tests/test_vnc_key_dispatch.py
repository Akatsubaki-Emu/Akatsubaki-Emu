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


if __name__ == "__main__":
    unittest.main()
