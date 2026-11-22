import unittest
from pathlib import Path


class LinuxWritevContractTests(unittest.TestCase):
    def test_writev_is_bounded_and_uses_guest_memory(self):
        source = Path("src/Runtime/LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("case 20:", source)
        self.assertIn("writeVector(descriptor: arg0, vectors: arg1, count: arg2)", source)
        self.assertIn("maximumVectorCount: UInt64 = 1024", source)
        self.assertIn("maximumVectorBytes: UInt64 = 1_048_576", source)
        self.assertIn("addingReportingOverflow(index * 16)", source)
        write_vector = source.split("private func writeVector", 1)[1].split("private func logGuestOutput", 1)[0]
        self.assertIn("memory.readUInt64Pair(offset: entryOffset)", write_vector)
        self.assertNotIn("lengthOffset", write_vector)
        self.assertNotIn("memory.readUInt64(offset:", write_vector)
        self.assertIn("logGuestOutput(output, descriptor: descriptor)", source)
        self.assertIn("return errno(9)", source)
        self.assertIn("return errno(14)", source)
        self.assertIn("return errno(22)", source)


    def test_iovec_pair_is_read_with_one_native_guest_memory_operation(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        pair = memory.split("func readUInt64Pair", 1)[1].split("func writeUInt32", 1)[0]
        self.assertIn("isteam_guest_memory_read(native, offset, base, 16)", pair)
        self.assertIn("UInt64(littleEndian: pair.0)", pair)
        self.assertIn("UInt64(littleEndian: pair.1)", pair)

    def test_writev_is_documented_as_a_limited_guest_syscall(self):
        docs = Path("docs/HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("bounded writev", docs)


if __name__ == "__main__":
    unittest.main()
