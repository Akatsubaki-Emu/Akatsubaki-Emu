import unittest
from pathlib import Path


class MetalTexturePoolReleaseTests(unittest.TestCase):
    def test_stop_releases_retained_texture_pool_after_invalidating_generation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        stop = source.split("func stop()", 1)[1].split("func submit", 1)[0]
        self.assertIn("framebufferGeneration &+= 1", stop)
        self.assertIn("framebuffer = nil", stop)
        self.assertIn("framebufferSlots.removeAll(keepingCapacity: false)", stop)
        self.assertLess(stop.index("framebuffer = nil"), stop.index("framebufferSlots.removeAll"))
        self.assertLess(stop.index("framebufferSlots.removeAll"), stop.index("textureLock.unlock()"))


if __name__ == "__main__":
    unittest.main()
