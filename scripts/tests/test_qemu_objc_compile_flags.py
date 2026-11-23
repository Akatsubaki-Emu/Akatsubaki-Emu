#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_qemu_meson_ios


COMPILER = "objc.get_supported_arguments(warn_flags)"
PATCHED = (
    "objc.get_supported_arguments(warn_flags + "
    "['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')"
)
FOUR_BLOCKS = """if 'objc' in all_languages
  summary_info += {'Objective-C compiler': true}
endif
if 'objc' in all_languages
  summary_info += {'OBJCFLAGS': true}
endif
if 'objc' in all_languages
  objc.get_supported_arguments(warn_flags)
endif
if 'objc' in all_languages
  summary_info += {'QEMU_OBJCFLAGS': true}
endif
"""


class QEMUObjectiveCCompileFlagTests(unittest.TestCase):
    def test_selects_only_the_compiler_argument_block_among_four_conditionals(self):
        patched = patch_qemu_meson_ios.patch_objc_compile_flag(FOUR_BLOCKS)
        self.assertEqual(patched.count("if 'objc' in all_languages"), 4)
        self.assertEqual(patched.count(PATCHED), 1)
        self.assertEqual(patched.count(COMPILER), 0)
        for summary in (
            "summary_info += {'Objective-C compiler': true}",
            "summary_info += {'OBJCFLAGS': true}",
            "summary_info += {'QEMU_OBJCFLAGS': true}",
        ):
            self.assertIn(summary, patched)

    def test_patch_is_idempotent_with_multiple_objective_c_blocks(self):
        once = patch_qemu_meson_ios.patch_objc_compile_flag(FOUR_BLOCKS)
        self.assertEqual(patch_qemu_meson_ios.patch_objc_compile_flag(once), once)

    def test_supports_the_qemu_common_flags_anchor(self):
        source = FOUR_BLOCKS.replace(
            COMPILER, "objc.get_supported_arguments(qemu_common_flags + warn_flags)"
        )
        patched = patch_qemu_meson_ios.patch_objc_compile_flag(source)
        self.assertIn(
            "objc.get_supported_arguments(qemu_common_flags + warn_flags + "
            "['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')",
            patched,
        )

    def test_missing_compiler_argument_block_fails_closed(self):
        source = FOUR_BLOCKS.replace("  " + COMPILER + "\n", "")
        with self.assertRaisesRegex(SystemExit, "compiler-argument block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_duplicate_anchor_in_one_block_fails_closed(self):
        source = FOUR_BLOCKS.replace(COMPILER, COMPILER + "\n  " + COMPILER)
        with self.assertRaisesRegex(SystemExit, "duplicate Objective-C compiler argument anchor"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_duplicate_anchor_across_conditional_blocks_fails_closed(self):
        source = FOUR_BLOCKS.replace(
            "if 'objc' in all_languages\n  summary_info += {'QEMU_OBJCFLAGS': true}\nendif",
            "if 'objc' in all_languages\n  " + COMPILER + "\nendif",
        )
        with self.assertRaisesRegex(SystemExit, "duplicate Objective-C compiler argument anchor"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_unterminated_objective_c_block_fails_closed(self):
        source = FOUR_BLOCKS.replace("  " + COMPILER + "\nendif", "  " + COMPILER)
        with self.assertRaisesRegex(SystemExit, "conditional block is unterminated"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_missing_objective_c_conditionals_fails_closed(self):
        with self.assertRaisesRegex(SystemExit, "compiler-argument block not found"):
            patch_qemu_meson_ios.patch_objc_compile_flag("project('qemu', 'c')\n")

    def test_already_patched_compiler_block_is_accepted(self):
        once = patch_qemu_meson_ios.patch_objc_compile_flag(FOUR_BLOCKS)
        self.assertEqual(patch_qemu_meson_ios.patch_objc_compile_flag(once), once)

    def test_patched_form_outside_compiler_block_fails_closed(self):
        source = FOUR_BLOCKS.replace(
            "if 'objc' in all_languages\n  summary_info += {'QEMU_OBJCFLAGS': true}\nendif",
            "if 'objc' in all_languages\n  " + PATCHED + "\nendif",
        )
        with self.assertRaisesRegex(SystemExit, "compiler-argument block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_mixed_patched_and_unpatched_blocks_fail_closed(self):
        source = FOUR_BLOCKS.replace(COMPILER, PATCHED) + (
            "if 'objc' in all_languages\n  " + COMPILER + "\nendif\n"
        )
        with self.assertRaisesRegex(SystemExit, "compiler-argument block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)


if __name__ == "__main__":
    unittest.main()
