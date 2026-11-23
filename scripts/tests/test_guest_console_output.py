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
        self.assertIn('userInfo: ["message": safeMessage]', write)

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


    def test_observer_test_is_wired_into_github_actions(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-ios-build.yml").read_text(encoding="utf-8")
        command = "swiftc -parse-as-library -swift-version 5 src/Core/EmulationLog.swift scripts/tests/test_emulation_log_observer.swift"
        self.assertIn(command, workflow)
        self.assertFalse((root / ".gitlab-ci.yml").exists())

    def test_aot_translation_and_cache_tests_are_wired_into_github_actions(self):
        root = Path(__file__).resolve().parents[2]
        source = (
            root / ".github" / "workflows" / "validate-kenran-buto-aot.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("X86_64AOTTranslator.swift", source)
        self.assertIn("test_kenran_buto_aot_translator.swift", source)
        self.assertIn("KenranButoAOTCompiler.swift", source)
        self.assertIn("test_kenran_buto_aot_cache.swift", source)
        self.assertNotIn("src/Runtime/KenranButoAOT.swift", source)
        self.assertFalse((root / ".gitlab-ci.yml").exists())


if __name__ == "__main__":
    unittest.main()
