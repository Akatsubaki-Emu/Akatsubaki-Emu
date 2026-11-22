import unittest
from pathlib import Path


class QEMUJITPolicyTests(unittest.TestCase):
    def test_physical_ios_runtime_requires_confirmed_jit_and_fails_closed(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        gate = runtime.split(
            "#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)",
            1,
        )[1].split("#endif", 1)[0]
        self.assertIn("if #available(iOS 17.4, *)", gate)
        self.assertIn("guard JITCoordinator.shared.isJITReady else", gate)
        self.assertIn("QEMU TCG requires iOS 17.4 or later", gate)
        self.assertNotIn("isStikDebugAvailable", gate)
        self.assertLess(runtime.index("if #available(iOS 17.4, *)"), runtime.index("switch QEMURuntimeStatus.inspect()"))


if __name__ == "__main__":
    unittest.main()
