import subprocess
import unittest
from pathlib import Path

class QEMURuntimeValidationScriptTests(unittest.TestCase):
    def test_validator_is_valid_bash(self):
        script = Path(__file__).resolve().parents[1] / "validate-qemu-runtime.sh"
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_requires_ios_arm64_and_all_runtime_exports(self):
        source = (Path(__file__).resolve().parents[1] / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        for token in ("dynamically linked shared library", "lipo -archs", "vtool -show-build",
                      "platform[[:space:]]+IOS", "nm -gU", "qemu_init", "qemu_main_loop",
                      "qemu_cleanup", "qemu_system_shutdown_request",
                      "isteam_qemu_set_jit_callbacks", "codesign --verify --strict"):
            with self.subTest(token=token):
                self.assertIn(token, source)
        self.assertEqual(source.count("for tool in "), 1)
        self.assertEqual(source.count("for symbol in "), 1)

if __name__ == "__main__":
    unittest.main()
