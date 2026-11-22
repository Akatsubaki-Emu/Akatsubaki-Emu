import unittest
from pathlib import Path


class X86InstructionWindowTests(unittest.TestCase):
    def test_instruction_bytes_are_prefetched_once_per_instruction(self):
        root = Path(__file__).resolve().parents[2]
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        self.assertIn("prepareInstructionWindow(at: instructionAddress)", interpreter)
        self.assertIn("maximumLength: maximumLength", interpreter)
        self.assertIn("maximumLength: aotMaximumLength", interpreter)
        self.assertIn("private var instructionWindow = [UInt8](repeating: 0, count: 15)", interpreter)
        self.assertIn("private var aotInstructionWindow = [UInt8](repeating: 0, count: 4096)", interpreter)
        self.assertIn("aotIsAvailable = aotExecutor?.isAvailable == true", interpreter)
        self.assertIn("let budget = Int(min(remaining, 256))", interpreter)
        self.assertIn("canStartAOTBlock()", interpreter)
        self.assertIn("instructionWindowCursor < instructionWindowLength", interpreter)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 4", interpreter)
        self.assertIn("instructionWindowLength - instructionWindowCursor >= 8", interpreter)
        self.assertIn("maximumLength: Int? = nil", memory)
        self.assertNotIn("instructionWindowOffset", interpreter)
        self.assertNotIn("Data(count: 15)", interpreter)


if __name__ == "__main__":
    unittest.main()
