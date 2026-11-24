from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-validation-freshness.sh"
WORKFLOW = ROOT / ".github/workflows/validate-ios-build.yml"


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=repo, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


class ValidationFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / "repo"
        self.remote = Path(self.temp.name) / "origin.git"
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "init", "--initial-branch=main", str(self.repo)], check=True, capture_output=True)
        git(self.repo, "config", "user.name", "Akatsubaki CI Test")
        git(self.repo, "config", "user.email", "ci-test@example.invalid")
        git(self.repo, "remote", "add", "origin", str(self.remote))
        (self.repo / "README.md").write_text("base\n")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-m", "base")
        git(self.repo, "push", "-u", "origin", "main")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def run_guard(self, sha: str, ref: str = "refs/heads/main"):
        env = os.environ.copy()
        env.update({"GITHUB_SHA": sha, "GITHUB_REF": ref})
        return subprocess.run(
            ["bash", str(SCRIPT), sha], cwd=self.repo, env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_current_main_revision_is_current(self):
        result = self.run_guard(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")

    def test_any_newer_main_commit_makes_old_run_stale(self):
        (self.repo / "docs.txt").write_text("documentation-only change\n")
        git(self.repo, "add", "docs.txt")
        git(self.repo, "commit", "-m", "newer docs commit")
        git(self.repo, "push", "origin", "main")
        result = self.run_guard(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "false")
        self.assertIn("newer main commit", result.stderr)

    def test_pull_request_checkout_is_not_skipped(self):
        (self.repo / "docs.txt").write_text("newer main change\n")
        git(self.repo, "add", "docs.txt")
        git(self.repo, "commit", "-m", "newer main")
        git(self.repo, "push", "origin", "main")
        result = self.run_guard(self.base, "refs/pull/42/merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")

    def test_platform_workflow_checks_freshness_before_apple_runners(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("check-validation-freshness:", workflow)
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertIn("scripts/check-validation-freshness.sh", workflow)
        self.assertIn("needs: check-validation-freshness", workflow)
        self.assertIn("if: needs.check-validation-freshness.outputs.current == 'true'", workflow)
        self.assertIn("group: platform-compile-${{ github.event.pull_request.number || github.ref }}", workflow)
        self.assertIn("cancel-in-progress: false", workflow)


if __name__ == "__main__":
    unittest.main()
