#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_qemu_tci_exports


BASE_EXPORTS = """{
  qemu_init;
  qemu_main_loop;
  qemu_cleanup;
};
"""


class QEMUTCIXportTests(unittest.TestCase):
    def test_tci_exports_add_shutdown_and_remove_jit_callback(self):
        source = BASE_EXPORTS.replace("};", "  isteam_qemu_set_jit_callbacks;\n};")
        patched = patch_qemu_tci_exports.patch_exported_symbols(source)
        self.assertIn("qemu_system_shutdown_request;", patched)
        self.assertNotIn("isteam_qemu_set_jit_callbacks;", patched)
        self.assertEqual(patched.count("qemu_system_shutdown_request;"), 1)

    def test_patch_is_idempotent(self):
        once = patch_qemu_tci_exports.patch_exported_symbols(BASE_EXPORTS)
        twice = patch_qemu_tci_exports.patch_exported_symbols(once)
        self.assertEqual(once, twice)

    def test_missing_lifecycle_export_is_rejected(self):
        source = BASE_EXPORTS.replace("  qemu_cleanup;\n", "")
        with self.assertRaisesRegex(SystemExit, "qemu_cleanup"):
            patch_qemu_tci_exports.patch_exported_symbols(source)

    def test_duplicate_shutdown_export_is_rejected(self):
        source = BASE_EXPORTS.replace("};", "  qemu_system_shutdown_request;\n  qemu_system_shutdown_request;\n};")
        with self.assertRaisesRegex(SystemExit, "duplicate shutdown"):
            patch_qemu_tci_exports.patch_exported_symbols(source)

    def test_duplicate_jit_callback_is_rejected(self):
        source = BASE_EXPORTS.replace("};", "  isteam_qemu_set_jit_callbacks;\n  isteam_qemu_set_jit_callbacks;\n};")
        with self.assertRaisesRegex(SystemExit, "duplicate StikJIT"):
            patch_qemu_tci_exports.patch_exported_symbols(source)

    def test_export_file_is_updated_idempotently(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "qemu.symbols"
            path.write_text(BASE_EXPORTS.replace("};", "  isteam_qemu_set_jit_callbacks;\n};"), encoding="utf-8")
            patch_qemu_tci_exports.patch_file(path)
            once = path.read_text(encoding="utf-8")
            patch_qemu_tci_exports.patch_file(path)
            self.assertEqual(path.read_text(encoding="utf-8"), once)
            self.assertIn("qemu_system_shutdown_request;", once)
            self.assertNotIn("isteam_qemu_set_jit_callbacks;", once)


if __name__ == "__main__":
    unittest.main()
