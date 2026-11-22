import unittest
from pathlib import Path


class VirtIOGPUFramebufferRegionTests(unittest.TestCase):
    def test_disjoint_dirty_regions_are_forwarded_to_the_backend(self):
        root = Path(__file__).resolve().parents[2]
        backend = (root / "src" / "GPU" / "GPUBackend.swift").read_text(encoding="utf-8")
        metal = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        virtio = (root / "src" / "GPU" / "VirtIOGPU.swift").read_text(encoding="utf-8")
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        vnc = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")

        self.assertIn("struct GPUFrameRegion: Equatable", backend)
        self.assertIn("struct GPUFrameRegionAccumulator", backend)
        self.assertIn("dirtyRegions: [GPUFrameRegion]?", backend)
        self.assertIn("case updateFramebuffer(Data, width: Int, height: Int, dirtyRegions: [GPUFrameRegion]?)", virtio)
        self.assertIn("backend.submit(frame: data, width: width, height: height, dirtyRegions: dirtyRegions)", virtio)
        self.assertIn("dirtyRegions: [GPUFrameRegion]?", metal)
        self.assertIn("let uploadRegions = updatesPublishedSlot ? requestedRegions : [fullRegion]", metal)
        self.assertIn("for region in uploadRegions", metal)
        self.assertIn("width, height, dirtyRegions in", display)
        self.assertIn("dirtyRegions: dirtyRegions", display)
        self.assertIn("var dirtyRegions = GPUFrameRegionAccumulator()", vnc)
        self.assertIn("dirtyRegions.add(GPUFrameRegion(x: 0, y: 0, width: width, height: height))", vnc)
        self.assertIn("dirtyRegions.add(region)", vnc)
        self.assertIn("onFrame?(frame.0, frame.1, frame.2, dirtyRegions.regions.isEmpty ? nil : dirtyRegions.regions)", vnc)


if __name__ == "__main__":
    unittest.main()
