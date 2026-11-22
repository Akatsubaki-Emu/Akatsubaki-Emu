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

    def test_txm_protocol_is_resolved_by_the_isolated_stikjit_helper(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn("static atomic_int gJITProtocolOverride", source)
        self.assertIn("atomic_load_explicit", source)
        self.assertIn("atomic_store_explicit", source)
        self.assertIn("iSteamJITSetProtocolOverride", source)
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", source)
        self.assertNotIn("uname(", source)
        self.assertNotIn("sscanf(", source)
        self.assertNotIn("iSteamJITHardwareTXMMode", source)

    def test_unknown_txm_mode_is_not_guessed_before_helper_confirmation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        mode = source.split("int iSteamJITGetProtocolMode(void)", 1)[1].split(
            "bool iSteamJITIsSupported(void)", 1
        )[0]
        self.assertIn("ISTEAM_JIT_PROTOCOL_UNKNOWN", mode)
        self.assertIn("iSteamJITSetProtocolOverride", source)


    def test_live_debugger_is_required_only_for_txm_breakpoint_protocol(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        readiness = source.split("bool iSteamJITIsReady(void) {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("int protocolMode = iSteamJITGetProtocolMode();", readiness)
        self.assertIn("if (protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN)", readiness)
        self.assertIn("if (protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG)", readiness)
        self.assertIn("return iSteamJITDebuggerIsAttached();", readiness)
        self.assertTrue(readiness.rstrip().endswith("return true;"))

    def test_qemu_uses_breakpoint_allocator_only_when_txm_is_present(self):
        root = Path(__file__).resolve().parents[2]
        patcher = (root / "scripts" / "patch_qemu_stikjit_ios.py").read_text(encoding="utf-8")
        self.assertIn('dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")', patcher)
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
            for symbol in ("iSteamJITGetProtocolMode", "iSteamJITIsSupported", "iSteamJITIsReady", "iSteamJITPrepareRegion", "iSteamJITDetach"):
                self.assertIn("-Wl,-exported_symbol,_" + symbol, block)


if __name__ == "__main__":
    unittest.main()
