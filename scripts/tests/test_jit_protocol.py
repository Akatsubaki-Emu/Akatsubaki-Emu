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

    def test_txm_detection_matches_stikdebug_hardware_rules(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn("#include <sys/utsname.h>", source)
        self.assertIn("uname(&systemInfo) != 0", source)
        self.assertIn('strcmp(hardwareIdentifier, "iPad8,11") == 0', source)
        self.assertIn('strcmp(hardwareIdentifier, "iPad8,12") == 0', source)
        self.assertIn('sscanf(hardwareIdentifier, "iPhone%d,%d"', source)
        self.assertIn('sscanf(hardwareIdentifier, "iPad%d,%d"', source)
        self.assertIn("minor >= 2", source)
        self.assertIn("minor >= 5", source)
        self.assertIn("static int iSteamJITHardwareTXMMode", source)
        self.assertIn("iSteamJITGetProtocolMode(void)", source)
        self.assertIn("ISTEAM_JIT_PROTOCOL_UNKNOWN", source)
        self.assertIn("ISTEAM_JIT_PROTOCOL_STANDARD", source)
        self.assertIn("ISTEAM_JIT_PROTOCOL_STIKDEBUG", source)
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", source)
        self.assertIn("if (__builtin_available(iOS 27.0, *))", source)
        self.assertIn("if (__builtin_available(iOS 26.0, *))", source)

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
