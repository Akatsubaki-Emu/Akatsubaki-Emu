import unittest
from pathlib import Path


class X86InstructionWindowTests(unittest.TestCase):
    def test_instruction_bytes_are_prefetched_once_per_instruction(self):
        root = Path(__file__).resolve().parents[2]
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")

        self.assertIn("prepareInstructionWindow(at: instructionAddress)", interpreter)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", interpreter)

        ensure = interpreter.split("private func ensureInstructionWindowContains", 1)[1].split("private func fetchByte()", 1)[0]
        self.assertIn("instructionWindowCursor <= instructionWindowLength", ensure)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= byteCount", ensure)
        self.assertIn("instructionWindowLength == instructionWindow.count", ensure)
        self.assertIn("refillInstructionWindow(at: rip, generation: memory.mutationGeneration)", ensure)

        fetch_byte = interpreter.split("private func fetchByte()", 1)[1].split("private func fetchUInt16()", 1)[0]
        fetch16 = interpreter.split("private func fetchUInt16()", 1)[1].split("private func fetchUInt32()", 1)[0]
        fetch32 = interpreter.split("private func fetchUInt32()", 1)[1].split("private func fetchUInt64()", 1)[0]
        fetch64 = interpreter.split("private func fetchUInt64()", 1)[1].split("private func readUInt64(at address:", 1)[0]

        self.assertIn("ensureInstructionWindowContains(1)", fetch_byte)
        self.assertNotIn("memory.readByte(offset: rip)", fetch_byte)
        self.assertIn("ensureInstructionWindowContains(2)", fetch16)
        self.assertIn("raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)", fetch16)
        self.assertIn("ensureInstructionWindowContains(4)", fetch32)
        self.assertIn("raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)", fetch32)
        self.assertNotIn("memory.readUInt32(offset: rip)", fetch32)
        self.assertIn("ensureInstructionWindowContains(8)", fetch64)
        self.assertIn("raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)", fetch64)
        self.assertNotIn("memory.readUInt64(offset: rip)", fetch64)

        self.assertIn("func readPrefix(offset: UInt64, into buffer: inout [UInt8]) -> Int?", memory)
        self.assertNotIn("instructionWindowOffset", interpreter)
        self.assertNotIn("Data(count: 15)", interpreter)


if __name__ == "__main__":
    unittest.main()
