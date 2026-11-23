import unittest
from pathlib import Path


class GuestMemoryTypedWriteTests(unittest.TestCase):
    def test_x86_interpreter_32_bit_memory_writes_do_not_allocate_data(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        test = (root / "scripts" / "tests" / "test_x86_64_interpreter.swift").read_text(encoding="utf-8")
        typed_write = memory.split("func writeUInt32", 1)[1].split("func writeUInt64", 1)[0]
        write_operand = interpreter.split("private func writeOperand", 1)[1].split("private func operandAddress", 1)[0]
        self.assertIn("isteam_guest_memory_write(native, offset, base, 4)", typed_write)
        self.assertIn("return memory.writeUInt32(word, offset: address)", write_operand)
        self.assertNotIn("Data([", write_operand)
        self.assertIn("func writeUInt32(_ value: UInt32, offset: UInt64)", test)


if __name__ == "__main__":
    unittest.main()
