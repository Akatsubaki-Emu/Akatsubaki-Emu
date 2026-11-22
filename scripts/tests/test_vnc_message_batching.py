import unittest
from pathlib import Path


class VNCMessageBatchingTests(unittest.TestCase):
    def test_framebuffer_update_header_uses_one_receive(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        update = source.split("case 0: // FramebufferUpdate", 1)[1].split("case 1: // SetColourMapEntries", 1)[0]
        self.assertIn("receiveExactly(3, from: connection)", update)
        self.assertIn("Self.u16(updateHeader, 1)", update)
        self.assertNotIn("receiveExactly(1, from: connection)", update)
        self.assertNotIn("receiveExactly(2, from: connection)", update)

    def test_related_key_transitions_share_one_ordered_send(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        encoder = source.split("private static func keyEvents", 1)[1].split("private func performHandshake", 1)[0]
        self.assertIn("data.reserveCapacity(events.count * 8)", encoder)
        self.assertIn("data.append(event.isDown ? 1 : 0)", encoder)
        stop = source.split("func stop()", 1)[1].split("private func waitUntilReady", 1)[0]
        tap = source.split("func tapKey", 1)[1].split("func setMovement", 1)[0]
        movement = source.split("func setMovement", 1)[1].split("func movePointer", 1)[0]
        self.assertIn("Self.keyEvents(releaseEvents)", stop)
        self.assertIn("Self.keyTapEvents(keysym)", tap)
        self.assertIn("Self.keyEvents(events)", movement)
        self.assertNotIn("for event in keyState.setMovement", movement)


if __name__ == "__main__":
    unittest.main()
