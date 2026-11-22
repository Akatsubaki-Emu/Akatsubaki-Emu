import unittest
from pathlib import Path


class ELFSparseMemoryResetTests(unittest.TestCase):
    def test_loader_relies_on_clear_and_zero_initialized_guest_pages(self):
        root = Path(__file__).resolve().parents[2]
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        native = (root / "iSteam" / "NativeGuestMemory.cpp").read_text(encoding="utf-8")
        reset = loader.split("memory.clear()", 1)[1].split("for (segment, fileOffset)", 1)[0]
        self.assertNotIn("memory.zero(", reset)
        self.assertIn("new (std::nothrow) Page{}", native)
        self.assertIn("memory->pages.clear()", native)


if __name__ == "__main__":
    unittest.main()
