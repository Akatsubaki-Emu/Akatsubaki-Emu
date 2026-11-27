import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from audit_qemu_runtime_licenses import build_report


class QEMULicenseAuditTests(unittest.TestCase):
    def test_generates_metadata_only_inventory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            utm = root / "UTM"
            package = root / "package"
            output = root / "audit"
            (utm / "build-iOS-arm64" / "glib").mkdir(parents=True)
            (utm / "src").mkdir()
            (utm / "LICENSE").write_text("Example license text\n", encoding="utf-8")
            (utm / "src" / "guest.c").write_text(
                "/* SPDX-License-Identifier: MIT */\nint main(void) { return 0; }\n",
                encoding="utf-8",
            )
            (utm / "build-iOS-arm64" / "glib" / "COPYING").write_text(
                "GLib license placeholder\n", encoding="utf-8"
            )
            frameworks = package / "Frameworks" / "Test.framework"
            frameworks.mkdir(parents=True)
            (frameworks / "Test").write_bytes(b"not-a-real-binary; metadata only")
            with (frameworks / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": "Test", "CFBundleIdentifier": "org.example.Test"}, stream)
            qemu_lib = package / "QEMU" / "JIT" / "libqemu-test.dylib"
            qemu_lib.parent.mkdir(parents=True)
            qemu_lib.write_bytes(b"test dylib bytes")
            firmware = package / "QEMU" / "TCI" / "share" / "qemu" / "edk2-x86_64-code.fd"
            firmware.parent.mkdir(parents=True)
            firmware.write_bytes(b"firmware bytes")
            outside = root / "outside.bin"
            outside.write_bytes(b"must not be hashed through a package symlink")
            external_link = package / "QEMU" / "TCI" / "external-link.bin"
            external_link.symlink_to(outside)
            (package / "dependency-report.txt").write_text("===== Frameworks/Test.framework/Test =====\n", encoding="utf-8")
            (package / "runtime-file-inventory.txt").write_text("Frameworks/Test.framework/Test\n", encoding="utf-8")
            (package / "BUILD-INFO.txt").write_text("Target: physical iOS arm64\n", encoding="utf-8")
            (package / "QEMU-SOURCE-URL.txt").write_text("https://example.invalid/qemu.tar.xz\n", encoding="utf-8")
            (package / "UTM-SOURCE-REVISION.txt").write_text("abc123\n", encoding="utf-8")

            manifest = build_report(utm, package, output)
            self.assertEqual(manifest["license_file_count"], 2)
            self.assertEqual(manifest["spdx_expression_counts"], {"MIT": 1})
            self.assertEqual(manifest["framework_count"], 1)
            self.assertEqual(manifest["runtime_library_count"], 1)
            self.assertEqual(manifest["package_file_count"], len(manifest["package_files"]))
            firmware_entry = next(item for item in manifest["package_files"] if item["path"].endswith("edk2-x86_64-code.fd"))
            self.assertEqual(firmware_entry["category"], "firmware-data")
            self.assertEqual(firmware_entry["sha256"], __import__("hashlib").sha256(b"firmware bytes").hexdigest())
            symlink_entry = next(item for item in manifest["package_files"] if item["path"].endswith("external-link.bin"))
            self.assertEqual(symlink_entry["category"], "symlink")
            self.assertNotIn("sha256", symlink_entry)
            self.assertEqual(manifest["runtime_libraries"][0]["path"], "QEMU/JIT/libqemu-test.dylib")
            self.assertEqual(manifest["frameworks"][0]["bundle_identifier"], "org.example.Test")
            self.assertTrue((output / "dependency-report.txt").is_file())
            self.assertTrue((output / "license-review.md").is_file())
            self.assertTrue((output / "license-manifest.json").is_file())
            self.assertFalse((output / "Frameworks" / "Test.framework" / "Test").exists())
            self.assertFalse((output / "QEMU" / "JIT" / "libqemu-test.dylib").exists())
            saved = json.loads((output / "license-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["review_status"], "INVENTORY_ONLY_REQUIRES_QUALIFIED_LICENSE_REVIEW")

    def test_rejects_output_inside_source_or_package(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            utm = root / "UTM"
            package = root / "package"
            utm.mkdir()
            package.mkdir()
            with self.assertRaises(ValueError):
                build_report(utm, package, utm / "audit")
            with self.assertRaises(ValueError):
                build_report(utm, package, package / "audit")


if __name__ == "__main__":
    unittest.main()
