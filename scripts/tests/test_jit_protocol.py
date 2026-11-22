import unittest
from pathlib import Path


class JITProtocolSourceTests(unittest.TestCase):
    def test_breakpoint_protocol_exports_prepare_and_detach(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        header = (root / "iSteam" / "JIT26Protocol.h").read_text(encoding="utf-8")
        self.assertIn('"brk #0xf00d\\n"', source)
        self.assertIn('"mov x16, #1\\n"', source)
        detach = source.split("void iSteamJITDetach(void) {", 1)[1].split("\n}", 1)[0]
        self.assertIn("compatibility", detach)
        self.assertIn("no-op", detach)
        self.assertNotIn("brk #0xf00d", detach)
        self.assertNotIn("mov x16, #0", detach)
        self.assertIn("bool iSteamJITIsReady(void)", source)
        self.assertIn("bool iSteamJITIsReady(void);", header)

    def test_jit_readiness_requires_cs_debugged(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn('dlsym(RTLD_DEFAULT, "csops")', source)
        self.assertIn("queryStatus(getpid(), 0, &status, sizeof(status)) == 0", source)
        self.assertIn("status & UINT32_C(0x10000000)", source)
        self.assertIn("bool iSteamJITIsReady(void) { return false; }", source)

    def test_txm_detection_uses_stikjit_ioregistry_query_and_fails_closed(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        self.assertIn("#include <IOKit/IOKitLib.h>", source)
        self.assertIn("IORegistryEntryFromPath(", source)
        self.assertIn('"IODeviceTree:/chosen/memory-map"', source)
        self.assertIn("kIORegistryEntryPropertyKeysKey", source)
        self.assertIn('CFSTR("TXM")', source)
        self.assertIn("CFGetTypeID(keysValue) != CFArrayGetTypeID()", source)
        self.assertIn("CFGetTypeID(key) != CFStringGetTypeID()", source)
        self.assertIn("keyCount == 0", source)
        self.assertIn("return ISTEAM_JIT_PROTOCOL_UNKNOWN;", source)
        self.assertIn("iSteamJITGetProtocolMode()", source)
        self.assertNotIn("uname(&systemInfo)", source)
        self.assertNotIn("sscanf(hardwareIdentifier", source)

    def test_live_debugger_is_required_only_for_txm_breakpoint_protocol(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        readiness = source.split("bool iSteamJITIsReady(void) {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("protocolMode == ISTEAM_JIT_PROTOCOL_UNKNOWN", readiness)
        self.assertIn("protocolMode == ISTEAM_JIT_PROTOCOL_STIKDEBUG", readiness)
        self.assertIn("return iSteamJITDebuggerIsAttached();", readiness)
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


    def test_ios_targets_link_iokit_and_export_the_protocol_mode(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count("- sdk: IOKit.framework"), 2)
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

if __name__ == "__main__":
    unittest.main()
