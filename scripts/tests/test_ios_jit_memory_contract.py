from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
AOT_MEMORY = ROOT / "iSteam/KenranButoAOTExecutableMemory.c"
JIT_COORDINATOR = ROOT / "iSteam/JITCoordinator.swift"
INFO = ROOT / "iSteam/Info.plist"
ENTITLEMENTS = ROOT / "iSteam/iSteam.entitlements"


class IOSJITMemoryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.aot_memory = AOT_MEMORY.read_text(encoding="utf-8")
        cls.jit_coordinator = JIT_COORDINATOR.read_text(encoding="utf-8")
        cls.info = plistlib.loads(INFO.read_bytes())
        cls.entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

    def test_stikdebug_request_targets_the_current_process_and_uses_universal_script(self):
        self.assertIn('components.scheme = "stikdebug"', self.jit_coordinator)
        self.assertIn('components.host = "enable-jit"', self.jit_coordinator)
        self.assertIn('URLQueryItem(name: "bundle-id", value: bundleID)', self.jit_coordinator)
        self.assertIn('URLQueryItem(name: "pid", value: String(getpid()))', self.jit_coordinator)
        self.assertIn('URLQueryItem(name: "script-name", value: "universal.js")', self.jit_coordinator)
        self.assertIn("LocalDevVPNCallback.didConnect", self.jit_coordinator)

    def test_info_plist_declares_companion_schemes_and_bundle_callback(self):
        schemes = self.info.get("LSApplicationQueriesSchemes", [])
        self.assertIn("stikdebug", schemes)
        self.assertIn("localdevvpn", schemes)
        callback_schemes = [
            scheme
            for url_type in self.info.get("CFBundleURLTypes", [])
            for scheme in url_type.get("CFBundleURLSchemes", [])
        ]
        self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER)", callback_schemes)
        self.assertIs(self.info.get("UIFileSharingEnabled"), True)
        self.assertIs(self.info.get("LSSupportsOpeningDocumentsInPlace"), True)

    def test_signing_entitlements_include_debug_attach_and_optional_memory_limits(self):
        self.assertIs(self.entitlements.get("get-task-allow"), True)
        self.assertIs(self.entitlements.get("com.apple.developer.kernel.increased-memory-limit"), True)
        self.assertIs(self.entitlements.get("com.apple.developer.kernel.extended-virtual-addressing"), True)

    def test_aot_allocator_does_not_call_unavailable_ios_pthread_jit_api(self):
        self.assertNotIn("pthread_jit_write_protect_np", self.aot_memory)
        self.assertIn("vm_remap", self.aot_memory)
        self.assertIn("sys_icache_invalidate", self.aot_memory)

    def test_txm_aot_blocks_share_one_page_aligned_executable_arena(self):
        self.assertIn("#define AOT_TXM_ARENA_BYTES (32u * 1024u * 1024u)", self.aot_memory)
        self.assertEqual(self.aot_memory.count("iSteamJITPrepareRegion(NULL,AOT_TXM_ARENA_BYTES)"), 1)
        self.assertIn("iSteamAOTExecutableArenaAllocate", self.aot_memory)
        self.assertIn("iSteamAOTExecutableArenaFree", self.aot_memory)
        self.assertIn("r->arena_owned=true", self.aot_memory)


if __name__ == "__main__":
    unittest.main()
