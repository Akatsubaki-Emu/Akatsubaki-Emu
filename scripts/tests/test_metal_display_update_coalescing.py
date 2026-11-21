import unittest
from pathlib import Path


class MetalDisplayUpdateCoalescingTests(unittest.TestCase):
    def test_frame_submissions_share_one_pending_main_queue_update(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")

        self.assertIn("private var displayUpdateScheduled = false", source)
        start = source.split("func start()", 1)[1].split("func stop()", 1)[0]
        stop = source.split("func stop()", 1)[1].split("private func scheduleDisplayUpdate()", 1)[0]
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        scheduler = source.split("private func scheduleDisplayUpdate()", 1)[1].split("func submit(frame:", 1)[0]

        self.assertIn("scheduleDisplayUpdate()", start)
        self.assertIn("scheduleDisplayUpdate()", stop)
        self.assertIn("scheduleDisplayUpdate()", submit)
        self.assertNotIn("DispatchQueue.main.async", submit)
        self.assertIn("let shouldSchedule = !displayUpdateScheduled", scheduler)
        self.assertIn("if shouldSchedule { displayUpdateScheduled = true }", scheduler)
        self.assertIn("guard shouldSchedule else { return }", scheduler)
        self.assertIn("self.displayUpdateScheduled = false", scheduler)
        self.assertIn("let width = self.drawableWidth", scheduler)
        self.assertIn("let height = self.drawableHeight", scheduler)
        self.assertIn("self.view.setNeedsDisplay()", scheduler)


if __name__ == "__main__":
    unittest.main()
