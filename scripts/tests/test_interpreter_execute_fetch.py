from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")


class InterpreterExecuteFetchTests(unittest.TestCase):
    def test_instruction_fetch_slow_path_checks_execute_permission(self):
        fetch = SOURCE.split("private func fetchByte() -> UInt8? {", 1)[1].split(
            "private func fetchUInt16()", 1
        )[0]
        self.assertIn("memory.readExecuteByte(offset: rip)", fetch)
        self.assertNotIn("memory.readByte(offset: rip)", fetch)

    def test_instruction_window_stays_bounded_to_one_instruction(self):
        self.assertIn("private var instructionWindow = [UInt8](repeating: 0, count: 15)", SOURCE)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", SOURCE)


if __name__ == "__main__":
    unittest.main()
