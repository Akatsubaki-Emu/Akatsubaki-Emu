import unittest
from pathlib import Path

class X86InterpreterDispatchTests(unittest.TestCase):
    def test_push_pop_opcode_handlers_are_unique(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("case 0x50...0x57:"), 1)
        self.assertEqual(source.count("case 0x58...0x5F:"), 1)
        self.assertNotIn("case 0x68, 0x6A:", source)

if __name__ == "__main__":
    unittest.main()
