"""Behavioral tests for the iOS QEMU TCI guest-target selector."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import patch_utm_qemu_ios


class TCIGuestTargetListTests(unittest.TestCase):
    def run_target_list(self, value: str | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("ISTEAM_QEMU_TCI_TARGET_LIST", None)
        if value is not None:
            env["ISTEAM_QEMU_TCI_TARGET_LIST"] = value
        block = patch_utm_qemu_ios.tci_target_list_shell_block()
        return subprocess.run(
            ["bash", "-c", block + '\\nprintf \"%s\\n\" \"$TCI_GUEST_TARGETS\"'],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_default_target_is_x86_64_softmmu(self) -> None:
        result = self.run_target_list()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "x86_64-softmmu")

    def test_explicit_supported_multiarch_target_list_is_preserved(self) -> None:
        expected = patch_utm_qemu_ios.TCI_TARGET_LIST_UPSTREAM
        result = self.run_target_list(expected)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)

    def test_shell_metacharacters_are_rejected(self) -> None:
        result = self.run_target_list("x86_64-softmmu;touch /tmp/not-allowed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid ISTEAM_QEMU_TCI_TARGET_LIST", result.stderr)


if __name__ == "__main__":
    unittest.main()
