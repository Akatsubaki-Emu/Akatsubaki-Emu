import unittest
from pathlib import Path


class VirtIOGPUFramebufferRegionTests(unittest.TestCase):
    def test_dirty_region_is_forwarded_to_the_backend(self):
        root = Path(__file__).resolve().parents[2]
        backend = (root / "src" / "GPU" / "GPUBackend.swift").read_text(encoding="utf-8")
        virtio = (root / "src" / "GPU" / "VirtIOGPU.swift").read_text(encoding="utf-8")
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        vnc = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")

        self.assertIn("struct GPUFrameRegion: Equatable", backend)
        self.assertIn("dirtyRegion: GPUFrameRegion?", backend)
        self.assertIn("case updateFramebuffer(Data, width: Int, height: Int, dirtyRegion: GPUFrameRegion?, sessionGeneration: UInt64)", virtio)
        self.assertIn("backend.submit(frame: data, width: width, height: height,", virtio)
        self.assertIn("dirtyRegion: dirtyRegion, sessionGeneration: generation)", virtio)
        self.assertIn("generation, data, width, height, dirtyRegion in", display)
        self.assertIn("dirtyRegion: dirtyRegion", display)
        self.assertIn("dirtyRegion = GPUFrameRegion(x: 0, y: 0, width: width, height: height)", vnc)
        self.assertIn("dirtyRegion = dirtyRegion.map { $0.union(region) } ?? region", vnc)
        self.assertIn("onFrame?(generation, frame.0, frame.1, frame.2, dirtyRegion)", vnc)
        self.assertIn("onSessionGenerationChanged: ((UInt64) -> Void)?", vnc)
        self.assertIn("sessionGeneration: UInt64", backend)
        self.assertIn("setSessionGeneration(_ generation: UInt64)", virtio)
        self.assertIn("sessionGeneration: generation", display)


if __name__ == "__main__":
    unittest.main()
