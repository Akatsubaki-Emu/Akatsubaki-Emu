import unittest
from pathlib import Path


class JITProtocolSourceTests(unittest.TestCase):
    def test_breakpoint_protocol_exports_prepare_and_detach(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        header = (root / "iSteam" / "JIT26Protocol.h").read_text(encoding="utf-8")
        self.assertIn('"brk #0xf00d\\n"', source)
        self.assertIn('"mov x16, #1\\n"', source)
        self.assertIn('"mov x16, #0\\n"', source)
        self.assertIn("bool iSteamJITIsReady(void)", source)
        self.assertIn("bool iSteamJITIsReady(void);", header)

    def test_jit_readiness_requires_cs_debugged(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn('dlsym(RTLD_DEFAULT, "csops")', source)
        self.assertIn("queryStatus(getpid(), 0, &status, sizeof(status)) == 0", source)
        self.assertIn("status & UINT32_C(0x10000000)", source)
        self.assertIn("bool iSteamJITIsReady(void) { return false; }", source)
        self.assertIn("bool iSteamJITIsDebuggerAttached(void) { return false; }", source)
        self.assertIn("void iSteamJITSetTXMScriptReady(bool ready)", source)
        self.assertIn("iSteamJITPrepareRegionIfReady", source)

    def test_txm_detection_matches_stikdebug_hardware_version_rules(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        helper = (root / "iSteam" / "JITHardwareModel.h").read_text(encoding="utf-8")
        self.assertIn("uname(&systemInfo)", source)
        self.assertIn("iSteamJITHardwareModelTXMModeForOS", source)
        self.assertIn('"iPad8,11"', helper)
        self.assertIn('"iPad8,12"', helper)
        self.assertIn("double threshold = isIPad ? 14.5 : 14.2;", helper)
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", helper)
        self.assertNotIn("IORegistryEntryFromPath", source)
        self.assertNotIn("#include <IOKit/IOKitLib.h>", source)

    def test_live_debugger_is_required_only_for_txm_breakpoint_protocol(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        readiness = source.split("bool iSteamJITIsReady(void) {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN", readiness)
        self.assertIn("protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG", readiness)
        self.assertIn("return iSteamJITIsDebuggerAttached()", readiness)
        self.assertIn("atomic_load_explicit(&g_txm_script_ready, memory_order_acquire)", readiness)
        self.assertTrue(readiness.rstrip().endswith("return true;"))

    def test_qemu_uses_breakpoint_allocator_only_when_txm_is_present(self):
        root = Path(__file__).resolve().parents[2]
        patcher = (root / "scripts" / "patch_qemu_stikjit_ios.py").read_text(encoding="utf-8")
        self.assertIn("JITProtocolModeFunction get_jit_protocol_mode =", patcher)
        self.assertIn("iSteamJITGetProtocolMode", patcher)
        self.assertIn("if (jit_protocol_mode < 0)", patcher)
        self.assertIn("if (jit_protocol_mode > 0)", patcher)
        self.assertIn("return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);", patcher)

    def test_qemu_can_resolve_host_jit_callbacks_from_main_and_nightly_apps(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        for bundle in ("com.xthrx.isteam", "com.xthrx.isteam.nightly"):
            start = project.index("PRODUCT_BUNDLE_IDENTIFIER: " + bundle)
            end = project.index("  iSteamTV:", start)
            block = project[start:end]
            for symbol in ("iSteamJITIsSupported", "iSteamJITGetProtocolMode", "iSteamJITIsReady", "iSteamJITPrepareRegion", "iSteamJITDetach"):
                self.assertIn("-Wl,-exported_symbol,_" + symbol, block)


    def test_ios_targets_use_model_detection_without_iokit_framework(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertNotIn("- sdk: IOKit.framework", project)
        self.assertEqual(project.count("-Wl,-exported_symbol,_iSteamJITGetProtocolMode"), 2)

    def test_non_device_builds_export_unknown_protocol_mode(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        fallback = source.split("\n#else\n", 1)[1].split("\n#endif", 1)[0]
        self.assertIn(
            "int iSteamJITGetProtocolMode(void) {",
            fallback,
        )
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", fallback)

    def test_launch_refuses_unknown_jit_protocol(self):
        root = Path(__file__).resolve().parents[2]
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("var isJITProtocolKnown: Bool", coordinator)
        self.assertIn("guard isJITProtocolKnown else", coordinator)

    def test_txm_script_readiness_is_required_before_region_preparation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        header = (root / "iSteam" / "JIT26Protocol.h").read_text(encoding="utf-8")
        self.assertIn("#include <stdatomic.h>", source)
        self.assertIn("static atomic_bool g_txm_script_ready = ATOMIC_VAR_INIT(false);", source)
        self.assertIn("atomic_load_explicit(&g_txm_script_ready, memory_order_acquire)", source)
        self.assertIn("void iSteamJITSetTXMScriptReady(bool ready)", source)
        self.assertIn("bool iSteamJITIsDebuggerAttached(void)", source)
        self.assertIn("void *iSteamJITPrepareRegionIfReady(void *address, size_t length)", source)
        self.assertIn("iSteamJITSetTXMScriptReady(bool ready);", header)
        self.assertIn("iSteamJITPrepareRegionIfReady(void *address, size_t length);", header)
        self.assertIn("protocolMode != ISTEAM_JIT_PROTOCOL_STIKDEBUG", source)


if __name__ == "__main__":
    unittest.main()
