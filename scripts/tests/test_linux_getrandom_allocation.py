import unittest
from pathlib import Path


class LinuxGetRandomAllocationTests(unittest.TestCase):
    def test_getrandom_fills_one_data_buffer_without_mapping_an_array(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        random = source.split("private func getRandom", 1)[1].split("private func writeTimespec", 1)[0]
        self.assertIn("var data = Data(count: count)", random)
        self.assertIn("data.withUnsafeMutableBytes", random)
        self.assertIn("generator.next().littleEndian", random)
        self.assertIn("MemoryLayout<UInt64>.size", random)
        self.assertIn("copyMemory(from: sourceBase", random)
        self.assertNotIn("UInt8.random", random)
        self.assertNotIn("(0..<Int(length)).map", random)


if __name__ == "__main__":
    unittest.main()
