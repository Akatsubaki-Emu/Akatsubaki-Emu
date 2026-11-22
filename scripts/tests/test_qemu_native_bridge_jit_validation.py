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

    def test_jit_callback_export_is_required_only_for_jit_runtime(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertIn("(requires_jit && !has_jit_callbacks)", source)
        self.assertIn("requires_jit ? \"lifecycle/JIT\" : \"lifecycle\"", source)
        self.assertIn("if (requires_jit) {", source)
        self.assertIn("isteam_qemu_set_jit_callbacks", source)
        self.assertIn(
            "typedef void (*qemu_set_jit_callbacks_fn)(bool (*)(void), void *(*)(void *, size_t), void (*)(void));",
            source,
        )
        self.assertIn(
            "set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);",
            source,
        )
        header = (root / "iSteam" / "QEMUNativeBridge.h").read_text(encoding="utf-8")
        self.assertIn("bool requires_jit", header)
        tci_fake = (root / "scripts" / "tests" / "fake_qemu_runtime_tci.c").read_text(encoding="utf-8")
        self.assertIn("int qemu_main_loop(void)", tci_fake)
        self.assertNotIn("isteam_qemu_set_jit_callbacks", tci_fake)
        harness = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn('strcmp(argv[1], "tci")', harness)
        self.assertIn("requires_jit", harness)
        patcher = (root / "scripts" / "patch_qemu_stikjit_ios.py").read_text(encoding="utf-8")
        self.assertIn("void isteam_qemu_set_jit_callbacks(", patcher)
        self.assertIn("isteam_jit_ready_callback = ready;", patcher)
        self.assertIn("isteam_jit_prepare_callback = prepare;", patcher)
        self.assertIn("isteam_jit_detach_callback = detach;", patcher)
        self.assertIn('__attribute__((visibility("default")))', patcher)

    def test_qemu_runtime_mode_selection_does_not_request_jit_for_tci(self):
        root = Path(__file__).resolve().parents[2]
        status = (root / "src" / "QEMU" / "QEMURuntimeStatus.swift").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn('requiresJIT ? "JIT" : "TCI"', status)
        self.assertIn('QEMU-TCI.framework/QEMU', status)
        self.assertIn("libraryPath, requiresJIT, baseAddress", status)
        self.assertIn("let requiresJIT = configuration.accelerator == .jit", runtime)
        self.assertIn("QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)", runtime)
        self.assertIn("libraryPath, requiresJIT, error", runtime)

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


    def test_qemu_main_loop_and_cleanup_use_upstream_status_abi(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        thread = source.split("static void *qemu_thread_main", 1)[1].split(
            "bool isteam_qemu_validate_library", 1
        )[0]
        fake = (root / "scripts" / "tests" / "fake_qemu_runtime.c").read_text(encoding="utf-8")
        self.assertIn("typedef int (*qemu_main_loop_fn)(void);", source)
        self.assertIn("typedef void (*qemu_cleanup_fn)(int);", source)
        self.assertIn("#define ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI 5", source)
        self.assertIn("int qemu_exit_status = g_qemu_main_loop();", thread)
        self.assertIn("if (g_qemu_cleanup) g_qemu_cleanup(qemu_exit_status);", thread)
        self.assertIn("int qemu_main_loop(void)", fake)
        self.assertIn("void qemu_cleanup(int status)", fake)
        self.assertIn("return 37;", fake)


if __name__ == "__main__":
    unittest.main()
