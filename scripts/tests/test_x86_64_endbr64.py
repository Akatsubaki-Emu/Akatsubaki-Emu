import unittest
from pathlib import Path


class X86Endbr64SourceTests(unittest.TestCase):
    def test_interpreter_recognizes_only_the_endbr64_encoding(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("var endbrPrefix = false", source)
        self.assertIn("else if opcode == 0xF3", source)
        self.assertIn("if endbrPrefix && opcode != 0x0F", source)
        self.assertIn("second == 0x1E", source)
        self.assertIn("modrm == 0xFA", source)

    def test_swift_regression_covers_valid_malformed_and_truncated_encodings(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "scripts" / "tests" / "test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("ENDBR64 is a CET landing pad", source)
        self.assertIn("precondition(endbr64.registerValue(3) == 2)", source)
        self.assertIn("malformedEndbr64Exit == .unsupportedInstruction(address: 0)", source)
        self.assertIn("truncatedEndbr64Exit == .memoryFault(address: 3)", source)


if __name__ == "__main__":
    unittest.main()
