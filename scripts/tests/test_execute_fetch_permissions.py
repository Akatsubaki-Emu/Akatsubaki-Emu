import pathlib
import unittest


class ExecutableFetchTests(unittest.TestCase):
    def test_instruction_window_and_wide_fallbacks_require_execute_permission(self):
        source = (
            pathlib.Path(__file__).parents[2] / "src/Runtime/X86_64Interpreter.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", source)
        helper = source.split("private func readExecutableInteger", 1)[1].split(
            "private func fetchUInt32", 1
        )[0]
        self.assertIn("memory.readExecuteByte(offset: byteAddress)", helper)
        self.assertNotIn("memory.readUInt32(offset: rip)", source)
        self.assertNotIn("memory.readUInt64(offset: rip)", source)


if __name__ == "__main__":
    unittest.main()
