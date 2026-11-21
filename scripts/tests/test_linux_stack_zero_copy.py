import unittest
from pathlib import Path


class LinuxStackCopyTests(unittest.TestCase):
    def test_stack_vector_writes_and_final_copy_avoid_intermediate_data(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxProcessStackBuilder.swift").read_text(encoding="utf-8")
        test = (root / "scripts" / "tests" / "test_linux_process_stack.swift").read_text(encoding="utf-8")
        vector = source.split("let vectorBytes", 1)[1].split("let stackPointer", 1)[0]
        final_write = source.split("let stackPointer", 1)[1].split("let argumentVectorAddress", 1)[0]
        self.assertIn("buffer.withUnsafeMutableBytes", vector)
        self.assertIn("copyMemory(from: source, byteCount: 8)", vector)
        self.assertNotIn("Data($0)", vector)
        self.assertNotIn("replaceSubrange", vector)
        self.assertIn("memory.write(buffer, sourceRange: vectorStart..<Self.stackSize", final_write)
        self.assertNotIn("subdata(in:", final_write)
        self.assertIn("func write(_ data: Data, sourceRange: Range<Int>", test)


if __name__ == "__main__":
    unittest.main()
