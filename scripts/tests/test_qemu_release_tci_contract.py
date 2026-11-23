import unittest
from pathlib import Path


class QEMUTCIRuntimePackagingTests(unittest.TestCase):
    def test_release_validates_and_embeds_both_runtime_modes(self):
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        merge = (root / "scripts" / "merge-qemu-runtime-variants.sh").read_text(encoding="utf-8")

        required_release_contract = (
            'test -s "$RUNTIME_DIR/QEMU/runtime-library-path.txt"',
            'TCI_RUNTIME_DIR="$RUNTIME_DIR/QEMU/TCI"',
            'test -s "$TCI_RUNTIME_DIR/runtime-library-path.txt"',
            'test -s "$TCI_RUNTIME_DIR/exports.txt"',
            'TCI_RUNTIME_REL="$(head -n 1 "$TCI_RUNTIME_DIR/runtime-library-path.txt")"',
            'test -s "$RUNTIME_DIR/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/JIT/runtime-library-path.txt"',
            'test -s "$APP/QEMU/TCI/runtime-library-path.txt"',
            'test -s "$APP/$TCI_RUNTIME_REL"',
            'test -s "$APP/QEMU/TCI/exports.txt"',
            'test -s "$APP/QEMU/runtime-mode-manifest.txt"',
        )
        for token in required_release_contract:
            with self.subTest(token=token):
                self.assertIn(token, release)

        self.assertIn(
            'cp "$JIT_DIR/QEMU/runtime-library-path.txt" "$TEMP_OUT/QEMU/runtime-library-path.txt"',
            merge,
        )
        self.assertIn("TCI runtime must not export the StikDebug JIT callback.", release)


if __name__ == "__main__":
    unittest.main()
