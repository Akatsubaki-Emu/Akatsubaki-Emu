#!/usr/bin/env python3
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "merge-qemu-runtime-variants.sh"


class QEMURuntimeMergeTests(unittest.TestCase):
    def package(self, root: Path, mode: str, shared: str = "identical",
                revision: str = "rev-1", tci_callback: bool = False) -> Path:
        package = root / mode
        shutil.rmtree(package, ignore_errors=True)
        framework = "QEMU.framework" if mode == "jit" else "QEMU-TCI.framework"
        (package / "Frameworks" / framework).mkdir(parents=True)
        (package / "Frameworks" / "Shared.framework").mkdir(parents=True)
        (package / "QEMU").mkdir(parents=True)
        (package / "Frameworks" / framework / "QEMU").write_text(mode + "-runtime")
        (package / "Frameworks" / "Shared.framework" / "shared").write_text(shared)
        (package / "QEMU" / "runtime-library-path.txt").write_text(
            f"Frameworks/{framework}/QEMU\n", encoding="utf-8"
        )
        exports = (
            "qemu_init\nqemu_main_loop\nqemu_cleanup\n"
            "qemu_system_shutdown_request\n"
        )
        if mode == "jit" or tci_callback:
            exports += "isteam_qemu_set_jit_callbacks\n"
        (package / "exports.txt").write_text(exports, encoding="utf-8")
        (package / "UTM-SOURCE-REVISION.txt").write_text(revision + "\n", encoding="utf-8")
        (package / "BUILD-INFO.txt").write_text(mode + " package", encoding="utf-8")
        return package

    def run_merge(self, root: Path, jit: Path, tci: Path):
        return subprocess.run(
            ["bash", str(SCRIPT), str(jit), str(tci), "build/merged"],
            cwd=root, text=True, capture_output=True,
        )

    def test_merges_both_runtime_variants_and_identical_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build").mkdir()
            jit = self.package(root, "jit")
            tci = self.package(root, "tci")
            result = self.run_merge(root, jit, tci)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = root / "build" / "merged"
            self.assertTrue((output / "Frameworks/QEMU.framework/QEMU").is_file())
            self.assertTrue((output / "Frameworks/QEMU-TCI.framework/QEMU").is_file())
            self.assertTrue((output / "QEMU/JIT/runtime-library-path.txt").is_file())
            self.assertTrue((output / "QEMU/TCI/runtime-library-path.txt").is_file())
            self.assertTrue((output / "QEMU/JIT/exports.txt").is_file())
            self.assertTrue((output / "QEMU/TCI/exports.txt").is_file())
            self.assertIn(
                "UTM_REVISION=rev-1",
                (output / "QEMU/runtime-mode-manifest.txt").read_text(encoding="utf-8"),
            )

    def test_rejects_different_shared_framework_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build").mkdir()
            jit = self.package(root, "jit", shared="jit-dependency")
            tci = self.package(root, "tci", shared="tci-dependency")
            result = self.run_merge(root, jit, tci)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different JIT/TCI dependency bytes", result.stderr)

    def test_rejects_mismatched_utm_revisions_and_jit_callback_in_tci(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build").mkdir()
            jit = self.package(root, "jit", revision="rev-1")
            tci = self.package(root, "tci", revision="rev-2")
            result = self.run_merge(root, jit, tci)
            self.assertIn("different UTM revisions", result.stderr)
            tci = self.package(root, "tci", revision="rev-1", tci_callback=True)
            result = self.run_merge(root, jit, tci)
            self.assertIn("unexpectedly contains the StikJIT callback", result.stderr)


if __name__ == "__main__":
    unittest.main()
