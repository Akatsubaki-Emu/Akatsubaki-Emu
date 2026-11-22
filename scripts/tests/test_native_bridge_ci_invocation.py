import unittest
from pathlib import Path


class NativeBridgeCIInvocationTests(unittest.TestCase):
    def test_gitlab_native_bridge_harness_passes_the_required_runtime_mode(self):
        root = Path(__file__).resolve().parents[2]
        ci = (root / ".gitlab-ci.yml").read_text(encoding="utf-8")
        harness = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn("/tmp/test-qemu-native-bridge jit /tmp/libfake-qemu-runtime.so", ci)
        self.assertIn("assert(argc == 3)", harness)
        self.assertIn('strcmp(argv[1], "jit")', harness)


if __name__ == "__main__":
    unittest.main()
