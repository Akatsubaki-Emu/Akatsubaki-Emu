import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "build-qemu-runtime.yml"


class QEMULicenseAuditWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_metadata_report_upload_is_separate_from_binary_gate(self):
        self.assertIn("Generate QEMU runtime license review report", self.workflow)
        self.assertIn("Upload QEMU runtime license review report (metadata only)", self.workflow)
        report_upload = self.workflow.split(
            "Upload QEMU runtime license review report (metadata only)", 1
        )[1].split("Upload verified QEMU runtime artifact", 1)[0]
        self.assertIn("path: build/qemu-license-review/", report_upload)
        self.assertNotIn("QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED", report_upload)
        binary_upload = self.workflow.split("Upload verified QEMU runtime artifact", 1)[1]
        self.assertIn("vars.QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED == 'true'", binary_upload)

    def test_workflow_tracks_audit_script(self):
        self.assertIn("scripts/audit_qemu_runtime_licenses.py", self.workflow)


if __name__ == "__main__":
    unittest.main()
