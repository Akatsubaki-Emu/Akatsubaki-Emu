import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "embed-qemu-runtime.sh"
LIFECYCLE = ["qemu_init", "qemu_main_loop", "qemu_cleanup", "qemu_system_shutdown_request"]
CALLBACK = "isteam_qemu_set_jit_callbacks"


def export_report(symbols):
    return "".join(f"0000000000000000 T _{symbol}\n" for symbol in symbols)


class QEMURuntimeEmbeddingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"
        self.app = self.root / "iSteam.app"
        (self.runtime / "Frameworks" / "QEMU.framework").mkdir(parents=True)
        (self.runtime / "Frameworks" / "TCI" / "QEMU.framework").mkdir(parents=True)
        (self.runtime / "QEMU" / "JIT").mkdir(parents=True)
        (self.runtime / "QEMU" / "TCI").mkdir(parents=True)
        self.app.mkdir()
        (self.runtime / "Frameworks" / "QEMU.framework" / "QEMU").write_bytes(b"jit")
        (self.runtime / "Frameworks" / "TCI" / "QEMU.framework" / "QEMU").write_bytes(b"tci")
        for mode, relative in (
            ("JIT", "Frameworks/QEMU.framework/QEMU"),
            ("TCI", "Frameworks/TCI/QEMU.framework/QEMU"),
        ):
            qemu = self.runtime / "QEMU" / mode
            (qemu / "runtime-library-path.txt").write_text(relative + "\n", encoding="utf-8")
            symbols = LIFECYCLE + ([CALLBACK] if mode == "JIT" else [])
            (qemu / "exports.txt").write_text(export_report(symbols), encoding="utf-8")
            (qemu / "bios.bin").write_bytes(mode.encode())

    def tearDown(self):
        self.temp.cleanup()

    def run_embed(self):
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.runtime), str(self.app)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_embeds_both_modes_using_their_own_manifests(self):
        result = self.run_embed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Frameworks/QEMU.framework/QEMU").read_bytes(), b"jit")
        self.assertEqual((self.app / "Frameworks/TCI/QEMU.framework/QEMU").read_bytes(), b"tci")
        self.assertEqual(
            (self.app / "QEMU/JIT/runtime-library-path.txt").read_text().strip(),
            "Frameworks/QEMU.framework/QEMU",
        )
        self.assertEqual(
            (self.app / "QEMU/TCI/runtime-library-path.txt").read_text().strip(),
            "Frameworks/TCI/QEMU.framework/QEMU",
        )
        self.assertFalse((self.app / "QEMU/runtime-library-path.txt").exists())

    def test_rejects_tci_runtime_with_stikjit_callback(self):
        tci_exports = self.runtime / "QEMU/TCI/exports.txt"
        tci_exports.write_text(export_report(LIFECYCLE + [CALLBACK]), encoding="utf-8")
        result = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TCI runtime unexpectedly exports the StikJIT callback", result.stderr)

    def test_rejects_jit_runtime_without_stikjit_callback(self):
        jit_exports = self.runtime / "QEMU/JIT/exports.txt"
        jit_exports.write_text(export_report(LIFECYCLE), encoding="utf-8")
        result = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JIT runtime is missing the StikJIT callback export", result.stderr)

    def test_rejects_manifest_path_traversal(self):
        manifest = self.runtime / "QEMU/TCI/runtime-library-path.txt"
        manifest.write_text("Frameworks/../../outside.dylib\n", encoding="utf-8")
        result = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe component", result.stderr)

    def test_rejects_library_symlink_that_escapes_runtime_package(self):
        outside = self.root / "outside.dylib"
        outside.write_bytes(b"outside")
        library = self.runtime / "Frameworks/TCI/QEMU.framework/QEMU"
        library.unlink()
        library.symlink_to(outside)
        result = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves outside the runtime package", result.stderr)

    def test_rejects_missing_tci_mode_manifest(self):
        (self.runtime / "QEMU/TCI/runtime-library-path.txt").unlink()
        result = self.run_embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TCI runtime-library-path.txt is missing", result.stderr)

    def test_release_workflow_uses_mode_aware_embedding_script(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn('bash scripts/embed-qemu-runtime.sh "$RUNTIME_DIR" "$APP"', workflow)
        self.assertNotIn('RUNTIME_DIR/QEMU/runtime-library-path.txt', workflow)


if __name__ == "__main__":
    unittest.main()
