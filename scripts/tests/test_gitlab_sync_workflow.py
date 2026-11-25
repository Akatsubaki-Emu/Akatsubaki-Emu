from pathlib import Path
import re
import unittest


class GitLabSyncWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (Path(__file__).resolve().parents[2] / ".github" / "workflows" / "blank.yml").read_text(encoding="utf-8")

    def test_sync_job_waits_longer_than_gitlab_rate_limit_window(self):
        match = re.search(r"timeout-minutes:\s*(\d+)", self.workflow)
        self.assertIsNotNone(match)
        self.assertGreaterEqual(int(match.group(1)), 20)

    def test_sync_job_retries_only_rate_limit_responses(self):
        self.assertIn("for attempt in 1 2 3 4 5; do", self.workflow)
        self.assertIn("grep -Eiq '429|rate limit exceeded|too many requests'", self.workflow)
        self.assertIn('sleep "$delay"', self.workflow)
        self.assertIn('1) delay=60 ;;', self.workflow)
        self.assertIn('2) delay=120 ;;', self.workflow)
        self.assertIn('3) delay=240 ;;', self.workflow)
        self.assertIn('*) delay=300 ;;', self.workflow)

    def test_sync_job_rechecks_gitlab_ancestry_before_retry(self):
        self.assertGreaterEqual(self.workflow.count("git fetch --no-tags gitlab main"), 2)
        self.assertGreaterEqual(
            self.workflow.count('git merge-base --is-ancestor "${GITLAB_SHA}" "${GITHUB_SHA}"'),
            2,
        )
        self.assertIn("GitLab main moved or diverged during retry", self.workflow)

    def test_sync_job_never_force_pushes(self):
        self.assertIn("git push gitlab HEAD:refs/heads/main", self.workflow)
        self.assertNotRegex(self.workflow, r"git\s+push[^\n]*--force")

    def test_sync_jobs_are_serialized_without_cancellation(self):
        self.assertIn("group: github-to-gitlab-main", self.workflow)
        self.assertIn("cancel-in-progress: false", self.workflow)


class GitHubActionsOwnershipTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[2]

    def test_gitlab_ci_configuration_is_retired(self):
        gitlab_ci = (self.ROOT / ".gitlab-ci.yml").read_text(encoding="utf-8")
        self.assertIn('CI_PIPELINE_SOURCE == "web"', gitlab_ci)
        self.assertIn('CI_PIPELINE_SOURCE == "api"', gitlab_ci)
        self.assertIn("core-source-and-elf-validation:", gitlab_ci)
        self.assertIn("unittest discover", gitlab_ci)
        self.assertIn("build_hybrid_runtime_smoke_elf.py", gitlab_ci)
        self.assertIn("build_hybrid_xchg_smoke_elf.py", gitlab_ci)
        self.assertNotIn("swiftc", gitlab_ci)
        self.assertNotIn("xcodebuild", gitlab_ci)

    def test_runtime_regression_tests_are_owned_by_github_actions(self):
        workflow = (self.ROOT / ".github" / "workflows" / "validate-repository.yml").read_text(encoding="utf-8")
        required = (
            "swift-runtime-tests:",
            "test_static_elf_execution.swift",
            "python -m unittest discover -s scripts/tests -p 'test_*.py'",
            "test-native-guest-memory",
            "test-qemu-native-bridge",
        )
        for contract in required:
            with self.subTest(contract=contract):
                self.assertIn(contract, workflow)

    def test_validation_runs_for_pushes_and_pull_requests(self):
        workflow = (self.ROOT / ".github" / "workflows" / "validate-repository.yml").read_text(encoding="utf-8")
        self.assertIn("  push:", workflow)
        self.assertIn("  pull_request:", workflow)
        self.assertIn("  workflow_dispatch:", workflow)

    def test_metrics_workflow_uploads_artifacts_without_repository_writes(self):
        workflow = (self.ROOT / ".github" / "workflows" / "Update stats.yml").read_text(encoding="utf-8")
        self.assertIn("needs: cancel-stale", workflow)
        self.assertEqual(workflow.count("output_action: none"), 2)
        self.assertEqual(workflow.count("uses: actions/upload-artifact@v4"), 2)
        self.assertEqual(workflow.count("retention-days: 30"), 2)
        self.assertIn("name: repository-metrics-overview", workflow)
        self.assertIn("name: repository-metrics-team", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("actions: write", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("gh workflow run blank.yml", workflow)
        self.assertNotIn("git push", workflow)


if __name__ == "__main__":
    unittest.main()
