import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "validate-kenran-buto-aot.yml"


def paths_for(source: str, event: str, next_event: str) -> list[str]:
    start = source.index(f"  {event}:\n")
    end = source.index(f"  {next_event}:\n", start + 1)
    event_block = source[start:end]
    paths_block = event_block.split("    paths:\n", 1)[1]
    paths = []
    for line in paths_block.splitlines():
        if not line.startswith("      - "):
            break
        value = line[8:].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        paths.append(value)
    return paths


class KenranButoWorkflowTriggerParityTests(unittest.TestCase):
    def test_push_and_pull_request_path_filters_match(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        push = paths_for(source, "push", "pull_request")
        pull_request = paths_for(source, "pull_request", "workflow_dispatch")
        self.assertEqual(push, pull_request)
        self.assertEqual(len(push), len(set(push)))

    def test_allocation_hot_path_regression_triggers_validation(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        for event, next_event in (("push", "pull_request"),
                                  ("pull_request", "workflow_dispatch")):
            paths = paths_for(source, event, next_event)
            self.assertIn("scripts/tests/test_aot_translator_allocation_hot_path.py", paths)
            self.assertIn("scripts/tests/test_aot_workflow_trigger_parity.py", paths)
            self.assertIn("docs/FIRST_PLAYABLE_IOS_ACCEPTANCE.md", paths)


if __name__ == "__main__":
    unittest.main()
