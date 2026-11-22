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


    def test_preflight_reuses_the_validated_library_handle_for_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        validate = source.split("bool isteam_qemu_validate_library", 1)[1].split(
            "bool isteam_qemu_start", 1
        )[0]
        start = source.split("bool isteam_qemu_start", 1)[1].split(
            "void isteam_qemu_request_stop", 1
        )[0]
        harness = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        fake = (root / "scripts" / "tests" / "fake_qemu_runtime.c").read_text(encoding="utf-8")
        self.assertIn("g_preflight_library = library", validate)
        self.assertIn("library = g_preflight_library", start)
        self.assertIn("strcmp(g_preflight_path, library_path)", start)
        self.assertIn("FAKE_QEMU_LIFECYCLE_FILE", fake)
        self.assertIn('count_lifecycle_event(lifecycle_path, "load") == 1', harness)
        self.assertIn('count_lifecycle_event(lifecycle_path, "unload") == 1', harness)



    def test_preflight_handle_transfer_keeps_lifecycle_lock_until_handle_is_consumed(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        start = source.split("bool isteam_qemu_start", 1)[1].split(
            "void isteam_qemu_request_stop", 1
        )[0]
        reservation = start.split("g_stop_requested = false;", 1)[1].split(
            "if (!library)", 1
        )[0]
        self.assertIn("g_preflight_library", reservation)
        self.assertEqual(reservation.count("pthread_mutex_unlock(&g_lock);"), 1)
        self.assertLess(
            reservation.index("g_preflight_library"),
            reservation.index("pthread_mutex_unlock(&g_lock);"),
        )



if __name__ == "__main__":
    unittest.main()
