import unittest
from pathlib import Path


class X86InstructionWindowTests(unittest.TestCase):
    def test_instruction_bytes_are_prefetched_once_per_instruction(self):
        root = Path(__file__).resolve().parents[2]
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        self.assertIn("prepareInstructionWindow(at: instructionAddress)", interpreter)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", interpreter)
        self.assertIn("instructionWindowCursor < instructionWindowLength", interpreter)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 4", interpreter)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 8", interpreter)
        self.assertIn("func readPrefix(offset: UInt64, maximumLength: Int? = nil, into buffer: inout [UInt8]) -> Int?", memory)
        self.assertNotIn("instructionWindowOffset", interpreter)
        self.assertNotIn("Data(count: 15)", interpreter)


if __name__ == "__main__":
    unittest.main()
