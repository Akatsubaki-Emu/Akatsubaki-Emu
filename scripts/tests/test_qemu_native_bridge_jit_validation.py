import unittest
from pathlib import Path


class QEMUNativeBridgeJITValidationTests(unittest.TestCase):
    def test_qemu_arguments_use_one_contiguous_allocation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        release = source.split("static void release_arguments", 1)[1].split("static void *qemu_thread_main", 1)[0]
        start = source.split("bool isteam_qemu_start", 1)[1].split("void isteam_qemu_request_stop", 1)[0]
        self.assertIn("static char *g_argument_storage = NULL;", source)
        self.assertIn("free(g_argument_storage)", release)
        self.assertNotIn("free(g_argv[i])", release)
        self.assertIn("malloc(total_argument_bytes)", start)
        self.assertIn("copied_argv[i] = argument_storage + argument_offset", start)
        self.assertNotIn("malloc(argument_length + 1)", start)
        self.assertIn("g_argument_storage = argument_storage", start)

    def test_jit_callback_export_is_required_during_validation_and_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertIn(
            "if (!has_init || !has_main_loop || !has_cleanup || !has_shutdown || !has_jit_callbacks)",
            source,
        )
        self.assertIn("isteam_qemu_set_jit_callbacks", source)
        self.assertIn("required lifecycle/JIT exports", source)
        self.assertIn(
            "typedef void (*qemu_set_jit_callbacks_fn)(bool (*)(void), void *(*)(void *, size_t), void (*)(void));",
            source,
        )
        self.assertIn(
            "set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);",
            source,
        )
        patcher = (root / "scripts" / "patch_qemu_stikjit_ios.py").read_text(encoding="utf-8")
        self.assertIn("void isteam_qemu_set_jit_callbacks(", patcher)
        self.assertIn("isteam_jit_ready_callback = ready;", patcher)
        self.assertIn("isteam_jit_prepare_callback = prepare;", patcher)
        self.assertIn("isteam_jit_detach_callback = detach;", patcher)
        self.assertIn('__attribute__((visibility("default")))', patcher)

    def test_qemu_init_uses_the_upstream_void_abi(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        thread = source.split("static void *qemu_thread_main", 1)[1].split(
            "bool isteam_qemu_validate_library", 1
        )[0]
        fake = (root / "scripts" / "tests" / "fake_qemu_runtime.c").read_text(encoding="utf-8")
        self.assertIn("typedef void (*qemu_init_fn)(int, char **);", source)
        self.assertIn("g_qemu_init(g_argc, g_argv);", thread)
        self.assertNotIn("init_result", thread)
        self.assertNotIn("environ", source)
        self.assertIn("void qemu_init(int argc, char *argv[])", fake)
        self.assertIn("poison_nonzero_return_register();", fake)


    def test_clear_starting_helper_has_valid_declaration(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertNotIn("remove unused set_error", source)
        self.assertEqual(source.count("static void clear_starting(void) {"), 1)


if __name__ == "__main__":
    unittest.main()
