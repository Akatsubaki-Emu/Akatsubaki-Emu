from __future__ import annotations

import platform
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build_hybrid_runtime_smoke_elf.py"
EXPECTED = b"Linuxx86_64KENRAN_BUTO_RUNTIME_OK\n"


class HybridRuntimeSmokeELFTests(unittest.TestCase):
    def test_generates_static_two_segment_elf_with_rw_uname_buffer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "hybrid_runtime_smoke.elf"
            subprocess.run([sys.executable, str(SCRIPT), str(output)], check=True)
            image = output.read_bytes()

            self.assertTrue(output.stat().st_mode & 0o100)
            self.assertEqual(image[:4], b"\x7fELF")
            self.assertEqual(image[4:7], bytes((2, 1, 1)))
            fields = struct.unpack_from("<16sHHIQQQIHHHHHH", image, 0)
            # ELF64 ET_EXEC, not PIE or an interpreter-backed dynamic image.
            self.assertEqual(fields[1], 2)
            self.assertEqual(fields[2], 62)
            self.assertEqual(fields[4], 0x401000)
            self.assertEqual(fields[5], 64)
            self.assertEqual(fields[9], 56)
            self.assertEqual(fields[10], 2)

            rx = struct.unpack_from("<IIQQQQQQ", image, 64)
            rw = struct.unpack_from("<IIQQQQQQ", image, 120)
            self.assertLessEqual(fields[5] + fields[9] * fields[10], rx[2] + rx[5])
            self.assertEqual((rx[0], rx[1], rx[2], rx[3], rx[5], rx[6]),
                             (1, 5, 0, 0x400000, 0x2000, 0x2000))
            self.assertEqual((rw[0], rw[1], rw[2], rw[3], rw[5], rw[6]),
                             (1, 6, 0x2000, 0x402000, 1, 0x1000))
            self.assertEqual(len(image), 0x2001)

            code = image[0x1000:0x1100]
            self.assertIn(bytes.fromhex("bf 00 20 40 00 b8 3f 00 00 00 0f 05"), code)
            self.assertIn(bytes.fromhex("b8 3c 00 00 00 bf 00 00 00 00 0f 05"), code)
            self.assertEqual(
                image[0x1100:0x1100 + len(b"KENRAN_BUTO_RUNTIME_OK\n")],
                b"KENRAN_BUTO_RUNTIME_OK\n",
            )

            if sys.platform == "linux" and platform.machine().lower() in {"x86_64", "amd64"}:
                completed = subprocess.run(
                    [str(output)], capture_output=True, check=False, timeout=5,
                )
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, EXPECTED)
                self.assertEqual(completed.stderr, b"")


if __name__ == "__main__":
    unittest.main()
