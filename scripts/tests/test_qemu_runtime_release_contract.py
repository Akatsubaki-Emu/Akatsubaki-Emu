from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class QEMURuntimeReleaseContractTests(unittest.TestCase):
    def test_release_ipa_validates_both_runtime_modes(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn('JIT_RUNTIME_DIR="$RUNTIME_DIR/QEMU/JIT"', workflow)
        self.assertIn('TCI_RUNTIME_DIR="$RUNTIME_DIR/QEMU/TCI"', workflow)
        self.assertIn('test -s "$APP/QEMU/JIT/runtime-library-path.txt"', workflow)
        self.assertIn('test -s "$APP/QEMU/TCI/runtime-library-path.txt"', workflow)
        self.assertIn('test -s "$APP/$JIT_RUNTIME_REL"', workflow)
        self.assertIn('test -s "$APP/$TCI_RUNTIME_REL"', workflow)
        self.assertNotIn('test -s "$RUNTIME_DIR/QEMU/runtime-library-path.txt"', workflow)

    def test_unsigned_intermediate_policy_is_explicit(self):
        validator = (ROOT / "scripts/validate-qemu-runtime.sh").read_text(encoding="utf-8")
        jit = (ROOT / "scripts/package-utm-qemu-runtime.sh").read_text(encoding="utf-8")
        tci = (ROOT / "scripts/package-utm-qemu-tci-runtime.sh").read_text(encoding="utf-8")
        self.assertIn('signature_policy="${3:-require-signature}"', validator)
        self.assertIn('if codesign -d "$library" >/dev/null 2>&1; then', validator)
        self.assertIn('elif [[ "$signature_policy" == "allow-unsigned" ]]; then', validator)
        self.assertIn('codesign --verify --strict "$library"', validator)
        self.assertIn('bash scripts/validate-qemu-runtime.sh "$OUT/$runtime_relative" "$MODE" allow-unsigned', jit)
        self.assertIn('bash scripts/validate-qemu-runtime.sh "$OUT/$runtime_relative" tci allow-unsigned', tci)

    def test_packaging_scripts_have_valid_shell_syntax(self):
        for relative in ("scripts/package-utm-qemu-runtime.sh", "scripts/package-utm-qemu-tci-runtime.sh", "scripts/validate-qemu-runtime.sh"):
            result = subprocess.run(["bash", "-n", str(ROOT / relative)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, f"{relative}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
