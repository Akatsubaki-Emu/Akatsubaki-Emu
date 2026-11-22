import unittest
from pathlib import Path


class X86ConditionDispatchTests(unittest.TestCase):
    def test_supported_branch_conditions_are_nonoptional(self):
        root = Path(__file__).resolve().parents[2]
        alu = (root / "src" / "Runtime" / "X86_64ALU.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("static func condition(_ code: UInt8, flags: UInt64) -> Bool {", alu)
        self.assertIn("case 0x0: return overflowSet", alu)
        self.assertIn("case 0x6: return carrySet || zeroSet", alu)
        self.assertIn("case 0xA: return paritySet", alu)
        self.assertIn("case 0x70...0x7F:", interpreter)
        self.assertIn("second >= 0x80 && second <= 0x8F", interpreter)
        self.assertNotIn("guard let takeBranch = X86_64ALU.condition", interpreter)


if __name__ == "__main__":
    unittest.main()
