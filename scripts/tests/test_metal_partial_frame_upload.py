import unittest
from pathlib import Path


class MetalPartialFramebufferUploadTests(unittest.TestCase):
    def test_only_current_unread_texture_receives_partial_updates(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        draw = source.split("func draw(in view:", 1)[1]

        self.assertIn("current.readers == 0, !current.isUploading", submit)
        self.assertIn("let updatesPublishedSlot: Bool", submit)
        self.assertIn("let requestedRegions: [GPUFrameRegion]", submit)
        self.assertIn("let uploadRegions = updatesPublishedSlot ? requestedRegions : [fullRegion]", submit)
        self.assertIn("for region in uploadRegions", submit)
        self.assertIn("base.advanced(by: byteOffset)", submit)
        self.assertIn("bytesPerRow: frameWidth * 4", submit)
        self.assertIn("let isUploading = framebuffer?.isUploading ?? false", draw)
        self.assertIn("if isUploading { return }", draw)

    def test_uploading_frame_skips_drawable_and_command_buffer_acquisition(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        draw = source.split("func draw(in view:", 1)[1].split("extension MetalGPUBackend", 1)[0]
        self.assertLess(draw.index("if isUploading { return }"), draw.index("queue.makeCommandBuffer()"))
        self.assertLess(draw.index("if isUploading { return }"), draw.index("view.currentDrawable"))
        self.assertIn("if let source { release(source) }", draw)

    def test_spare_texture_receives_a_full_frame_to_avoid_stale_pixels(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        self.assertIn("Spare slots can contain older frames", submit)
        self.assertIn("updatesPublishedSlot = false", submit)
        self.assertIn("let fullRegion = GPUFrameRegion(x: 0, y: 0, width: frameWidth, height: frameHeight)", submit)

    def test_invalid_or_empty_dirty_region_sets_fall_back_to_full_upload(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        self.assertIn("dirtyRegions.allSatisfy", submit)
        self.assertIn("requestedRegions = [fullRegion]", submit)


if __name__ == "__main__":
    unittest.main()
