import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class InterpreterStopPollingTests(unittest.TestCase):
    def test_stop_polling_uses_a_bounded_1024_instruction_interval(self):
        source = (ROOT / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        run_loop = source.split(
            "func run(maxInstructions: UInt64) throws -> GuestCPUExit", 1
        )[1].split("private func dispatchArchPrctl", 1)[0]
        self.assertIn("if executed & 0x3ff == 0", run_loop)
        self.assertNotIn("if executed & 0xff == 0", run_loop)
        self.assertIn("1024 guest instructions", run_loop)

    def test_concurrent_stop_regression_is_in_the_interpreter_harness(self):
        tests = (ROOT / "scripts" / "tests" / "test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("concurrentStopMemory", tests)
        self.assertIn("DispatchQueue.global(qos: .userInitiated).asyncAfter", tests)
        self.assertIn("concurrentStopExit == .interrupted", tests)


if __name__ == "__main__":
    unittest.main()
