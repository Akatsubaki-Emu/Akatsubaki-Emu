import unittest
from pathlib import Path


class X86ConditionHotPathTests(unittest.TestCase):
    def test_condition_checks_only_the_flags_needed_by_each_branch(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "X86_64ALU.swift").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        method = source[source.index("static func condition"):source.index("private static func makeFlags8")]
        for unused in ("let cf =", "let zf =", "let sf =", "let of ="):
            self.assertNotIn(unused, method)
        self.assertIn("for code in UInt8(0)...UInt8(15)", tests)
        self.assertIn("for combination in 0..<32", tests)


if __name__ == "__main__":
    unittest.main()
