import unittest
from pathlib import Path


class LinuxStackCopyTests(unittest.TestCase):
    def test_stack_vector_writes_and_final_copy_avoid_intermediate_data(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxProcessStackBuilder.swift").read_text(encoding="utf-8")
        test = (root / "scripts" / "tests" / "test_linux_process_stack.swift").read_text(encoding="utf-8")
        vector = source.split("let vectorBytes", 1)[1].split("let stackPointer = stackBase", 1)[0]
        final_write = source.split("let stackPointer = stackBase", 1)[1].split("let argumentVectorAddress", 1)[0]
        self.assertIn("buffer.withUnsafeMutableBytes", vector)
        self.assertIn("copyMemory(from: source, byteCount: 8)", vector)
        self.assertNotIn("Data($0)", vector)
        self.assertNotIn("replaceSubrange", vector)
        self.assertIn("memory.write(buffer, sourceRange: vectorStart..<Self.stackSize", final_write)
        self.assertNotIn("subdata(in:", final_write)
        self.assertIn("func write(_ data: Data, sourceRange: Range<Int>", test)


    def test_stack_builder_avoids_temporary_argument_environment_and_word_arrays(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxProcessStackBuilder.swift").read_text(encoding="utf-8")
        self.assertNotIn("let argv =", source)
        self.assertNotIn("let envp =", source)
        self.assertNotIn("argv + envp", source)
        self.assertNotIn("var words: [UInt64]", source)
        self.assertIn("let argumentCount = arguments.count + 1", source)
        self.assertIn("let environmentKeys = environment.keys.sorted()", source)
        self.assertIn("for value in arguments.reversed()", source)
        self.assertIn("for key in environmentKeys.reversed()", source)
        self.assertIn("argumentPointers.reserveCapacity(argumentCount)", source)
        self.assertIn("environmentPointers.reserveCapacity(environmentKeys.count)", source)
        self.assertIn("let vectorWordCount", source)
        self.assertIn("writeWord(UInt64(argumentCount))", source)


if __name__ == "__main__":
    unittest.main()
