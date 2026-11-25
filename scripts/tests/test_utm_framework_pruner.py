#!/usr/bin/env python3
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from prune_utm_missing_qemu_frameworks import patch_project


class UTMFrameworkPrunerTests(unittest.TestCase):
    def project_fixture(self):
        return '''/* Begin PBXBuildFile section */
AAAAAAAAAAAAAAAAAAAAAAAA /* qemu-x86_64-softmmu.framework in Embed Libraries */ = {isa = PBXBuildFile; fileRef = BBBBBBBBBBBBBBBBBBBBBBBB /* qemu-x86_64-softmmu.framework */; };
CCCCCCCCCCCCCCCCCCCCCCCC /* qemu-xtensa-softmmu.framework in Embed Libraries */ = {isa = PBXBuildFile; fileRef = DDDDDDDDDDDDDDDDDDDDDDDD /* qemu-xtensa-softmmu.framework */; };
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
BBBBBBBBBBBBBBBBBBBBBBBB /* qemu-x86_64-softmmu.framework */ = {isa = PBXFileReference; path = qemu-x86_64-softmmu.framework; };
DDDDDDDDDDDDDDDDDDDDDDDD /* qemu-xtensa-softmmu.framework */ = {isa = PBXFileReference; path = qemu-xtensa-softmmu.framework; };
/* End PBXFileReference section */
/* Begin PBXFrameworksBuildPhase section */
EEEEEEEEEEEEEEEEEEEEEEEE /* Frameworks */ = {isa = PBXFrameworksBuildPhase; files = (
AAAAAAAAAAAAAAAAAAAAAAAA /* qemu-x86_64-softmmu.framework in Embed Libraries */,
CCCCCCCCCCCCCCCCCCCCCCCC /* qemu-xtensa-softmmu.framework in Embed Libraries */,
); };
/* End PBXFrameworksBuildPhase section */
'''

    def test_removes_missing_framework_objects_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            (frameworks / "qemu-x86_64-softmmu.framework").mkdir()
            source = self.project_fixture()
            patched, removed = patch_project(source, frameworks)
            repeated, removed_again = patch_project(patched, frameworks)

        self.assertEqual(removed, ["qemu-xtensa-softmmu.framework"])
        self.assertEqual(removed_again, [])
        self.assertEqual(patched, repeated)
        self.assertIn("qemu-x86_64-softmmu.framework", patched)
        self.assertNotIn("qemu-xtensa-softmmu.framework", patched)
        for object_id in ("CCCCCCCCCCCCCCCCCCCCCCCC", "DDDDDDDDDDDDDDDDDDDDDDDD"):
            self.assertNotIn(object_id, patched)

    def test_fails_closed_when_required_x86_64_framework_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "required x86_64"):
                patch_project(self.project_fixture(), Path(temporary))

    def test_qemu_workflow_prunes_each_sysroot_before_archive(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / ".github" / "workflows" / "build-qemu-runtime.yml")
        if not workflow.exists():
            workflow = root / ".github" / "workflows" / "build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn('"scripts/prune_utm_missing_qemu_frameworks.py"', source)
        self.assertIn("UTM/sysroot-iOS-arm64/Frameworks", source)
        self.assertIn("UTM/sysroot-iOS-TCI-arm64/Frameworks", source)
        self.assertLess(source.index("UTM/sysroot-iOS-arm64/Frameworks"), source.index("- name: Build UTM iOS archive"))
        self.assertLess(source.index("UTM/sysroot-iOS-TCI-arm64/Frameworks"), source.index("- name: Build UTM iOS TCI archive"))


if __name__ == "__main__":
    unittest.main()
