import unittest
from pathlib import Path


class X86InstructionWindowTests(unittest.TestCase):
    def test_instruction_bytes_are_prefetched_once_per_instruction(self):
        root = Path(__file__).resolve().parents[2]
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        self.assertIn("prepareInstructionWindow(at: instructionAddress)", interpreter)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", interpreter)
        fetch32 = interpreter.split("private func fetchUInt32()", 1)[1].split("private func fetchUInt64()", 1)[0]
        fetch64 = interpreter.split("private func fetchUInt64()", 1)[1].split("private func decodeRM", 1)[0]
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 4", fetch32)
        self.assertIn("memory.readUInt32(offset: rip)", fetch32)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 8", fetch64)
        self.assertIn("memory.readUInt64(offset: rip)", fetch64)
        self.assertIn("UInt64(instructionWindow[offset + 7]) << 56", fetch64)
        self.assertNotIn("for shift in 0..<8", fetch64)
        self.assertIn("func readPrefix(offset: UInt64, into buffer: inout [UInt8]) -> Int?", memory)
        self.assertNotIn("instructionWindowOffset", interpreter)
        self.assertNotIn("Data(count: 15)", interpreter)


if __name__ == "__main__":
    unittest.main()
