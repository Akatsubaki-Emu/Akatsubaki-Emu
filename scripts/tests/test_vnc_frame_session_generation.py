import unittest
from pathlib import Path


class VNCFrameSessionGenerationTests(unittest.TestCase):
    def test_generation_is_attached_at_vnc_snapshot_and_invalidated_on_stop(self):
        root = Path(__file__).resolve().parents[2]
        vnc = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        self.assertIn("onFrame: ((UInt64, Data, Int, Int, GPUFrameRegion?) -> Void)?", vnc)
        self.assertIn("onSessionGenerationChanged: ((UInt64) -> Void)?", vnc)
        self.assertIn("onSessionGenerationChanged?(generation)", vnc)
        self.assertIn("return (previous, group, sessionGeneration)", vnc)
        self.assertIn("onFrame?(generation, frame.0, frame.1, frame.2, dirtyRegion)", vnc)

    def test_generation_is_checked_at_virtio_and_metal_consumers(self):
        root = Path(__file__).resolve().parents[2]
        contract = (root / "src" / "GPU" / "GPUBackend.swift").read_text(encoding="utf-8")
        virtio = (root / "src" / "GPU" / "VirtIOGPU.swift").read_text(encoding="utf-8")
        metal = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        self.assertIn("setSessionGeneration(_ generation: UInt64)", contract)
        self.assertIn("sessionGeneration: UInt64", contract)
        self.assertIn("let isCurrent = generation == sessionGeneration", virtio)
        self.assertIn("guard isCurrent else { return }", virtio)
        self.assertIn("guard frameSessionGeneration == sessionGeneration", metal)
        self.assertIn("pending.sessionGeneration == sessionGeneration", metal)
        self.assertIn("drawSessionGeneration == sessionGeneration", metal)
        self.assertIn("drawFramebufferGeneration == framebufferGeneration", metal)
        self.assertIn("framebuffer === source", metal)

    def test_controller_passes_the_vnc_generation_to_the_gpu(self):
        root = Path(__file__).resolve().parents[2]
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn("vncClient.onSessionGenerationChanged", display)
        self.assertIn("self.virtioGPU.setSessionGeneration(generation)", display)
        self.assertIn("vncClient.onFrame = { [weak self] generation, data, width, height, dirtyRegion in", display)
        self.assertIn("sessionGeneration: generation", display)


if __name__ == "__main__":
    unittest.main()
