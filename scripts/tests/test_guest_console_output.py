import unittest
from pathlib import Path


class GuestConsoleOutputTests(unittest.TestCase):
    def test_emulation_log_publishes_sanitized_messages(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Core" / "EmulationLog.swift").read_text(encoding="utf-8")
        write = source.split("func write(_ message: String)", 1)[1].split("private func append", 1)[0]
        self.assertIn("static let emulationLogDidWrite", source)
        self.assertIn("NotificationCenter.default.post(", write)
        self.assertIn("name: .emulationLogDidWrite", write)
        self.assertIn('"userInfo: ["message": safeMessage]', write)

    def test_console_displays_only_guest_stdout_and_stderr(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "ConsoleViewController.swift").read_text(encoding="utf-8")
        self.assertIn("forName: .emulationLogDidWrite", source)
        self.assertIn("object: nil", source)
        self.assertIn('let stdoutPrefix = "[guest stdout] "', source)
        self.assertIn('let stderrPrefix = "[guest stderr] "', source)
        self.assertIn("NotificationCenter.default.removeObserver(logObserver)", source)

    def test_console_output_is_bounded_and_scrolls_to_latest_output(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "ConsoleViewController.swift").read_text(encoding="utf-8")
        output = source.split("private func appendGuestOutput", 1)[1].split("private func appendStatus", 1)[0]
        self.assertIn("maximumConsoleCharacters = 128 * 1024", output)
        self.assertIn("textView.text.suffix(maximumConsoleCharacters)", output)
        self.assertIn("textView.scrollRangeToVisible", output)


if __name__ == "__main__":
    unittest.main()
