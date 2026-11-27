import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Runtime" / "GuestBlockDevice.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GuestBlockDevicePositionalIOTests(unittest.TestCase):
    def test_reads_use_pread_without_mutating_shared_file_offset(self):
        read = section("    func read(lba:", "    func write(")
        self.assertIn("pread(", read)
        self.assertNotIn("handle.seek(", read)
        self.assertNotIn("handle.read(", read)

    def test_writes_use_pwrite_without_mutating_shared_file_offset(self):
        write = section("    func write(", "    func synchronize(")
        self.assertIn("pwrite(", write)
        self.assertNotIn("handle.seek(", write)
        self.assertNotIn("handle.write(", write)

    def test_partial_io_and_interrupts_are_handled(self):
        self.assertEqual(SOURCE.count("if errno == EINTR { continue }"), 2)
        self.assertIn("guard amount > 0 else { throw DeviceError.shortRead }", SOURCE)
        self.assertIn("guard amount > 0 else { throw DeviceError.shortWrite }", SOURCE)

    def test_bounds_and_transfer_limit_remain_in_force(self):
        self.assertIn("UInt64(count) <= sectorCount - lba", SOURCE)
        self.assertIn("byteCount <= UInt64(Self.maximumTransferBytes)", SOURCE)
        self.assertIn("data.count <= Self.maximumTransferBytes", SOURCE)
        self.assertIn("lock.lock()", SOURCE)


if __name__ == "__main__":
    unittest.main()
