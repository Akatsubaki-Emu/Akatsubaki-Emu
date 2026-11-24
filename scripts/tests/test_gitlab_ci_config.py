from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".gitlab-ci.yml"


class GitLabCIConfigTests(unittest.TestCase):
    def test_pipeline_is_limited_to_existing_main(self) -> None:
        config = CONFIG.read_text(encoding="utf-8")
        self.assertIn("if: '$CI_COMMIT_BRANCH == \"main\"'", config)
        self.assertIn("- when: never", config)

    def test_pipeline_runs_source_contracts_and_python_regressions(self) -> None:
        config = CONFIG.read_text(encoding="utf-8")
        self.assertIn("python3 scripts/validate-qemu-source.py", config)
        self.assertIn("python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v", config)

    def test_pipeline_publishes_executable_smoke_guest(self) -> None:
        config = CONFIG.read_text(encoding="utf-8")
        self.assertIn("scripts/build_hybrid_xchg_smoke_elf.py build/hybrid_xchg_smoke.elf", config)
        self.assertIn("./build/hybrid_xchg_smoke.elf", config)
        self.assertIn("build/hybrid_xchg_smoke.elf", config)
        self.assertIn("expire_in: 7 days", config)


if __name__ == "__main__":
    unittest.main()
