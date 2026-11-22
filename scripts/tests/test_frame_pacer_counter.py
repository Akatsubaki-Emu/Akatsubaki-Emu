import unittest
from pathlib import Path


class FramePacerCounterTests(unittest.TestCase):
    def test_first_display_callback_only_establishes_baseline(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Performance" / "FramePacer.swift").read_text(encoding="utf-8")
        tick = source.split("@objc private func tick(_ display: CADisplayLink) {", 1)[1]
        self.assertLess(tick.index("guard lastTimestamp != 0"), tick.index("frames += 1"))

    def test_sixty_hertz_window_does_not_count_baseline_callback(self):
        last_timestamp = 0.0
        frames = 0
        measured = 0.0
        for index in range(31):
            timestamp = 1.0 + index / 60.0
            if last_timestamp == 0:
                last_timestamp = timestamp
                continue
            frames += 1
            elapsed = timestamp - last_timestamp
            if elapsed >= 0.5:
                measured = frames / elapsed
                frames = 0
                last_timestamp = timestamp
        self.assertAlmostEqual(measured, 60.0, places=9)


if __name__ == "__main__":
    unittest.main()
