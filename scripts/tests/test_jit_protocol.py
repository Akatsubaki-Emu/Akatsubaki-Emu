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

    def test_jit_readiness_requires_cs_debugged_and_live_txm_debugger(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn('dlsym(RTLD_DEFAULT, "csops")', source)
        self.assertIn("queryStatus(getpid(), 0, &status, sizeof(status)) == 0", source)
        self.assertIn("status & UINT32_C(0x10000000)", source)
        self.assertIn("#include <sys/sysctl.h>", source)
        self.assertIn("(info.kp_proc.p_flag & P_TRACED) != 0", source)

    def test_txm_detection_uses_stikjit_ioregistry_query(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn("#include <IOKit/IOKitLib.h>", source)
        self.assertIn("IORegistryEntryFromPath(", source)
        self.assertIn('"IODeviceTree:/chosen/memory-map"', source)
        self.assertIn("kIORegistryEntryPropertyKeysKey", source)
        self.assertIn('CFSTR("TXM")', source)
        self.assertIn("CFGetTypeID(keysValue) != CFArrayGetTypeID()", source)
        self.assertIn("CFGetTypeID(key) != CFStringGetTypeID()", source)
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", source)
        self.assertIn("return iSteamJITHardwareTXMMode();", source)
        self.assertNotIn("sscanf(hardwareIdentifier", source)
        self.assertNotIn("uname(&systemInfo)", source)

    def test_unknown_txm_state_blocks_jit_and_qemu_protocol_selection(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        patcher = (root / "scripts" / "patch_qemu_stikjit_ios.py").read_text(encoding="utf-8")
        mode = source.split("static int iSteamJITHardwareTXMMode(void)", 1)[1].split(
            "int iSteamJITGetProtocolMode(void)", 1
        )[0]
        readiness = source.split("bool iSteamJITIsReady(void) {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", mode)
        self.assertIn("protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN", readiness)
        self.assertIn("iSteamJITGetProtocolMode() >= 0", coordinator)
        self.assertIn("jit_protocol_mode < 0", patcher)

    def test_ios_targets_link_iokit_for_txm_detection(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count("- sdk: IOKit.framework"), 2)

    def test_live_debugger_is_required_only_for_txm_breakpoint_protocol(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        readiness = source.split("bool iSteamJITIsReady(void) {", 1)[1].split("\n}\n", 1)[0]
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
