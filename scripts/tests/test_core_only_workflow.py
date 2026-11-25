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
        ipa_checksum = 'shasum -a 256 "$DIST/Akatsubaki-Emu-CoreOnly-iOS.ipa" > "$DIST/Akatsubaki-Emu-CoreOnly-iOS.ipa.sha256"'
        self.assertIn(ipa_checksum, workflow)
        self.assertLess(workflow.index(ipa_checksum), workflow.index("Validate core-only IPA"))
        self.assertIn("IPA SHA-256:", workflow)
        self.assertIn("test_localdevvpn_callback.swift", workflow)
        self.assertIn("test_translation_cache.swift", workflow)
        self.assertIn("test_kenran_buto_aot_cache.swift", workflow)
        self.assertIn("test_elf_loader_program_headers.swift", workflow)
        self.assertIn("test_linux_syscall_dispatcher.swift", workflow)
        self.assertIn("test_linux_process_stack.swift", workflow)
        self.assertIn("test_native_guest_memory.cpp", workflow)
        self.assertIn("test_guest_memory_native_integration.swift", workflow)
        self.assertIn("actions/checkout@v7", workflow)
        self.assertIn("actions/upload-artifact@v7", workflow)
        self.assertIn("brew list xcodegen", workflow)
        self.assertIn("xcodegen generate --spec project.yml", workflow)
        self.assertLess(
            workflow.index("xcodegen generate --spec project.yml"),
            workflow.index("Build iOS device app without code signing"),
        )
        self.assertIn("scripts/build_hybrid_xchg_smoke_elf.py", workflow)
        self.assertIn('cp "$RUNNER_TEMP/hybrid_xchg_smoke.elf" "$DIST/hybrid_xchg_smoke.elf"', workflow)
        project = (ROOT / "project.yml").read_text()
        self.assertIn('CLANG_CXX_LANGUAGE_STANDARD: "gnu++17"', project)
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
        self.assertIn("Akatsubaki-Emu-CoreOnly-iOS.ipa.sha256", doc)
