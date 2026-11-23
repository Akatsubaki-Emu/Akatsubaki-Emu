import unittest
from pathlib import Path


class MotionStatusRuntimeStateTests(unittest.TestCase):
    def test_motion_telemetry_does_not_overwrite_startup_or_failure_status(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        callback = source.split("motion.onOrientation =", 1)[1].split("motion.onLookDelta =", 1)[0]
        self.assertIn("DispatchQueue.main.async { [weak self] in", callback)
        self.assertIn("case .running = self.engine.state", callback)
        self.assertIn("self.vncClient.isConnected", callback)
        self.assertIn("self.status.text = summary", callback)


if __name__ == "__main__":
    unittest.main()
