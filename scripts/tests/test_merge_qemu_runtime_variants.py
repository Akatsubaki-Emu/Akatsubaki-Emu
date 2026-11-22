import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "merge-qemu-runtime-variants.sh"
LIFECYCLE = ["qemu_init", "qemu_main_loop", "qemu_cleanup", "qemu_system_shutdown_request"]


def make_package(root: Path, mode: str, *, revision: str = "utm-revision-1", callback: bool | None = None,
                 missing_symbol: str | None = None, qemu_bytes: str | None = None,
                 shared_bytes: str = "shared dependency") -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "Frameworks" / "QEMU.framework").mkdir(parents=True)
    (root / "Frameworks" / "Shared.framework").mkdir(parents=True)
    (root / "QEMU").mkdir()
    (root / "UTM-SOURCE-REVISION.txt").write_text(revision + "\n", encoding="utf-8")
    (root / "Frameworks" / "QEMU.framework" / "QEMU").write_text(
        qemu_bytes if qemu_bytes is not None else mode + " qemu binary", encoding="utf-8"
    )
    (root / "Frameworks" / "Shared.framework" / "Shared").write_text(shared_bytes, encoding="utf-8")
    (root / "QEMU" / "runtime-library-path.txt").write_text(
        "Frameworks/QEMU.framework/QEMU\n", encoding="utf-8"
    )
    symbols = [symbol for symbol in LIFECYCLE if symbol != missing_symbol]
    include_callback = mode == "jit" if callback is None else callback
    if include_callback:
        symbols.append("isteam_qemu_set_jit_callbacks")
    (root / "exports.txt").write_text("\n".join(symbols) + "\n", encoding="utf-8")
    (root / "BUILD-INFO.txt").write_text(mode + " build\n", encoding="utf-8")
    (root / "QEMU" / "bios.bin").write_text(mode + " bios\n", encoding="utf-8")
    return root


class MergeQEMURuntimeVariantsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.build = self.root / "build"
        self.build.mkdir()
        self.jit = make_package(self.build / "jit", "jit")
        self.tci = make_package(self.build / "tci", "tci")

    def tearDown(self):
        self.temp.cleanup()

    def run_merge(self, output="build/merged", jit=None, tci=None):
        return subprocess.run(
            ["bash", str(SCRIPT), str(jit or self.jit), str(tci or self.tci), output],
            cwd=self.root, capture_output=True, text=True, check=False,
        )

    def test_valid_merge_separates_qemu_frameworks_and_rewrites_tci_manifest(self):
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.build / "merged"
        self.assertEqual((output / "Frameworks/QEMU.framework/QEMU").read_text(), "jit qemu binary")
        self.assertEqual((output / "Frameworks/TCI/QEMU.framework/QEMU").read_text(), "tci qemu binary")
        self.assertEqual((output / "Frameworks/Shared.framework/Shared").read_text(), "shared dependency")
        self.assertEqual((output / "QEMU/JIT/runtime-library-path.txt").read_text().strip(),
                         "Frameworks/QEMU.framework/QEMU")
        self.assertEqual((output / "QEMU/TCI/runtime-library-path.txt").read_text().strip(),
                         "Frameworks/TCI/QEMU.framework/QEMU")
        self.assertTrue((output / "QEMU/JIT/bios.bin").is_file())
        self.assertTrue((output / "QEMU/TCI/bios.bin").is_file())

    def test_rejects_path_traversal_without_deleting_outside_sentinel(self):
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel.txt"
        sentinel.write_text("preserve me", encoding="utf-8")
        result = self.run_merge("build/../outside")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve me")

    def test_rejects_output_that_contains_an_input_package(self):
        combined = self.build / "combined"
        jit = make_package(combined / "jit", "jit")
        tci = make_package(combined / "tci", "tci")
        result = self.run_merge("build/combined", jit=jit, tci=tci)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((jit / "QEMU/bios.bin").is_file())
        self.assertTrue((tci / "QEMU/bios.bin").is_file())

    def test_rejects_missing_lifecycle_export_from_tci(self):
        tci = make_package(self.build / "bad-tci", "tci", missing_symbol="qemu_system_shutdown_request")
        result = self.run_merge(tci=tci)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("qemu_system_shutdown_request", result.stderr)

    def test_rejects_jit_callback_export_in_tci(self):
        tci = make_package(self.build / "bad-tci", "tci", callback=True)
        result = self.run_merge(tci=tci)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpectedly contains", result.stderr)

    def test_rejects_mismatched_utm_revisions(self):
        tci = make_package(self.build / "bad-tci", "tci", revision="other-revision")
        result = self.run_merge(tci=tci)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different UTM revisions", result.stderr)

    def test_rejects_non_framework_library_manifest(self):
        (self.tci / "QEMU" / "runtime-library-path.txt").write_text("../outside.dylib\n", encoding="utf-8")
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe TCI library path", result.stderr)

    def test_rejects_different_non_qemu_dependency_bytes_and_preserves_existing_output(self):
        tci = make_package(self.build / "bad-tci", "tci", shared_bytes="different shared dependency")
        output = self.build / "merged"
        output.mkdir()
        sentinel = output / "sentinel.txt"
        sentinel.write_text("keep old output", encoding="utf-8")
        result = self.run_merge(tci=tci)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep old output")

    def test_rejects_tci_qemu_framework_symlink_escape(self):
        (self.tci / "Frameworks" / "QEMU.framework" / "escape").symlink_to("../../../../outside")
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes its tree", result.stderr)

    def test_rejects_reserved_tci_framework_directory_collision(self):
        (self.jit / "Frameworks" / "TCI" / "Existing.framework").mkdir(parents=True)
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved Frameworks/TCI path", result.stderr)

    def test_rejects_symlinked_output_directory(self):
        outside = self.root / "outside"
        outside.mkdir()
        output = self.build / "merged"
        output.symlink_to(outside, target_is_directory=True)
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(outside.is_dir())


if __name__ == "__main__":
    unittest.main()
