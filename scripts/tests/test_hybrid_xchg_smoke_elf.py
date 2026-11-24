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
            for opcode in ("49 91", "45 87 c8", "4d 87 da"):
                self.assertIn(bytes.fromhex(opcode), guest_code)
            self.assertEqual(guest_code.count(bytes.fromhex("0f 85")), 8)
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

                # Corrupt one operand for each XCHG encoding independently:
                # every register-pair check must take the nonzero failure path.
                cases = (
                    ("accumulator32", bytes.fromhex("b9 00 00 00 00"), 1, 1),
                    ("accumulator64", bytes.fromhex("49 b9 00 00 00 00 00 00 00 00"), 2, 1),
                    ("modrm32", bytes.fromhex("41 b9 01 00 00 00"), 2, 0),
                    ("modrm64", bytes.fromhex("49 bb 01 00 00 00 00 00 00 00"), 2, 0),
                )
                for label, instruction, immediate_offset, replacement in cases:
                    broken = bytearray(image)
                    instruction_offset = broken.index(instruction, 0x1000)
                    broken[instruction_offset + immediate_offset] = replacement
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
