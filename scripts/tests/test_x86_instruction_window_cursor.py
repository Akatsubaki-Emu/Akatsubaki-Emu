import unittest
from pathlib import Path


class X86InstructionWindowTests(unittest.TestCase):
    def test_instruction_bytes_are_prefetched_once_per_instruction(self):
        root = Path(__file__).resolve().parents[2]
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")

        self.assertIn("prepareInstructionWindow(at: instructionAddress)", interpreter)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", interpreter)
        self.assertIn("instructionWindowCursor <= instructionWindowLength", interpreter)
        self.assertIn("instructionWindowCursor = 0", interpreter)

        fetch_byte = interpreter.split("private func fetchByte()", 1)[1].split("private func fetchUInt16()", 1)[0]
        fetch16 = interpreter.split("private func fetchUInt16()", 1)[1].split("private func fetchUInt32()", 1)[0]
        fetch32 = interpreter.split("private func fetchUInt32()", 1)[1].split("private func fetchUInt64()", 1)[0]
        fetch64 = interpreter.split("private func fetchUInt64()", 1)[1].split("private func readUInt64(at address:", 1)[0]

        for fetch, width in ((fetch_byte, 1), (fetch16, 2), (fetch32, 4), (fetch64, 8)):
            self.assertIn(f"ensureInstructionWindowContains({width})", fetch)
            self.assertIn(f"instructionWindowCursor += {width}", fetch)
            self.assertIn(f"rip &+= {width}", fetch)

        self.assertNotIn("instructionWindowCursor < instructionWindowLength", interpreter)
        self.assertIn("func readPrefix(offset: UInt64, into buffer: inout [UInt8]) -> Int?", memory)
        self.assertNotIn("instructionWindowOffset", interpreter)
        self.assertNotIn("Data(count: 15)", interpreter)


if __name__ == "__main__":
    unittest.main()
