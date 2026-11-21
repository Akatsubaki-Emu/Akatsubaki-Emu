import unittest
from pathlib import Path


class VNCPointerAllocationTests(unittest.TestCase):
    def test_coalesced_pointer_packets_are_encoded_only_when_drained(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        self.assertIn("private struct VNCPointerPosition: Sendable", source)
        self.assertIn("var latestPosition: VNCPointerPosition?", source)
        movement = source.split("func movePointer", 1)[1].split("func sendButton", 1)[0]
        self.assertIn("batch.latestPosition = VNCPointerPosition", movement)
        self.assertNotIn("Data([", movement)
        drain = movement.split("sendQueue.async", 1)[1]
        self.assertIn("let latestPosition = withStateLock", drain)
        self.assertIn("let message = Data([", drain)
        self.assertIn("connection.send(content: message", drain)


if __name__ == "__main__":
    unittest.main()
