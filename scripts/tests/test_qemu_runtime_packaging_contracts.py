import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class QEMURuntimePackagingContractTests(unittest.TestCase):
    def test_runtime_shell_scripts_parse(self):
        for relative in (
            "scripts/validate-qemu-runtime.sh",
            "scripts/package-utm-qemu-runtime.sh",
            "scripts/package-utm-qemu-tci-runtime.sh",
            "scripts/merge-qemu-runtime-variants.sh",
        ):
            result = subprocess.run(["bash", "-n", str(ROOT / relative)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{relative}: {result.stderr}")

    def test_unsigned_is_allowed_only_for_intermediate_packages(self):
        validator = (ROOT / "scripts/validate-qemu-runtime.sh").read_text()
        jit = (ROOT / "scripts/package-utm-qemu-runtime.sh").read_text()
        tci = (ROOT / "scripts/package-utm-qemu-tci-runtime.sh").read_text()
        self.assertIn('signature_policy="${3:-required}"', validator)
        self.assertIn('codesign --verify --strict "$library"', validator)
        self.assertIn('[[ "$signature_policy" == "allow-unsigned" ]]', validator)
        self.assertIn('"$MODE" allow-unsigned', jit)
        self.assertIn('"$OUT/$runtime_relative" tci allow-unsigned', tci)

    def test_release_requires_and_embeds_both_runtime_modes(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        for token in (
            'TCI_RUNTIME_DIR="$RUNTIME_DIR/QEMU/TCI"',
            'TCI_RUNTIME_REL="$(head -n 1 "$TCI_RUNTIME_DIR/runtime-library-path.txt")"',
            'test -s "$RUNTIME_DIR/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/TCI/runtime-library-path.txt"',
            'test -s "$APP/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/TCI/exports.txt"',
        ):
            self.assertIn(token, workflow)

    def test_build_is_pinned_and_keeps_legacy_jit_manifest(self):
        workflow = (ROOT / ".github/workflows/build-qemu-runtime.yml").read_text()
        self.assertIn("ref: 3d4b8d8cb1ce93a8b1a9610695c12487685f0c15", workflow)
        self.assertIn("test -s build/qemu-runtime/QEMU/runtime-library-path.txt", workflow)
        self.assertIn("test -s build/qemu-runtime/exports.txt", workflow)


if __name__ == "__main__":
    unittest.main()
