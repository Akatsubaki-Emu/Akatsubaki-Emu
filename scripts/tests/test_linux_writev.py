import unittest
from pathlib import Path


class LinuxWritevContractTests(unittest.TestCase):
    def test_writev_is_bounded_and_uses_guest_memory(self):
        source = Path("src/Runtime/LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("case 20:", source)
        self.assertIn("writeVector(descriptor: arg0, vectors: arg1, count: arg2)", source)
        self.assertIn("maximumVectorCount: UInt64 = 1024", source)
        self.assertIn("maximumVectorBytes: UInt64 = 1_048_576", source)
        write_vector = source.split("private func writeVector", 1)[1].split("private func logGuestOutput", 1)[0]
        self.assertIn("count.multipliedReportingOverflow(by: 16)", write_vector)
        self.assertIn("memory.read(offset: vectors, length: Int(tableByteCount))", write_vector)
        self.assertIn("raw.loadUnaligned(fromByteOffset: entryOffset, as: UInt64.self)", write_vector)
        self.assertIn("raw.loadUnaligned(fromByteOffset: entryOffset + 8, as: UInt64.self)", write_vector)
        self.assertIn("var output = Data(count: Int(total))", write_vector)
        self.assertIn("into: &output, destinationOffset: destinationOffset", write_vector)
        self.assertNotIn("readUInt64Pair", write_vector)
        self.assertNotIn("output.append(bytes)", write_vector)
        self.assertIn("logGuestOutput(output, descriptor: descriptor)", source)
        self.assertIn("return errno(9)", source)
        self.assertIn("return errno(14)", source)
        self.assertIn("return errno(22)", source)


    def test_guest_memory_read_into_avoids_intermediate_data_allocations(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        read_into = memory.split("func read(offset: UInt64, length: Int, into:", 1)[1].split("func readByte", 1)[0]
        self.assertIn("destinationOffset <= data.count", read_into)
        self.assertIn("length <= data.count - destinationOffset", read_into)
        self.assertIn("base.advanced(by: destinationOffset)", read_into)
        self.assertIn("isteam_guest_memory_read(native, offset, destination, length)", read_into)

    def test_writev_is_documented_as_a_limited_guest_syscall(self):
        docs = Path("docs/HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("bounded writev", docs)


if __name__ == "__main__":
    unittest.main()
