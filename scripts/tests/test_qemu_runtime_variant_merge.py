import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
MERGER = REPOSITORY / "scripts" / "merge-qemu-runtime-variants.sh"
TCI_PACKAGER = REPOSITORY / "scripts" / "package-utm-qemu-tci-runtime.sh"


def make_package(root: Path, mode: str, shared_bytes: bytes = b"shared dependency"):
    package = root / "build" / f"qemu-runtime-{mode}"
    framework = "QEMU.framework" if mode == "jit" else "QEMU-TCI.framework"
    library = f"Frameworks/{framework}/QEMU"
    (package / "Frameworks" / framework).mkdir(parents=True)
    (package / "QEMU" / "firmware").mkdir(parents=True)
    (package / library).write_bytes((mode + " runtime").encode())
    (package / "Frameworks" / "libshared.dylib").write_bytes(shared_bytes)
    (package / "QEMU" / "runtime-library-path.txt").write_text(library + "\n", encoding="utf-8")
    (package / "UTM-SOURCE-REVISION.txt").write_text("revision-1\n", encoding="utf-8")
    (package / "BUILD-INFO.txt").write_text(mode + " build\n", encoding="utf-8")
    (package / "dependency-report.txt").write_text("dependencies\n", encoding="utf-8")
    (package / "runtime-file-inventory.txt").write_text("runtime\n", encoding="utf-8")
    (package / "QEMU" / "firmware" / "OVMF_CODE.fd").write_bytes(b"firmware")
    exports = [
        "_qemu_init",
        "_qemu_main_loop",
        "_qemu_cleanup",
        "_qemu_system_shutdown_request",
    ]
    if mode == "jit":
        exports.append("_isteam_qemu_set_jit_callbacks")
    (package / "exports.txt").write_text("\n".join(exports) + "\n", encoding="utf-8")
    return package


class QEMURuntimeVariantMergeTests(unittest.TestCase):
    def _copy_merger(self, root: Path) -> Path:
        scripts = root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        destination = scripts / "merge-qemu-runtime-variants.sh"
        shutil.copy2(MERGER, destination)
        return destination

    def test_shell_scripts_parse(self):
        for script in (MERGER, TCI_PACKAGER):
            result = subprocess.run(["bash", "-n", str(script)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, f"{script.name}: {result.stderr}")

    def test_output_path_traversal_is_rejected_before_outside_data_is_touched(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = self._copy_merger(root)
            sentinel = root / "outside"
            sentinel.write_text("keep me", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(script), "build/jit", "build/tci", "build/../outside"],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep me")
            self.assertIn("simple directory name beneath build", result.stderr)

    def test_merger_keeps_jit_and_tci_frameworks_distinct(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = self._copy_merger(root)
            make_package(root, "jit")
            make_package(root, "tci")
            result = subprocess.run(
                ["bash", str(script), "build/qemu-runtime-jit", "build/qemu-runtime-tci", "build/combined"],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            output = root / "build" / "combined"
            self.assertTrue((output / "Frameworks" / "QEMU.framework" / "QEMU").is_file())
            self.assertTrue((output / "Frameworks" / "TCI" / "QEMU-TCI.framework" / "QEMU").is_file())
            self.assertEqual(
                (output / "QEMU" / "JIT" / "runtime-library-path.txt").read_text(encoding="utf-8").strip(),
                "Frameworks/QEMU.framework/QEMU",
            )
            self.assertEqual(
                (output / "QEMU" / "TCI" / "runtime-library-path.txt").read_text(encoding="utf-8").strip(),
                "Frameworks/TCI/QEMU-TCI.framework/QEMU",
            )
            self.assertIn("isteam_qemu_set_jit_callbacks", (output / "QEMU" / "JIT" / "exports.txt").read_text(encoding="utf-8"))
            self.assertNotIn("isteam_qemu_set_jit_callbacks", (output / "QEMU" / "TCI" / "exports.txt").read_text(encoding="utf-8"))

    def test_merger_rejects_different_bytes_for_shared_framework_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = self._copy_merger(root)
            make_package(root, "jit", b"jit dependency")
            make_package(root, "tci", b"tci dependency")
            result = subprocess.run(
                ["bash", str(script), "build/qemu-runtime-jit", "build/qemu-runtime-tci", "build/combined"],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different JIT/TCI dependency bytes", result.stderr)
            self.assertFalse((root / "build" / "combined").exists())


if __name__ == "__main__":
    unittest.main()
