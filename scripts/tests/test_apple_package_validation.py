import unittest
from pathlib import Path


class ApplePackageValidationTests(unittest.TestCase):
    def test_validator_checks_bundle_identity_and_executable_payload(self):
        script = (Path(__file__).resolve().parents[1] / "validate-apple-package.sh").read_text(encoding="utf-8")
        required = (
            "Print :CFBundleIdentifier",
            "Print :CFBundlePackageType",
            'if [ "$actual_package_type" != "APPL" ]; then',
            "Print :CFBundleExecutable",
            'executable_path="Payload/$app_name/$actual_executable"',
            'unzip -p "$archive" "$executable_path" > "$executable"',
            'file "$executable" | grep -q "Mach-O"',
            'lipo -verify_arch arm64 "$executable"',
        )
        for token in required:
            with self.subTest(token=token):
                self.assertIn(token, script)

    def test_validator_rejects_non_basename_app_paths(self):
        script = (Path(__file__).resolve().parents[1] / "validate-apple-package.sh").read_text(encoding="utf-8")
        self.assertIn('""|.|..|*/*)', script)


if __name__ == "__main__":
    unittest.main()
