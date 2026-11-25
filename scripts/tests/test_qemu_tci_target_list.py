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
        command = block + chr(10) + 'printf "%s" "$TCI_GUEST_TARGETS"'
        return subprocess.run(
            ["bash", "-c", command],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_default_target_is_x86_64_softmmu(self) -> None:
        result = self.run_target_list()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "x86_64-softmmu")

    def test_explicit_supported_multiarch_target_list_is_preserved(self) -> None:
        expected = patch_utm_qemu_ios.TCI_TARGET_LIST_UPSTREAM
        result = self.run_target_list(expected)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)

    def test_shell_metacharacters_are_rejected(self) -> None:
        result = self.run_target_list("x86_64-softmmu;touch /tmp/not-allowed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid ISTEAM_QEMU_TCI_TARGET_LIST", result.stderr)



    def test_target_list_patch_is_idempotent_and_preserves_other_flags(self) -> None:
        source = (
            'TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list='
            + patch_utm_qemu_ios.TCI_TARGET_LIST_UPSTREAM
            + ' --enable-debug"'
            + chr(10)
        )
        once = patch_utm_qemu_ios.patch_tci_target_list(source)
        twice = patch_utm_qemu_ios.patch_tci_target_list(once)
        self.assertEqual(once, twice)
        self.assertIn('TCI_GUEST_TARGETS="${ISTEAM_QEMU_TCI_TARGET_LIST:-x86_64-softmmu}"', once)
        self.assertIn("--target-list=$TCI_GUEST_TARGETS --enable-debug", once)
        self.assertNotIn(patch_utm_qemu_ios.TCI_TARGET_LIST_UPSTREAM, once)

    def test_incomplete_existing_target_override_fails_closed(self) -> None:
        with self.assertRaisesRegex(SystemExit, "incomplete"):
            patch_utm_qemu_ios.patch_tci_target_list('TCI_GUEST_TARGETS="incomplete"')

if __name__ == "__main__":
    unittest.main()
