import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src" / "Runtime" / "X86_64Interpreter.swift"


class InterpreterStopLockingTests(unittest.TestCase):
    def test_all_stop_flag_reads_use_the_locking_helper(self):
        source = SOURCE.read_text(encoding="utf-8")
        helper = re.search(
            r"private func shouldStopExecution\(\) -> Bool\s*\{(?P<body>.*?)\n    \}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(helper, "stop-state helper must exist")
        body = helper.group("body")
        self.assertIn("stopLock.lock()", body)
        self.assertIn("defer { stopLock.unlock() }", body)
        self.assertIn("return stopRequested", body)
        self.assertNotRegex(source, r"\bif\s+stopRequested\b")
        self.assertNotRegex(source, r"let\s+\w+\s*=\s*stopRequested\b")
        self.assertGreaterEqual(source.count("shouldStopExecution()"), 3)


if __name__ == "__main__":
    unittest.main()
