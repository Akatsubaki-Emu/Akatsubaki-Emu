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
        self.assertIn('python3 scripts/build_hybrid_runtime_smoke_elf.py "$RUNNER_TEMP/hybrid_runtime_smoke.elf"', workflow)
        self.assertIn('"$RUNNER_TEMP/akatsubaki-core-tests/static-elf-tests" "$RUNNER_TEMP/hybrid_xchg_smoke.elf" "$RUNNER_TEMP/hybrid_runtime_smoke.elf"', workflow)
        self.assertIn('cp "$RUNNER_TEMP/hybrid_runtime_smoke.elf" "$DIST/hybrid_runtime_smoke.elf"', workflow)
        self.assertIn('cp scripts/build_hybrid_runtime_smoke_elf.py "$DIST/build_hybrid_runtime_smoke_elf.py"', workflow)
        self.assertIn('cp scripts/tests/test_hybrid_runtime_smoke_elf.py "$DIST/test_hybrid_runtime_smoke_elf.py"', workflow)
        self.assertIn('shasum -a 256 "$DIST/hybrid_runtime_smoke.elf"', workflow)
        self.assertIn("Runtime smoke guest expected output: Linuxx86_64KENRAN_BUTO_RUNTIME_OK", workflow)
        self.assertIn("hybrid_runtime_smoke.elf", docs)
        self.assertIn("KENRAN_BUTO_RUNTIME_OK", docs)
        self.assertIn("XCHG R8D,R9D", docs)
        self.assertIn("XCHG R10,R11", docs)


if __name__ == "__main__":
    unittest.main()
