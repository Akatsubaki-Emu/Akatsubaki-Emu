import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "merge-qemu-runtime-variants.sh"
LIFECYCLE = ["qemu_init", "qemu_main_loop", "qemu_cleanup", "qemu_system_shutdown_request"]


def make_package(root: Path, mode: str, *, revision: str = "utm-revision-1", callback: bool | None = None,
                 missing_symbol: str | None = None, qemu_bytes: str | None = None,
                 shared_bytes: str = "shared dependency", extra_symbols: list[str] | None = None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "Frameworks" / "QEMU.framework").mkdir(parents=True)
    (root / "Frameworks" / "Shared.framework").mkdir(parents=True)
    qemu_root = root / "QEMU"
    qemu_root.mkdir()
    mode_qemu = qemu_root / "JIT" if mode == "jit" else qemu_root
    mode_qemu.mkdir(parents=True, exist_ok=True)
    (root / "UTM-SOURCE-REVISION.txt").write_text(revision + "\n", encoding="utf-8")
    (root / "QEMU-SOURCE-URL.txt").write_text("https://github.com/utmapp/qemu.git\n", encoding="utf-8")
    (root / "Frameworks" / "QEMU.framework" / "QEMU").write_text(
        qemu_bytes if qemu_bytes is not None else mode + " qemu binary", encoding="utf-8"
    )
    (root / "Frameworks" / "Shared.framework" / "Shared").write_text(shared_bytes, encoding="utf-8")
    (qemu_root / "runtime-library-path.txt").write_text(
        "Frameworks/QEMU.framework/QEMU\n", encoding="utf-8"
    )
    symbols = [f"00000000 T _{symbol}" for symbol in LIFECYCLE if symbol != missing_symbol]
    include_callback = mode == "jit" if callback is None else callback
    if include_callback:
        symbols.append("00000000 T _isteam_qemu_set_jit_callbacks")
    symbols.extend(extra_symbols or [])
    (root / "exports.txt").write_text("\n".join(symbols) + "\n", encoding="utf-8")
    if mode == "jit":
        (mode_qemu / "runtime-library-path.txt").write_text(
            "Frameworks/QEMU.framework/QEMU\n", encoding="utf-8"
        )
        (mode_qemu / "exports.txt").write_text("\n".join(symbols) + "\n", encoding="utf-8")
    (root / "BUILD-INFO.txt").write_text(mode + " build\n", encoding="utf-8")
    (mode_qemu / "bios.bin").write_text(mode + " bios\n", encoding="utf-8")
    firmware = mode_qemu / "firmware" / "uefi"
    firmware.mkdir(parents=True)
    (firmware / "OVMF_CODE.fd").write_text(mode + " firmware\n", encoding="utf-8")
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

    def run_merge(self, output="build/merged", jit=None, tci=None, env=None):
        return subprocess.run(
            ["bash", str(SCRIPT), str(jit or self.jit), str(tci or self.tci), output],
            cwd=self.root, capture_output=True, text=True, check=False, env=env,
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
        self.assertFalse((output / "QEMU/JIT/JIT").exists())
        self.assertEqual((output / "QEMU/JIT/firmware/uefi/OVMF_CODE.fd").read_text(), "jit firmware\n")
        self.assertEqual((output / "QEMU/TCI/firmware/uefi/OVMF_CODE.fd").read_text(), "tci firmware\n")

    def test_rejects_missing_jit_mode_data_directory(self):
        import shutil
        shutil.rmtree(self.jit / "QEMU" / "JIT")
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing JIT runtime data directory", result.stderr)

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
        self.assertTrue((jit / "QEMU/JIT/bios.bin").is_file())
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

    def test_rejects_substring_only_lifecycle_exports(self):
        for mode in ("jit", "tci"):
            with self.subTest(mode=mode):
                package = make_package(
                    self.build / f"bad-{mode}",
                    mode,
                    missing_symbol="qemu_init",
                    extra_symbols=["00000000 T _qemu_init_extra"],
                )
                result = self.run_merge(jit=package) if mode == "jit" else self.run_merge(tci=package)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("qemu_init", result.stderr)

    def test_rejects_substring_only_jit_callback_export(self):
        jit = make_package(
            self.build / "bad-jit-callback",
            "jit",
            callback=False,
            extra_symbols=["00000000 T _isteam_qemu_set_jit_callbacks_extra"],
        )
        result = self.run_merge(jit=jit)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the StikJIT callback", result.stderr)

    def test_allows_unrelated_tci_symbol_with_jit_callback_prefix(self):
        tci = make_package(
            self.build / "tci-callback-prefix",
            "tci",
            callback=False,
            extra_symbols=["00000000 T _isteam_qemu_set_jit_callbacks_extra"],
        )
        result = self.run_merge(tci=tci)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_multiline_runtime_manifest(self):
        (self.tci / "QEMU" / "runtime-library-path.txt").write_text(
            "Frameworks/QEMU.framework/QEMU\nFrameworks/Other.framework/Other\n",
            encoding="utf-8",
        )
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one line", result.stderr)

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

    def test_preserves_different_jit_and_tci_dependency_trees(self):
        tci = make_package(self.build / "different-tci", "tci", shared_bytes="different TCI dependency")
        result = self.run_merge(tci=tci)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.build / "merged"
        self.assertEqual((output / "Frameworks/Shared.framework/Shared").read_text(), "shared dependency")
        self.assertEqual((output / "Frameworks/TCI/Shared.framework/Shared").read_text(),
                         "different TCI dependency")


    def test_isolates_versioned_tci_frameworks_and_resigns_runpath_changes(self):
        framework = self.tci / "Frameworks" / "Versioned.framework"
        versioned_binary = framework / "Versions" / "A" / "Versioned"
        versioned_binary.parent.mkdir(parents=True)
        versioned_binary.write_text("versioned TCI framework binary", encoding="utf-8")
        (framework / "Versions" / "Current").symlink_to("A")
        (framework / "Versioned").symlink_to("Versions/Current/Versioned")
        (framework / "Resources").mkdir()
        (framework / "Resources" / "Info.plist").write_text("versioned resources", encoding="utf-8")
        (framework / "Versions" / "A" / "Resources").symlink_to("../../Resources")

        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        tools = {
            "file": (
                "#!/bin/sh\n"
                "if [ \"${1:-}\" = \"-b\" ]; then shift; fi\n"
                "case \"${1:-}\" in\n"
                "  *.plist) echo 'XML 1.0 document, ASCII text' ;;\n"
                "  *) echo 'Mach-O 64-bit dynamically linked shared library arm64' ;;\n"
                "esac\n"
            ),
            "otool": (
                "#!/bin/sh\n"
                "cat <<'EOF'\n"
                "Load command 1\n"
                "          cmd LC_RPATH\n"
                "      cmdsize 40\n"
                "         path @executable_path/Frameworks (offset 12)\n"
                "EOF\n"
            ),
            "install_name_tool": (
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  -add_rpath) printf '\\nMOCK_RPATH=%s' \"$2\" >> \"$3\" ;;\n"
                "  -delete_rpath) printf '\\nMOCK_DELETED_RPATH=%s' \"$2\" >> \"$3\" ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n"
            ),
            "codesign": "#!/bin/bash\ntarget=\"$5\"\nprintf '\\nMOCK_SIGNED' >> \"$target\"\n",
        }
        for name, source in tools.items():
            tool = mock_bin / name
            tool.write_text(source, encoding="utf-8")
            tool.chmod(0o755)

        env = {**os.environ, "PATH": f"{mock_bin}:{os.environ['PATH']}"}
        result = self.run_merge(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

        output = self.build / "merged"
        flat_tci = output / "Frameworks/TCI/QEMU.framework/QEMU"
        self.assertIn("MOCK_DELETED_RPATH=@executable_path/Frameworks", flat_tci.read_text(encoding="utf-8"))
        self.assertIn("MOCK_RPATH=@loader_path/..", flat_tci.read_text(encoding="utf-8"))
        self.assertIn("MOCK_SIGNED", flat_tci.read_text(encoding="utf-8"))

        nested_tci = output / "Frameworks/TCI/Versioned.framework/Versions/A/Versioned"
        self.assertIn("MOCK_DELETED_RPATH=@executable_path/Frameworks", nested_tci.read_text(encoding="utf-8"))
        self.assertIn("MOCK_RPATH=@loader_path/../../..", nested_tci.read_text(encoding="utf-8"))
        self.assertIn("MOCK_SIGNED", nested_tci.read_text(encoding="utf-8"))
        self.assertTrue((output / "Frameworks/TCI/Versioned.framework/Versioned").is_symlink())
        self.assertTrue((output / "Frameworks/TCI/Versioned.framework/Versions/Current").is_symlink())
        self.assertTrue((output / "Frameworks/TCI/Versioned.framework/Versions/A/Resources").is_symlink())
        self.assertEqual((output / "Frameworks/TCI/Versioned.framework/Resources/Info.plist").read_text(),
                         "versioned resources")

        jit_binary = output / "Frameworks/QEMU.framework/QEMU"
        self.assertNotIn("MOCK_RPATH", jit_binary.read_text(encoding="utf-8"))
        self.assertNotIn("MOCK_SIGNED", jit_binary.read_text(encoding="utf-8"))

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
