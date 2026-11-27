from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build_fexcore_ios.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "build-fexcore-ios.yml"
DOC = ROOT / "docs" / "FEXCORE_IOS_FORK_BUILD.md"
PIN = "1dc6ed4932bd231df1c53dd7b8043ffdee0ac34a"


class FEXCoreIOSBuildContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text(encoding="utf-8")
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.doc = DOC.read_text(encoding="utf-8")

    def test_workflow_uses_one_pinned_recursive_source_revision(self):
        self.assertIn(f"ref: {PIN}", self.workflow)
        self.assertIn("repository: willfaust/FEX", self.workflow)
        self.assertIn("submodules: recursive", self.workflow)
        self.assertIn("runs-on: xcode-27", self.workflow)
        self.assertIn("workflow_dispatch:", self.workflow)
        self.assertIn("retention-days: 7", self.workflow)
        self.assertIn("not a release", self.workflow)

    def test_build_targets_and_archives_match_fexcore_dependency_graph(self):
        self.assertIn(f'FEX_PIN="{PIN}"', self.script)
        self.assertIn("CMAKE_SYSTEM_NAME=iOS", self.script)
        self.assertIn("CMAKE_OSX_ARCHITECTURES=arm64", self.script)
        for target in ("FEXCore", "FEXCore_Base", "JemallocLibs", "fmt", "cephes_128bit", "softfloat_3e", "xxhash"):
            self.assertRegex(self.script, rf"\b{re.escape(target)}\b")
        for archive in ("libFEXCore.a", "libFEXCore_Base.a", "libJemallocLibs.a", "libfmt.a", "libcephes_128bit.a", "libsoftfloat_3e.a", "libxxhash.a"):
            self.assertIn(archive, self.script)

    def test_build_checks_public_api_and_device_platform(self):
        for symbol in ("CreateNewContext", "ExecuteThread", "CreateThread", "DestroyThread"):
            self.assertIn(symbol, self.script)
        self.assertIn("vtool -show-build", self.script)
        self.assertIn("platform IOS", self.script)
        self.assertIn("LC_BUILD_VERSION", self.script)

    def test_generated_public_headers_and_license_provenance_are_packaged(self):
        for header in ("IRDefines.inc", "IRDefines_Dispatch.inc", "ConfigValues.inl", "ConfigOptions.inl", "git_version.h"):
            self.assertIn(header, self.script)
        for license in ("LICENSE-MADEIRA.md", "COPYING.GPL-3.0", "FEX-MIT-LICENSE.txt", "FEX-GITMODULES.txt"):
            self.assertIn(license, self.script)

    def test_consumer_probe_covers_transitive_headers_and_correct_shell_escapes(self):
        for include in ("External/fmt/include", "External/unordered_dense/include", "External/cephes/include", "External/SoftFloat-3e/include", "CodeEmitter", "FEXHeaderUtils"):
            self.assertIn(include, self.script)
        self.assertIn("External/xxhash/xxhash.h", self.script)
        self.assertIn("fexcore_ios_api_probe.cpp", self.script)
        self.assertIn("FEXCore::HostFeatures Features{}", self.script)
        self.assertIn("-fsyntax-only", self.script)
        self.assertIn("printf '%s\\n'", self.script)
        self.assertNotIn("printf '%s\\\\n'", self.script)
        lines = self.script.splitlines()
        compiler_line = next(i for i, line in enumerate(lines) if "xcrun --sdk iphoneos clang++" in line)
        self.assertTrue(lines[compiler_line].endswith("\\"))
        self.assertIn("-std=c++20", lines[compiler_line + 1])

    def test_output_paths_are_confined_before_cleanup(self):
        self.assertIn("resolve_output_dir", self.script)
        self.assertIn('[[ ! -L "$requested" ]]', self.script)
        self.assertIn("must be inside", self.script)
        self.assertIn("FEX_DIST_DIR must not overlap FEX_BUILD_DIR", self.script)
        self.assertIn('mktemp -d "$safe_temp_root/fexcore-ios-platform-check.XXXXXX"', self.script)
        self.assertLess(self.script.index('FEX_DIST_DIR="$(resolve_output_dir'), self.script.index('rm -rf "$FEX_DIST_DIR"'))
    def test_document_does_not_claim_operational_runtime_or_kernel_boot(self):
        self.assertIn("not an operational guest runtime", self.doc)
        self.assertIn("not linked into the app yet", self.doc)
        self.assertIn("does not boot a Linux/Windows kernel", self.doc)
        self.assertIn("physical iPad guest execution", self.doc)


if __name__ == "__main__":
    unittest.main()
