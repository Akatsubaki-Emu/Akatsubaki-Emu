from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/build-core-only-ios.yml"
VALIDATOR = ROOT / "scripts/validate-core-only-ipa.sh"
DOC = ROOT / "docs/CORE_ONLY_IOS_TEST_BUILD.md"


class CoreOnlyIOSWorkflowTests(unittest.TestCase):
    def test_manual_unsigned_build_does_not_publish_release(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("runs-on: xcode-27", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("Xcode 27.1 or newer is required", workflow)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", workflow)
        self.assertIn("scripts/validate-core-only-ipa.sh", workflow)
        self.assertIn("test_localdevvpn_callback.swift", workflow)
        self.assertIn("actions/checkout@v7", workflow)
        self.assertIn("actions/upload-artifact@v7", workflow)
        self.assertNotIn("softprops/action-gh-release", workflow)
        self.assertNotIn("gh release create", workflow)

    def test_core_only_validator_rejects_embedded_qemu_runtime(self):
        validator = VALIDATOR.read_text()
        self.assertIn("lipo -verify_arch arm64", validator)
        self.assertIn("platform IOS", validator)
        self.assertIn("QEMU runtime content found", validator)
        self.assertIn("QEMU_EFI", validator)
        self.assertIn("otool -L", validator)
        self.assertIn("embedded.mobileprovision", validator)

    def test_document_explains_scope_and_signing(self):
        doc = DOC.read_text()
        self.assertIn("no QEMU runtime", doc)
        self.assertIn("SideStore", doc)
        self.assertIn("full-system VM", doc)
