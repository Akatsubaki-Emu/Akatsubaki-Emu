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
        self.assertIn("batch.latestPosition = VNCPointerPosition", movement)
        self.assertIn("guard !batch.scheduled else { return }", movement)
        self.assertIn("sendQueue.async", movement)
        self.assertIn("let latestPosition = withStateLock", movement)
        self.assertIn("group.enter()", movement)
        self.assertIn("group.leave()", movement)
        self.assertIn("connection.send(content: message, completion:", movement)
        self.assertNotIn("enqueueSend(message", movement)
        self.assertIn("@unchecked Sendable", source)
        self.assertIn("pointer send failed: \\(error.localizedDescription)", source)

    def test_cancelled_reader_cannot_install_connection_after_stop(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        start = source.split("func start(port:", 1)[1].split("func stop()", 1)[0]
        self.assertIn("let installed = self.withStateLock", start)
        self.assertIn("guard !Task.isCancelled else { return false }", start)
        self.assertIn("self.connection = candidate", start)
        self.assertIn("guard installed else {", start)
        self.assertLess(start.index("guard !Task.isCancelled"), start.index("self.connection = candidate"))
        self.assertLess(start.index("self.connection = candidate"), start.index("guard installed else"))

    def test_reconnect_does_not_publish_unhandshaken_or_stale_connection(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        start = source.split("func start(port:", 1)[1].split("func stop()", 1)[0]
        install = start.split("let installed = self.withStateLock", 1)[1].split("guard installed", 1)[0]
        self.assertIn("self.connected = false", install)
        self.assertIn("self.pointerSendBatch = nil", install)
        activation = start.split("try await self.performHandshake(candidate)", 1)[1].split("self.onStatus", 1)[0]
        self.assertIn("guard !Task.isCancelled, self.connection === candidate else { return false }", activation)
        self.assertIn("guard activated else {", activation)
        catch = start.split("} catch {", 1)[1].split("if attempt < 119", 1)[0]
        self.assertIn("let wasCurrent = self.withStateLock", catch)
        self.assertIn("guard self.connection === candidate else { return false }", catch)
        self.assertIn("self.connection = nil", catch)
        self.assertIn("self.connected = false", catch)
        self.assertIn("self.pendingSendGroup = DispatchGroup()", catch)
        self.assertIn("_ = self.keyState.releaseAll()", catch)
        self.assertIn("if wasCurrent", catch)


if __name__ == "__main__":
    unittest.main()
