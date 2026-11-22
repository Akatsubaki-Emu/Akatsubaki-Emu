import unittest
from pathlib import Path


class X86ConditionDispatchTests(unittest.TestCase):
    def test_supported_branch_conditions_are_nonoptional(self):
        root = Path(__file__).resolve().parents[2]
        alu = (root / "src" / "Runtime" / "X86_64ALU.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        condition = alu.split("static func condition(_ code: UInt8, flags: UInt64) -> Bool {", 1)[1].split("private static func makeFlags8", 1)[0]
        self.assertIn("case 0x0: return flags & overflow != 0", condition)
        self.assertIn("case 0x6: return flags & (carry | zero) != 0", condition)
        self.assertIn("case 0xA: return flags & parity != 0", condition)
        self.assertIn("case 0xF: return flags & zero == 0 && (flags & sign != 0) == (flags & overflow != 0)", condition)
        self.assertNotIn("let carrySet", condition)
        self.assertIn("case 0x70...0x7F:", interpreter)
        self.assertIn("second >= 0x80 && second <= 0x8F", interpreter)
        self.assertIn("case 0xF6: // TEST, NOT and NEG r/m8", interpreter)
        self.assertIn("case 0xFE: // INC and DEC r/m8", interpreter)
        self.assertIn("second >= 0x40 && second <= 0x4F", interpreter)
        self.assertIn("second >= 0x90 && second <= 0x9F", interpreter)
        self.assertIn("second == 0x1F", interpreter)
        self.assertIn("guard let _ = decodeRM(modrm, rex: rex) else {", interpreter)
        self.assertNotIn("guard let takeBranch = X86_64ALU.condition", interpreter)


if __name__ == "__main__":
    unittest.main()
