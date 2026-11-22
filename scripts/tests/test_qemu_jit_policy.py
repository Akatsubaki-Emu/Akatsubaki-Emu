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
        self.assertIn("guard JITCoordinator.shared.isQEMUJITReady else", gate)
        self.assertIn("QEMU TCG requires a physical iOS 26+ device", gate)
        self.assertIn("get-task-allow entitlement", gate)
        self.assertIn("recognised StikDebug JIT protocol (standard split-WX or TXM)", gate)
        self.assertLess(runtime.index("isQEMUJITReady"), runtime.index("switch QEMURuntimeStatus.inspect()"))
        coordinator = (root / "iSteam" / "JITCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("return isStikDebugAvailable && hasGetTaskAllow && isQEMUProtocolAvailable && isJITReady", coordinator)


if __name__ == "__main__":
    unittest.main()
