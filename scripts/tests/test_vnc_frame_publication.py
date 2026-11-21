import unittest
from pathlib import Path


class VNCFramebufferPublicationTests(unittest.TestCase):
    def test_empty_updates_do_not_snapshot_or_submit_unchanged_framebuffer(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        update = source.split("case 0: // FramebufferUpdate", 1)[1].split("case 1: // SetColourMapEntries", 1)[0]
        self.assertIn("var framebufferChanged = false", update)
        self.assertIn("framebufferChanged = true", update)
        self.assertIn("if framebufferChanged {", update)
        self.assertLess(update.index("if framebufferChanged {"), update.index("let frame = withStateLock"))
        self.assertIn("try await requestFramebufferUpdate(incremental: true, connection: connection)", update)


if __name__ == "__main__":
    unittest.main()
