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
        self.assertIn("let requiresFullUpload = requiresFullFrameUpload || pendingFullFrame != nil || !updatesPublishedSlot", submit)
        self.assertIn("let uploadRegion = requiresFullUpload ? fullRegion : requestedRegion", submit)
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

    def test_session_generation_is_checked_before_upload_and_final_publication(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        drain = source.split("private func drainPendingFrame()", 1)[1].split("private func makeTexture", 1)[0]
        draw = source.split("func draw(in view:", 1)[1].split("extension MetalGPUBackend", 1)[0]

        self.assertIn("let sessionGeneration: UInt64", source)
        self.assertIn("guard frameSessionGeneration == sessionGeneration", submit)
        self.assertIn("frameSessionGeneration == sessionGeneration", submit)
        self.assertIn("pending.sessionGeneration == sessionGeneration", drain)
        self.assertIn("drawSessionGeneration == sessionGeneration", draw)
        self.assertIn("drawFramebufferGeneration == framebufferGeneration", draw)
        self.assertIn("framebuffer === source", draw)
        self.assertIn("if !isCurrent", draw)

    def test_spare_texture_receives_a_full_frame_to_avoid_stale_pixels(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        self.assertIn("updatesPublishedSlot = false", submit)
        self.assertIn("let fullRegion = GPUFrameRegion(x: 0, y: 0, width: frameWidth, height: frameHeight)", submit)
        self.assertIn("let uploadRegion = requiresFullUpload ? fullRegion : requestedRegion", submit)

    def test_dropped_frame_is_retained_and_replayed_as_a_full_upload(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        submit = source.split("func submit(frame:", 1)[1].split("private func release(", 1)[0]
        release = source.split("private func release(", 1)[1].split("private func schedulePendingFrameDrain", 1)[0]
        drain = source.split("private func drainPendingFrame()", 1)[1].split("private func makeTexture", 1)[0]

        self.assertIn("private struct PendingFrame", source)
        self.assertIn("private var pendingFullFrame: PendingFrame?", source)
        self.assertIn("pendingFullFrame = PendingFrame(data: frame", submit)
        self.assertIn("requiresFullFrameUpload = true", submit)
        self.assertLess(submit.index("nextFrameSequence &+= 1"), submit.index("if let current = framebuffer"))
        self.assertIn("if shouldDrainPending { schedulePendingFrameDrain() }", release)
        self.assertIn("DispatchQueue.global(qos: .userInitiated).async", source)
        self.assertIn("pending.data.withUnsafeBytes", drain)
        self.assertIn("bytesPerRow: pending.width * 4", drain)
        self.assertIn("pending.sequence == nextFrameSequence && pendingFullFrame == nil", drain)


if __name__ == "__main__":
    unittest.main()
