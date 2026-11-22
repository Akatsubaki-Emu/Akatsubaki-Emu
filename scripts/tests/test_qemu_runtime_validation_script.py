import subprocess
import unittest
from pathlib import Path


class QEMURuntimeValidationScriptTests(unittest.TestCase):
    def test_validator_is_valid_bash(self):
        root = Path(__file__).resolve().parents[1]
        script = root / "validate-qemu-runtime.sh"
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_requires_all_five_defined_runtime_exports(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        required = (
            "qemu_init",
            "qemu_main_loop",
            "qemu_cleanup",
            "qemu_system_shutdown_request",
            "isteam_qemu_set_jit_callbacks",
        )
        loop = next(line for line in source.splitlines() if line.startswith("for symbol in "))
        for symbol in required:
            with self.subTest(symbol=symbol):
                self.assertIn(symbol, loop)
        self.assertEqual(source.count("for symbol in "), 1)
        self.assertEqual(source.count("codesign --verify --strict"), 1)
        self.assertNotIn("Optional export absent", source)
        self.assertNotIn("Found optional graceful-shutdown export", source)


if __name__ == "__main__":
    unittest.main()
