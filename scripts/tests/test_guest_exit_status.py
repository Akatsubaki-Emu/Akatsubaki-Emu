from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class GuestExitStatusTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_exit_status_is_preserved_across_runtime_layers(self) -> None:
        machine = self.read("src/Runtime/GuestMachine.swift")
        interpreter = self.read("src/Runtime/X86_64Interpreter.swift")
        syscalls = self.read("src/Runtime/LinuxSyscallDispatcher.swift")
        console = self.read("iSteam/ConsoleViewController.swift")
        static_test = self.read("scripts/tests/test_static_elf_execution.swift")

        self.assertIn("case exited(Int32)", machine)
        self.assertIn("case .halted, .exited(_): state = .stopped", machine)
        self.assertIn("case .exited(let status)", interpreter)
        self.assertIn("return .exited(status)", interpreter)
        self.assertIn("return .exited(Int32(arg0 & 0xFF))", syscalls)
        self.assertIn("case .success(.exited(let status)):", console)
        self.assertGreaterEqual(static_test.count("exit == .exited(0)"), 2)

    def test_interpreter_covers_exit_and_exit_group_status_semantics(self) -> None:
        tests = self.read("scripts/tests/test_x86_64_interpreter.swift")
        self.assertIn("(60, 0, 0)", tests)
        self.assertIn("(60, 7, 7)", tests)
        self.assertIn("(60, 256, 0)", tests)
        self.assertIn("(231, UInt32.max, 255)", tests)


if __name__ == "__main__":
    unittest.main()
