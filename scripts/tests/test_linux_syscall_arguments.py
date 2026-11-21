import unittest
from pathlib import Path


class LinuxSyscallArgumentTests(unittest.TestCase):
    def test_guest_syscalls_do_not_allocate_argument_array(self):
        root = Path(__file__).resolve().parents[2]
        dispatcher = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_linux_syscall_dispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("func dispatch(number: UInt64, arg0: UInt64, arg1: UInt64, arg2: UInt64,", dispatcher)
        self.assertIn("return dispatch(number: number, arg0: arguments[0]", dispatcher)
        self.assertIn("arg5: registers[9]", interpreter)
        self.assertNotIn("let arguments = [registers[7]", interpreter)
        self.assertIn("scalarIdentity", tests)
        self.assertIn("arguments: [0]) == nil", tests)


if __name__ == "__main__":
    unittest.main()
