import unittest
from pathlib import Path


class X86WordReadTests(unittest.TestCase):
    def test_word_operands_use_one_bounded_native_read(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("func readUInt16(offset: UInt64) -> UInt16?", memory)
        self.assertIn("isteam_guest_memory_read(native, offset, base, 2)", memory)
        self.assertIn("return memory.readUInt16(offset: address)", interpreter)
        self.assertIn("readUInt16Calls == 1", tests)
        self.assertIn("readByteCalls == 0", tests)
        self.assertNotIn("memory.readByte(offset: nextAddress)", interpreter)


if __name__ == "__main__":
    unittest.main()
