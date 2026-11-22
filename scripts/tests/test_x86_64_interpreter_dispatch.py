import unittest
from pathlib import Path

class X86InterpreterDispatchTests(unittest.TestCase):
    def test_push_pop_opcode_handlers_are_unique(self):
        source = (Path(__file__).resolve().parents[2] / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        for opcode in ("case 0x50...0x57:", "case 0x58...0x5F:", "case 0x68:", "case 0x6A:"):
            with self.subTest(opcode=opcode):
                self.assertEqual(source.count(opcode), 1)

if __name__ == "__main__":
    unittest.main()
