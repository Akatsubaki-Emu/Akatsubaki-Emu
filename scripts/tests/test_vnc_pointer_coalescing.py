import unittest
from pathlib import Path


class VNCPointerCoalescingTests(unittest.TestCase):
    def test_pointer_updates_coalesce_per_connection_on_ordered_send_queue(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        self.assertIn("private final class VNCPointerSendBatch", source)
        self.assertIn("private var pointerSendBatch: VNCPointerSendBatch?", source)
        self.assertIn("self.pointerSendBatch = VNCPointerSendBatch()", source)
        stop = source.split("func stop()", 1)[1].split("private func waitUntilReady", 1)[0]
        self.assertIn("pointerSendBatch = nil", stop)
        movement = source.split("func movePointer", 1)[1].split("func sendButton", 1)[0]
        self.assertIn("batch.latestMessage = message", movement)
        self.assertIn("guard !batch.scheduled else { return }", movement)
        self.assertIn("sendQueue.async", movement)
        self.assertIn("let latestMessage = withStateLock", movement)
        self.assertIn("group.enter()", movement)
        self.assertIn("group.leave()", movement)
        self.assertNotIn("enqueueSend(message", movement)
        enqueue = source.split("private func enqueueSend", 1)[1].split("private func send(", 1)[0]
        self.assertIn("pointerSendBatch = VNCPointerSendBatch()", enqueue)
        self.assertLess(enqueue.index("pointerSendBatch = VNCPointerSendBatch()"), enqueue.index("sendQueue.async"))
        self.assertIn("@unchecked Sendable", source)
        self.assertIn("pointer send failed: \\(error.localizedDescription)", source)


if __name__ == "__main__":
    unittest.main()
