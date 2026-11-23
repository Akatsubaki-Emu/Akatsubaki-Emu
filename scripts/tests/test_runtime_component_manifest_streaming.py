import unittest
from pathlib import Path


class RuntimeComponentManifestStreamingTests(unittest.TestCase):
    def test_integrity_verifier_hashes_the_existing_read_buffer_without_data_copies(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "RuntimeComponentManifest.swift").read_text(encoding="utf-8")
        verifier = source.split("static func verify(", 1)[1].split("enum Error:", 1)[0]

        self.assertIn("while true", verifier)
        self.assertIn("stream.read(base, maxLength: bytes.count)", verifier)
        self.assertIn("hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))", verifier)
        self.assertNotIn("Data(buffer[0..<count])", verifier)
        self.assertIn("hasher.finalize()", verifier)
        self.assertIn("digest.caseInsensitiveCompare(component.sha256)", verifier)


if __name__ == "__main__":
    unittest.main()
