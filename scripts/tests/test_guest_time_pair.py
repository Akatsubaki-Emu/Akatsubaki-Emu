import unittest
from pathlib import Path


class GuestTimePairWriteTests(unittest.TestCase):
    def test_timespec_and_timeval_use_one_native_16_byte_write(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        syscalls = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        pair = memory.split("func writeUInt64Pair", 1)[1].split("func writeUInt64(", 1)[0]
        timespec = syscalls.split("private func writeTimespec", 1)[1].split("private func writeTimeval", 1)[0]
        timeval = syscalls.split("private func writeTimeval", 1)[1].split("private func errno", 1)[0]
        self.assertIn("isteam_guest_memory_write(native, offset, base, 16)", pair)
        self.assertIn("memory.writeUInt64Pair(seconds, nanoseconds, offset: address)", timespec)
        self.assertIn("memory.writeUInt64Pair(seconds, microseconds, offset: address)", timeval)
        self.assertNotIn("memory.writeUInt64(seconds", timespec + timeval)


if __name__ == "__main__":
    unittest.main()
