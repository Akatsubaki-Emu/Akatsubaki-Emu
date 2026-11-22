import unittest
from pathlib import Path


class X86OpcodeDispatchTests(unittest.TestCase):
    def test_conditional_branch_decode_avoids_temporary_opcode_array(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        self.assertNotIn(".contains(second)", source)
        self.assertIn("second >= 0x80 && second <= 0x8F", source)


if __name__ == "__main__":
    unittest.main()
