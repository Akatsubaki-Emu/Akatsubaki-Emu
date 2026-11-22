import unittest
from pathlib import Path


class DisplayFrameStatusThrottleTests(unittest.TestCase):
    def test_guest_resolution_status_is_not_dispatched_for_every_frame(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        callback = source.split("vncClient.onFrame = {", 1)[1].split("vncClient.onStatus =", 1)[0]

        self.assertIn("lastReportedGuestFrameWidth != width", callback)
        self.assertIn("lastReportedGuestFrameHeight != height", callback)
        self.assertIn("lastReportedGuestFrameWidth = width", callback)
        self.assertIn("lastReportedGuestFrameHeight = height", callback)
        self.assertIn("DispatchQueue.main.async { [weak self] in", callback)
        self.assertIn("self.virtioGPU.submit(.updateFramebuffer(data, width: width, height: height))", callback)


if __name__ == "__main__":
    unittest.main()
