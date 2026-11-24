import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ".github/workflows/build-qemu-runtime.yml",
    ".github/workflows/release.yml",
    ".github/workflows/validate-ios-build.yml",
)
XCODE_VERSION_GUARDS = ("27.1", "27.10", "28.0", "28.1")
XCODE_VERSION_REJECTIONS = ("27.0", "26.4", "27")
GUARD_PATTERN = re.compile(r'awk -v version="\\$XCODE_VERSION"\\s+\'([^\']+)\'')


class XcodeVersionGuardTests(unittest.TestCase):
    def guards(self):
        results = []
        for relative_path in WORKFLOWS:
            content = (ROOT / relative_path).read_text(encoding="utf-8")
            scripts = GUARD_PATTERN.findall(content)
            self.assertTrue(scripts, f"{relative_path} has no numeric Xcode-version guard")
            self.assertNotIn("27.1*|27.[2-9]*", content)
            results.extend((relative_path, script) for script in scripts)
        return results

    @staticmethod
    def accepts(script, version):
        return subprocess.run(
            ["awk", "-v", f"version={version}", script],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).returncode == 0

    def test_all_apple_workflows_accept_xcode_27_10_and_28(self):
        for path, script in self.guards():
            for version in XCODE_VERSION_GUARDS:
                with self.subTest(workflow=path, version=version):
                    self.assertTrue(self.accepts(script, version))

    def test_all_apple_workflows_reject_xcode_27_0_and_older(self):
        for path, script in self.guards():
            for version in XCODE_VERSION_REJECTIONS:
                with self.subTest(workflow=path, version=version):
                    self.assertFalse(self.accepts(script, version))


if __name__ == "__main__":
    unittest.main()
