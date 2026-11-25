from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INTERPRETER = ROOT / "src" / "Runtime" / "X86_64Interpreter.swift"


class AOTWindowBudgetTests(unittest.TestCase):
    def test_aot_fetch_window_is_bounded_by_instruction_budget(self) -> None:
        source = INTERPRETER.read_text(encoding="utf-8")
        self.assertIn("private static let maximumAOTInstructionBatch = 16", source)
        self.assertIn("private static let maximumX86InstructionLength = 15", source)
        self.assertIn(
            "private var aotInstructionWindow = [UInt8](repeating: 0, count: 240)",
            source,
        )
        fetch = source.split("let maximumAOTBytes = min(", 1)[1].split(
            "let aotWindowLength", 1
        )[0]
        self.assertIn("aotPageRemaining", fetch)
        self.assertIn("budget * Self.maximumX86InstructionLength", fetch)
        self.assertIn("maximumLength: maximumAOTBytes", source)
        self.assertEqual(16 * 15, 240)

    def test_aot_eligibility_and_fetch_both_enforce_page_boundary(self) -> None:
        source = INTERPRETER.read_text(encoding="utf-8")
        eligibility = source.split("private func canStartAOTBlock() -> Bool {", 1)[1].split(
            "private func canTranslateRegisterXCHGAtCurrentWindow", 1
        )[0]
        self.assertIn("let pageRemaining = 4096 - Int(rip & 0xFFF)", eligibility)
        self.assertIn("cursor < min(instructionWindowLength, pageRemaining)", eligibility)
        self.assertIn("case 0x98, 0x99:", eligibility)
        self.assertIn("cursor + 2 <= pageRemaining", eligibility)
        self.assertIn("instructionEnd <= pageRemaining", eligibility)
        self.assertIn("let aotPageRemaining = 4096 - Int(instructionAddress & 0xFFF)", source)


if __name__ == "__main__":
    unittest.main()
