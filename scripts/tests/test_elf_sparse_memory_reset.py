import unittest
from pathlib import Path


class ELFSparseMemoryResetTests(unittest.TestCase):
    def test_guest_machine_does_not_clear_memory_twice_on_success(self):
        root = Path(__file__).resolve().parents[2]
        machine = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        load = machine.split("func loadELFImage", 1)[1].split("func reset", 1)[0]
        before_loader = load.split("let image = try ELF64Loader().load", 1)[0]
        self.assertNotIn("memory.clear()", before_loader)
        self.assertEqual(load.count("memory.clear()"), 1)
        self.assertIn("memory.clear()\n        for (segment, fileOffset) in pending", loader)
        self.assertIn("guard memory.beginMapping() else {\n            memory.clear()", loader)
        self.assertGreaterEqual(loader.count("memory.clear()"), 5)


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
