import unittest
from pathlib import Path


class X86StackInstructionTests(unittest.TestCase):
    def test_register_and_immediate_push_pop_are_implemented(self):
        source = Path("src/Runtime/X86_64Interpreter.swift").read_text(encoding="utf-8")
        for token in (
            "case 0x50...0x57: // PUSH r64",
            "case 0x58...0x5F: // POP r64",
            "case 0x68: // PUSH sign-extended imm32",
            "case 0x6A: // PUSH sign-extended imm8",
            "addingReportingOverflow(8)",
            "if index == 4",
        ):
            self.assertIn(token, source)

    def test_functional_regressions_cover_rex_b_sign_extension_and_stack_faults(self):
        tests = Path("scripts/tests/test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        for token in (
            "let registerStackMemory",
            "let extendedStackMemory",
            "let immediateByteStackMemory",
            "let immediateDwordStackMemory",
            "let popStackPointerMemory",
            "let stackUnderflowMemory",
            "0xFFFFFFFFFFFFFF80",
            "0xFFFFFFFF80000000",
            "stackUnderflowExit == .memoryFault(address: 0)",
        ):
            self.assertIn(token, tests)
        docs = Path("docs/HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("direct register/immediate PUSH and register POP", docs)


if __name__ == "__main__":
    unittest.main()
