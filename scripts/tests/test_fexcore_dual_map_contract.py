import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iSteam" / "KenranButoAOTExecutableMemory.c"


def function_body(source, signature, next_signature):
    start = source.index(signature)
    end = source.index(next_signature, start + len(signature))
    return source[start:end]


class FEXCoreDualMapContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.allocate = function_body(
            cls.source,
            "bool iSteamAOTExecutableMemoryAllocateDualMap(",
            "bool iSteamAOTExecutableMemoryFreeDualMap(",
        )
        cls.free = function_body(
            cls.source,
            "bool iSteamAOTExecutableMemoryFreeDualMap(",
            "bool iSteamAOTExecutableMemoryGetDualMapWriteOffset(",
        )

    def test_host_page_size_is_defined_and_used_consistently(self):
        self.assertIn("static size_t host_page_size(void)", self.source)
        self.assertNotIn("sPageSize", self.source)
        self.assertIn("size_t page_size = host_page_size();", self.allocate)
        self.assertIn("size_t page_size = host_page_size();", self.free)
        self.assertIn("size_t hostPage=host_page_size();", self.source)

    def test_new_allocations_are_zero_initialized_after_reservation(self):
        reserve = self.allocate.index("iSteamAOTExecutableArenaAllocate")
        zero = self.allocate.index("memset(rw, 0, rounded_size)")
        self.assertLess(reserve, zero)

    def test_free_validates_and_releases_without_mutating_live_memory(self):
        self.assertIn("iSteamAOTExecutableArenaFree(sTXMArena, offset, mapped_size)", self.free)
        self.assertNotIn("memset(", self.free)
        self.assertIn("mapped_size > AOT_TXM_ARENA_BYTES - offset", self.free)


if __name__ == "__main__":
    unittest.main()
