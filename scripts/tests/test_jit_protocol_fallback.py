import unittest
from pathlib import Path


class JITProtocolFallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.source = (root / "iSteam" / "JIT26Protocol.c").read_text(encoding="utf-8")
        cls.header = (root / "iSteam" / "JIT26Protocol.h").read_text(encoding="utf-8")
        cls.fallback = cls.source.rsplit("#else", 1)[1].split("#endif", 1)[0]

    def test_simulator_fallback_exports_unknown_protocol_mode(self):
        self.assertIn("int iSteamJITGetProtocolMode(void);", self.header)
        self.assertIn("int iSteamJITGetProtocolMode(void) { return ISTEAM_JIT_PROTOCOL_UNKNOWN; }", self.fallback)

    def test_simulator_fallback_never_claims_jit_readiness(self):
        self.assertIn("bool iSteamJITIsSupported(void) { return false; }", self.fallback)
        self.assertIn("bool iSteamJITIsReady(void) { return false; }", self.fallback)
        self.assertIn("void *iSteamJITPrepareRegion(void *address, size_t length)", self.fallback)


if __name__ == "__main__":
    unittest.main()
