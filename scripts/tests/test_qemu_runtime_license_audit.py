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
    def test_generates_metadata_only_inventory_with_safe_package_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            utm = root / "UTM"
            package = root / "bios" / "package"
            output = root / "audit"
            (utm / "build-iOS-arm64" / "glib").mkdir(parents=True)
            (utm / "src").mkdir()
            (utm / "LICENSE").write_text("Example license text\n", encoding="utf-8")
            (utm / "src" / "guest.c").write_text(
                "/* SPDX-License-Identifier: MIT */\nint main(void) { return 0; }\n",
                encoding="utf-8",
            )
            outside_source = root / "outside-source.c"
            outside_source.write_text(
                "/* SPDX-License-Identifier: GPL-2.0-only */\nint external(void) { return 0; }\n",
                encoding="utf-8",
            )
            (utm / "src" / "external.c").symlink_to(outside_source)
            (utm / "build-iOS-arm64" / "glib" / "COPYING").write_text(
                "GLib license placeholder\n", encoding="utf-8"
            )

            frameworks = package / "Frameworks" / "Test.framework"
            frameworks.mkdir(parents=True)
            (frameworks / "Test").write_bytes(b"not-a-real-binary; metadata only")
            with (frameworks / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": "Test", "CFBundleIdentifier": "org.example.Test"}, stream)

            outside_framework = root / "outside" / "External.framework"
            outside_framework.mkdir(parents=True)
            (outside_framework / "External").write_bytes(b"outside framework binary")
            with (outside_framework / "Info.plist").open("wb") as stream:
                plistlib.dump(
                    {"CFBundleExecutable": "External", "CFBundleIdentifier": "org.example.External"},
                    stream,
                )
            (package / "Frameworks" / "External.framework").symlink_to(
                outside_framework, target_is_directory=True
            )

            qemu_lib = package / "QEMU" / "JIT" / "libqemu-test.dylib"
            qemu_lib.parent.mkdir(parents=True)
            qemu_lib.write_bytes(b"test dylib bytes")
            outside_runtime = root / "outside-runtime.dylib"
            outside_runtime.write_bytes(b"must not be hashed through a package symlink")
            external_runtime_link = package / "QEMU" / "TCI" / "external-runtime.dylib"
            external_runtime_link.parent.mkdir(parents=True)
            external_runtime_link.symlink_to(outside_runtime)

            firmware = package / "QEMU" / "TCI" / "share" / "qemu" / "edk2-x86_64-code.fd"
            firmware.parent.mkdir(parents=True)
            firmware.write_bytes(b"firmware bytes")
            outside = root / "outside.bin"
            outside.write_bytes(b"must not be hashed through a package symlink")
            external_link = package / "QEMU" / "TCI" / "external-link.bin"
            external_link.symlink_to(outside)

            (package / "QEMU" / "runtime-mode-manifest.txt").write_text(
                "mode=TCI\n", encoding="utf-8"
            )
            (package / "dependency-report.txt").write_text(
                "===== Frameworks/Test.framework/Test =====\n", encoding="utf-8"
            )
            (package / "runtime-file-inventory.txt").write_text(
                "Frameworks/Test.framework/Test\n", encoding="utf-8"
            )
            (package / "BUILD-INFO.txt").write_text(
                "Target: physical iOS arm64\n", encoding="utf-8"
            )
            outside_qemu_url = root / "outside-qemu-source-url.txt"
            outside_qemu_url.write_text(
                "https://outside.invalid/qemu.tar.xz\n", encoding="utf-8"
            )
            (package / "QEMU-SOURCE-URL.txt").symlink_to(outside_qemu_url)
            outside_utm_revision = root / "outside-utm-revision.txt"
            outside_utm_revision.write_text("external-revision-secret\n", encoding="utf-8")
            (package / "UTM-SOURCE-REVISION.txt").symlink_to(outside_utm_revision)
            outside_report = root / "outside-runtime-exports.txt"
            outside_report.write_text("external-runtime-report-secret\n", encoding="utf-8")
            (package / "QEMU" / "JIT" / "exports.txt").symlink_to(outside_report)

            manifest = build_report(utm, package, output)
            self.assertEqual(manifest["license_file_count"], 2)
            self.assertEqual(manifest["spdx_expression_counts"], {"MIT": 1})
            self.assertEqual(manifest["framework_count"], 1)
            self.assertEqual(manifest["runtime_library_count"], 1)
            self.assertEqual(manifest["package_file_count"], len(manifest["package_files"]))

            firmware_entry = next(
                item for item in manifest["package_files"]
                if item["path"].endswith("edk2-x86_64-code.fd")
            )
            self.assertEqual(firmware_entry["category"], "firmware-data")
            self.assertEqual(
                firmware_entry["sha256"],
                __import__("hashlib").sha256(b"firmware bytes").hexdigest(),
            )
            library_entry = next(
                item for item in manifest["package_files"]
                if item["path"] == "QEMU/JIT/libqemu-test.dylib"
            )
            self.assertEqual(library_entry["category"], "runtime-library")
            provenance_entry = next(
                item for item in manifest["package_files"]
                if item["path"] == "QEMU/runtime-mode-manifest.txt"
            )
            self.assertEqual(provenance_entry["category"], "build-provenance")

            symlink_entry = next(
                item for item in manifest["package_files"]
                if item["path"] == "QEMU/TCI/external-link.bin"
            )
            self.assertEqual(symlink_entry["category"], "symlink")
            self.assertNotIn("sha256", symlink_entry)
            external_runtime_entry = next(
                item for item in manifest["package_files"]
                if item["path"] == "QEMU/TCI/external-runtime.dylib"
            )
            self.assertEqual(external_runtime_entry["category"], "symlink")
            self.assertNotIn("sha256", external_runtime_entry)
            external_framework_entry = next(
                item for item in manifest["package_files"]
                if item["path"] == "Frameworks/External.framework"
            )
            self.assertEqual(external_framework_entry["category"], "symlink")
            self.assertNotIn("sha256", external_framework_entry)

            self.assertEqual(
                [item["path"] for item in manifest["runtime_libraries"]],
                ["QEMU/JIT/libqemu-test.dylib"],
            )
            self.assertEqual(manifest["frameworks"][0]["bundle_identifier"], "org.example.Test")
            self.assertTrue((output / "dependency-report.txt").is_file())
            self.assertTrue((output / "QEMU" / "runtime-mode-manifest.txt").is_file())
            self.assertFalse((output / "QEMU" / "JIT" / "exports.txt").exists())
            self.assertFalse((output / "QEMU-SOURCE-URL.txt").exists())
            self.assertFalse((output / "UTM-SOURCE-REVISION.txt").exists())
            self.assertNotIn("QEMU/JIT/exports.txt", manifest["copied_package_reports"])
            self.assertNotIn("QEMU-SOURCE-URL.txt", manifest["copied_package_reports"])
            self.assertNotIn("UTM-SOURCE-REVISION.txt", manifest["copied_package_reports"])
            review_text = (output / "license-review.md").read_text(encoding="utf-8")
            self.assertIn("QEMU source URL: not recorded", review_text)
            self.assertIn("UTM source revision: not recorded", review_text)
            self.assertNotIn("outside.invalid", review_text)
            self.assertNotIn("external-revision-secret", review_text)
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
