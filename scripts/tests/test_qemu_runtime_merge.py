import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SOURCE_SCRIPT = Path(__file__).resolve().parents[1] / "merge-qemu-runtime-variants.sh"


class QEMURuntimeMergeTests(unittest.TestCase):
    def make_repository(self, temporary_root: Path) -> Path:
        repo = temporary_root / "repo"
        scripts = repo / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SOURCE_SCRIPT, scripts / "merge-qemu-runtime-variants.sh")
        (repo / "build").mkdir()
        return repo

    def write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def make_package(self, repo: Path, mode: str, shared_dependency: str = "same") -> Path:
        package = repo / "build" / f"qemu-runtime-{mode}"
        framework = "QEMU.framework" if mode == "jit" else "QEMU-TCI.framework"
        library = f"Frameworks/{framework}/QEMU"
        self.write(package / library, f"{mode}-runtime")
        self.write(package / "Frameworks/Shared.framework/Shared", shared_dependency)
        self.write(package / "UTM-SOURCE-REVISION.txt", "fixture-revision\n")
        self.write(package / "UTM-archive-Info.plist", f"<plist>{mode}</plist>\n")
        self.write(package / "runtime-file-inventory.txt", f"{library}\n")

        base_exports = (
            " T _qemu_init\n"
            " T _qemu_main_loop\n"
            " T _qemu_cleanup\n"
            " T _qemu_system_shutdown_request\n"
        )
        if mode == "jit":
            exports = base_exports + " T _isteam_qemu_set_jit_callbacks\n"
            mode_directory = package / "QEMU/JIT"
            self.write(mode_directory / "runtime-library-path.txt", library + "\n")
            self.write(mode_directory / "exports.txt", exports)
            self.write(package / "BUILD-INFO-jit.txt", "JIT build information\n")
            self.write(package / "dependency-report-jit.txt", "JIT dependencies\n")
        else:
            exports = base_exports
            self.write(package / "QEMU/firmware/OVMF_CODE.fd", "firmware\n")
            self.write(package / "BUILD-INFO.txt", "TCI build information\n")
            self.write(package / "dependency-report.txt", "TCI dependencies\n")

        self.write(package / "QEMU/runtime-library-path.txt", library + "\n")
        self.write(package / "exports.txt", exports)
        return package

    def run_merge(self, repo: Path, jit: Path, tci: Path, output: str):
        script = repo / "scripts/merge-qemu-runtime-variants.sh"
        return subprocess.run(
            ["bash", str(script), str(jit), str(tci), output],
            cwd=repo,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_output_path_traversal_is_rejected_without_deleting_sentinel(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.make_repository(Path(temporary))
            jit = self.make_package(repo, "jit")
            tci = self.make_package(repo, "tci")
            outside = repo / "outside"
            outside.mkdir()
            sentinel = outside / "keep.txt"
            sentinel.write_text("must survive\n")

            result = self.run_merge(repo, jit, tci, "build/../outside")

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_text(), "must survive\n")

    def test_merge_preserves_separate_jit_and_tci_layout_and_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.make_repository(Path(temporary))
            jit = self.make_package(repo, "jit")
            tci = self.make_package(repo, "tci")

            result = self.run_merge(repo, jit, tci, "build/merged")

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = repo / "build/merged"
            self.assertTrue((output / "QEMU/JIT/runtime-library-path.txt").is_file())
            self.assertTrue((output / "QEMU/TCI/runtime-library-path.txt").is_file())
            self.assertFalse((output / "QEMU/JIT/JIT").exists())
            self.assertTrue((output / "Frameworks/QEMU.framework/QEMU").is_file())
            self.assertTrue((output / "Frameworks/TCI/QEMU-TCI.framework/QEMU").is_file())
            build_info = (output / "BUILD-INFO.txt").read_text()
            dependency_report = (output / "dependency-report.txt").read_text()
            self.assertIn("JIT build information", build_info)
            self.assertIn("TCI build information", build_info)
            self.assertIn("JIT dependencies", dependency_report)
            self.assertIn("TCI dependencies", dependency_report)

    def test_different_shared_framework_bytes_are_rejected_without_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.make_repository(Path(temporary))
            jit = self.make_package(repo, "jit", shared_dependency="jit-version")
            tci = self.make_package(repo, "tci", shared_dependency="tci-version")

            result = self.run_merge(repo, jit, tci, "build/merged")

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((repo / "build/merged").exists())

    def test_symlinked_framework_directory_cannot_redirect_merge_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.make_repository(Path(temporary))
            jit = self.make_package(repo, "jit")
            tci = self.make_package(repo, "tci")
            self.write(jit / "Frameworks/Shared.framework/Elsewhere/marker.txt", "safe\n")
            (jit / "Frameworks/Shared.framework/Redirect").symlink_to(
                "Elsewhere", target_is_directory=True
            )
            self.write(tci / "Frameworks/Shared.framework/Redirect/Injected.txt", "must not be copied\n")

            result = self.run_merge(repo, jit, tci, "build/merged")

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((repo / "build/merged").exists())


if __name__ == "__main__":
    unittest.main()
