from __future__ import annotations

import platform
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build_hybrid_xchg_smoke_elf.py"


class HybridXCHGSmokeELFTests(unittest.TestCase):
    def test_generates_valid_static_x86_64_elf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "hybrid_xchg_smoke.elf"
            subprocess.run([sys.executable, str(SCRIPT), str(output)], check=True)
            image = output.read_bytes()

            self.assertTrue(output.stat().st_mode & 0o100)
            self.assertEqual(image[:4], b"\x7fELF")
            self.assertEqual(image[4:7], bytes((2, 1, 1)))

            fields = struct.unpack_from("<16sHHIQQQIHHHHHH", image, 0)
            self.assertEqual(fields[1], 2)
            self.assertEqual(fields[2], 62)
            self.assertEqual(fields[4], 0x401000)
            self.assertEqual(fields[5], 64)
            self.assertEqual(fields[9], 56)
            self.assertEqual(fields[10], 1)

            phdr = struct.unpack_from("<IIQQQQQQ", image, 64)
            self.assertEqual(phdr[0], 1)
            self.assertEqual(phdr[1], 5)
            self.assertEqual(phdr[2], 0)
            self.assertEqual(phdr[3], 0x400000)
            self.assertEqual(phdr[5], len(image))
            self.assertEqual(phdr[6], len(image))
            self.assertEqual(phdr[7], 0x1000)

            guest_code = image[0x1000:]
            self.assertEqual(guest_code[10], 0x91)
            self.assertIn(bytes.fromhex("49 91"), guest_code)
            self.assertEqual(guest_code.count(bytes.fromhex("83 f8 00 75")), 2)
            lea = guest_code.index(bytes.fromhex("48 8d 35"))
            displacement = struct.unpack_from("<i", guest_code, lea + 3)[0]
            message_offset = lea + 7 + displacement
            self.assertEqual(guest_code[message_offset:], b"hello\n")
            self.assertEqual(guest_code.count(bytes.fromhex("0f 05")), 3)

            if sys.platform == "linux" and platform.machine().lower() in {"x86_64", "amd64"}:
                completed = subprocess.run(
                    [str(output)], capture_output=True, check=False, timeout=5,
                )
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, b"hello\n")
                self.assertEqual(completed.stderr, b"")

                # Corrupt each XCHG input independently: its CMP/JNE guard must
                # take the failure path instead of printing a false success.
                for label, immediate_offset in (("xchg32", 0x1000 + 6), ("xchg64", 0x1000 + 18)):
                    broken = bytearray(image)
                    broken[immediate_offset] = 1
                    broken_path = Path(temporary) / f"{label}-failure.elf"
                    broken_path.write_bytes(broken)
                    broken_path.chmod(0o755)
                    failed = subprocess.run(
                        [str(broken_path)], capture_output=True, check=False, timeout=5,
                    )
                    self.assertEqual(failed.returncode, 1, label)
                    self.assertEqual(failed.stdout, b"", label)
                    self.assertEqual(failed.stderr, b"", label)


if __name__ == "__main__":
    unittest.main()
