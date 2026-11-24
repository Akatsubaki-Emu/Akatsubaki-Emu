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


    def test_old_reader_cannot_clear_or_publish_into_a_new_session(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        self.assertIn("private var sessionGeneration: UInt64 = 0", source)
        start = source.split("func start(", 1)[1].split("func stop(", 1)[0]
        self.assertIn("let generation = withStateLock", start)
        self.assertIn("self.sessionGeneration == generation", start)
        self.assertIn("readServerMessages(candidate, generation: generation)", start)
        stop = source.split("func stop()", 1)[1].split("private func waitUntilReady", 1)[0]
        self.assertIn("sessionGeneration &+= 1", stop)
        reader = source.split("private func readServerMessages", 1)[1].split("private func requestFramebufferUpdate", 1)[0]
        self.assertIn("generation: UInt64", reader)
        self.assertIn("isCurrentSession(connection, generation: generation)", reader)
        self.assertIn("self.sessionGeneration == generation", reader)
        self.assertIn("guard shouldReportStatus", source)
