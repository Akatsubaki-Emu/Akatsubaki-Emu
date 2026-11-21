import unittest
from pathlib import Path


class QEMUNativeBridgeJITValidationTests(unittest.TestCase):
    def test_jit_callback_export_is_required_during_validation_and_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertIn(
            "if (!has_init || !has_main_loop || !has_cleanup || !has_shutdown || !has_jit_callbacks)",
            source,
        )
        self.assertIn("isteam_qemu_set_jit_callbacks", source)
        self.assertIn("required lifecycle/JIT exports", source)


if __name__ == "__main__":
    unittest.main()
