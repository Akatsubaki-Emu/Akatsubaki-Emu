from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOADER = ROOT / "src/Runtime/ELF64Loader.swift"
STATIC_ELF_TEST = ROOT / "scripts/tests/test_static_elf_execution.swift"


class ELFSnapshotContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = LOADER.read_text(encoding="utf-8")
        cls.snapshot = source.split("final class OpenedFileSnapshot", 1)[1].split("\\n    func load(", 1)[0]
        cls.test_source = STATIC_ELF_TEST.read_text(encoding="utf-8")

    def test_snapshot_is_bound_to_a_regular_open_descriptor(self):
        self.assertIn("fstat(openedHandle.fileDescriptor, &fileStatus)", self.snapshot)
        self.assertIn("mode_t(S_IFMT)", self.snapshot)
        self.assertIn("mode_t(S_IFREG)", self.snapshot)
        self.assertIn("fileStatus.st_size >= 0", self.snapshot)
        self.assertIn("guard end == length", self.snapshot)

    def test_chunked_reads_reject_short_reads_and_growth(self):
        self.assertIn("while snapshot.count < byteCount", self.snapshot)
        self.assertIn("handle.read(upToCount: requested)", self.snapshot)
        self.assertIn("guard !chunk.isEmpty, chunk.count <= requested", self.snapshot)
        self.assertIn("handle.read(upToCount: 1)", self.snapshot)
        self.assertIn("guard trailing.isEmpty", self.snapshot)

    def test_runtime_snapshot_regressions_remain(self):
        self.assertIn("testDescriptorBoundELFSnapshot()", self.test_source)
        self.assertIn("growthSnapshot.read()", self.test_source)
        self.assertIn("truncationSnapshot.read()", self.test_source)
        self.assertIn("OpenedFileSnapshot(url: directory)", self.test_source)


if __name__ == "__main__":
    unittest.main()
