from __future__ import annotations

import platform
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_SCRIPT = ROOT / "scripts" / "build_hybrid_stdin_smoke_elf.py"
SCRIPT = REPOSITORY_SCRIPT if REPOSITORY_SCRIPT.is_file() else Path(__file__).resolve().with_name("build_hybrid_stdin_smoke_elf.py")
READY = b"KENRAN_BUTO_STDIN_READY\n"
PREFIX = b"KENRAN_BUTO_STDIN_ECHO:"
DONE = b"KENRAN_BUTO_STDIN_OK\n"
EXPECTED = READY + PREFIX + b"hello\n" + DONE


class HybridStdinSmokeELFTests(unittest.TestCase):
    def test_generates_static_elf_with_blocking_stdin_echo(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "hybrid_stdin_smoke.elf"
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
            self.assertEqual(fields[10], 2)
            rx = struct.unpack_from("<IIQQQQQQ", image, 64)
            rw = struct.unpack_from("<IIQQQQQQ", image, 120)
            self.assertEqual((rx[0], rx[1], rx[2], rx[3], rx[5], rx[6]), (1, 5, 0, 0x400000, 0x2000, 0x2000))
            self.assertEqual((rw[0], rw[1], rw[2], rw[3], rw[6]), (1, 6, 0x2000, 0x402000, 0x1000))
            self.assertGreater(rw[5], 1)
            self.assertLessEqual(rw[5], rw[6])
            self.assertEqual(rw[5], len(image) - 0x2000)
            self.assertEqual(len(image), 0x2000 + rw[5])
            code = image[0x1000:0x1200]
            self.assertIn(bytes.fromhex("31 c0 31 ff 48 8d 74 24 80"), code)
            self.assertIn(bytes.fromhex("48 89 c3"), code)
            self.assertIn(bytes.fromhex("48 89 da"), code)
            self.assertIn(b"\x0f\x05", code)
            self.assertEqual(image[0x1200:0x1200 + len(READY)], READY)
            self.assertEqual(image[0x1220:0x1220 + len(PREFIX)], PREFIX)
            self.assertEqual(image[0x1240:0x1240 + len(DONE)], DONE)
            if sys.platform == "linux" and platform.machine().lower() in {"x86_64", "amd64"}:
                completed = subprocess.run([str(output)], input=b"hello\n", capture_output=True, check=False, timeout=5)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, EXPECTED)
                self.assertEqual(completed.stderr, b"")


if __name__ == "__main__":
    unittest.main()
