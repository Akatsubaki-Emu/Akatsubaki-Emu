import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LinuxELFRuntimeInitializationTests(unittest.TestCase):
    def test_guest_machine_retains_typed_initialization_errors(self):
        source = (ROOT / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")

        self.assertIn("private(set) var initializationError: GuestEngineError?", source)
        self.assertIn("let error = GuestEngineError.memoryUnavailable", source)
        self.assertIn("let error = GuestEngineError.backendNotInstalled(configuration.architecture)", source)
        self.assertIn("self.initializationError = error", source)
        self.assertIn("initializationError = nil", source)

    def test_linux_elf_runtime_propagates_initialization_error(self):
        source = (ROOT / "src" / "Steam" / "GameLauncher.swift").read_text(encoding="utf-8")

        self.assertIn("let initializationError = machine.initializationError", source)
        self.assertIn("result: .failure(initializationError)", source)
        self.assertNotIn("result: .failure(GuestEngineError.memoryUnavailable)", source)

        capture = source.index("let initializationError = machine.initializationError")
        stop = source.index("machine.stop()", capture)
        propagate = source.index("result: .failure(initializationError)", capture)
        self.assertLess(capture, stop)
        self.assertLess(stop, propagate)


if __name__ == "__main__":
    unittest.main()
