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
        self.assertIn("addingReportingOverflow(8)", source)
        self.assertIn("memory.readUInt64(offset: entryOffset)", source)
        self.assertIn("logGuestOutput(output, descriptor: descriptor)", source)
        self.assertIn("return errno(9)", source)
        self.assertIn("return errno(14)", source)
        self.assertIn("return errno(22)", source)

    def test_writev_is_documented_as_a_limited_guest_syscall(self):
        docs = Path("docs/HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("bounded writev", docs)


if __name__ == "__main__":
    unittest.main()
