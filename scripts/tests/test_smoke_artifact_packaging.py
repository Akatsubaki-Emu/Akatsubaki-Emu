from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/build-core-only-ios.yml"
DOCS = ROOT / "docs/CORE_ONLY_IOS_TEST_BUILD.md"


class SmokeArtifactPackagingTests(unittest.TestCase):
    def test_core_only_artifact_contains_guest_builder_test_and_checksum(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('cp scripts/build_hybrid_xchg_smoke_elf.py "$DIST/build_hybrid_xchg_smoke_elf.py"', workflow)
        self.assertIn('cp scripts/tests/test_hybrid_xchg_smoke_elf.py "$DIST/test_hybrid_xchg_smoke_elf.py"', workflow)
        self.assertIn('shasum -a 256 "$DIST/hybrid_xchg_smoke.elf"', workflow)
        self.assertIn("Smoke guest expected output: KENRAN_BUTO_XCHG_OK", workflow)

    def test_core_only_documentation_matches_guest_artifact(self):
        docs = DOCS.read_text(encoding="utf-8")
        self.assertIn("KENRAN_BUTO_XCHG_OK", docs)
        self.assertIn("XCHG R8D,R9D", docs)
        self.assertIn("XCHG R10,R11", docs)


if __name__ == "__main__":
    unittest.main()
