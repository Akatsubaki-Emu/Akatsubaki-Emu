from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MERGER = ROOT / "scripts" / "merge-qemu-runtime-variants.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
BUILD_DOC = ROOT / "docs" / "QEMU_BUILD_WORKFLOW.md"

COMMON_EXPORTS = (
    "qemu_init",
    "qemu_main_loop",
    "qemu_cleanup",
    "qemu_system_shutdown_request",
)


def make_runtime_package(package: Path, library_path: str, *, jit: bool) -> None:
    (package / "Frameworks").mkdir(parents=True)
    (package / "QEMU").mkdir()
    (package / "UTM-SOURCE-REVISION.txt").write_text("test-utm-revision\n", encoding="utf-8")
    (package / "QEMU" / "runtime-library-path.txt").write_text(
        library_path + "\n", encoding="utf-8"
    )
    exports = [f"00000000 T _{symbol}" for symbol in COMMON_EXPORTS]
    if jit:
        exports.append("00000000 T _isteam_qemu_set_jit_callbacks")
    (package / "exports.txt").write_text("\n".join(exports) + "\n", encoding="utf-8")
    library = package / library_path
    library.parent.mkdir(parents=True)
    library.write_bytes(b"fake device-arm64 QEMU runtime\n")
    (package / "QEMU" / "machine.conf").write_text("machine=test\n", encoding="utf-8")


class QEMURuntimeManifestTests(unittest.TestCase):
    def test_merger_emits_root_jit_compatibility_manifest_and_both_mode_manifests(self):
        with tempfile.TemporaryDirectory(prefix="akatsubaki-qemu-manifests-") as temporary:
            temporary_root = Path(temporary)
            workspace = temporary_root / "workspace"
            workspace.mkdir()
            jit_package = temporary_root / "jit-package"
            tci_package = temporary_root / "tci-package"
            jit_library = "Frameworks/QEMU.framework/QEMU"
            tci_input_library = "Frameworks/TCI.framework/TCI"
            make_runtime_package(jit_package, jit_library, jit=True)
            make_runtime_package(tci_package, tci_input_library, jit=False)

            completed = subprocess.run(
                [
                    "bash",
                    str(MERGER),
                    str(jit_package),
                    str(tci_package),
                    "build/qemu-runtime",
                ],
                cwd=workspace,
                check=True,
                capture_output=True,
                text=True,
            )
            merged = workspace / "build" / "qemu-runtime"
            tci_merged_library = "Frameworks/TCI/TCI.framework/TCI"

            self.assertIn("Merged JIT and no-JIT TCI runtime variants", completed.stdout)
            self.assertEqual(
                (merged / "QEMU" / "runtime-library-path.txt").read_text(encoding="utf-8").strip(),
                jit_library,
            )
            self.assertEqual(
                (merged / "QEMU" / "JIT" / "runtime-library-path.txt").read_text(encoding="utf-8").strip(),
                jit_library,
            )
            self.assertEqual(
                (merged / "QEMU" / "TCI" / "runtime-library-path.txt").read_text(encoding="utf-8").strip(),
                tci_merged_library,
            )
            self.assertTrue((merged / jit_library).is_file())
            self.assertTrue((merged / tci_merged_library).is_file())
            self.assertTrue((merged / "QEMU" / "JIT" / "exports.txt").is_file())
            self.assertTrue((merged / "QEMU" / "TCI" / "exports.txt").is_file())
            self.assertIn(f"JIT={jit_library}", (merged / "QEMU" / "runtime-mode-manifest.txt").read_text(encoding="utf-8"))
            self.assertIn(f"TCI={tci_merged_library}", (merged / "QEMU" / "runtime-mode-manifest.txt").read_text(encoding="utf-8"))

    def test_release_validates_and_embeds_both_runtime_modes(self):
        release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        required_contract = (
            'JIT_MANIFEST="$RUNTIME_DIR/QEMU/JIT/runtime-library-path.txt"',
            'TCI_MANIFEST="$RUNTIME_DIR/QEMU/TCI/runtime-library-path.txt"',
            'JIT_EXPORTS="$RUNTIME_DIR/QEMU/JIT/exports.txt"',
            'TCI_EXPORTS="$RUNTIME_DIR/QEMU/TCI/exports.txt"',
            'test "$COMPAT_RUNTIME_REL" = "$JIT_RUNTIME_REL"',
            'grep -Eq \' _?isteam_qemu_set_jit_callbacks$\' "$JIT_EXPORTS"',
            'grep -Eq \' _?isteam_qemu_set_jit_callbacks$\' "$TCI_EXPORTS"',
            'cp -R "$RUNTIME_DIR/QEMU/." "$APP/QEMU/"',
            'test -s "$APP/$JIT_RUNTIME_REL"',
            'test -s "$APP/$TCI_RUNTIME_REL"',
            'cmp -s "$APP/QEMU/JIT/runtime-library-path.txt" "$JIT_MANIFEST"',
            'cmp -s "$APP/QEMU/TCI/runtime-library-path.txt" "$TCI_MANIFEST"',
        )
        for token in required_contract:
            with self.subTest(token=token):
                self.assertIn(token, release)
        self.assertNotIn(
            'RUNTIME_REL="$(head -n 1 "$RUNTIME_DIR/QEMU/runtime-library-path.txt")"',
            release,
        )

    def test_build_documentation_distinguishes_packaged_tci_from_device_verified_tci(self):
        documentation = BUILD_DOC.read_text(encoding="utf-8")
        self.assertIn("QEMU/JIT/", documentation)
        self.assertIn("QEMU/TCI/", documentation)
        self.assertIn("physical iPad", documentation)
        self.assertIn("compatibility pointer", documentation)


if __name__ == "__main__":
    unittest.main()
