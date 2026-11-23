#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_qemu_meson_ios
import verify_qemu_meson_link


class QEMUObjectiveCCompileFlagTests(unittest.TestCase):
    def meson_source(self):
        return (
            "project('qemu', 'c')\n"
            "if 'objc' in all_languages\n"
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),\n"
            "      native: false, language: 'objc')\n"
            "endif\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
            "emulator_link_args += ['-Wl,-force_load,libqemuutil.a']\n"
        )

    def ninja_source(self, compile_flags):
        return (
            "build libqemu-x86_64-softmmu.dylib.p/ui_spice-display-metal.m.o: objc_COMPILER ../ui/spice-display-metal.m\n"
            f"  FLAGS = -O2 {compile_flags}\n"
            "build libqemu-x86_64-softmmu.dylib: c_LINKER objects\n"
            "  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a\n"
        )

    def test_meson_patcher_adds_required_objc_flag_and_is_idempotent(self):
        once = patch_qemu_meson_ios.patch_source(self.meson_source(), "/toolchain/libclang_rt.ios.a")
        twice = patch_qemu_meson_ios.patch_source(once, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(once, twice)
        self.assertIn("-fno-objc-msgsend-class-selector-stubs", once)
        self.assertIn("checked: 'require'", once)

    def test_meson_patcher_changes_only_the_objc_compiler_block(self):
        source = "objc.get_supported_arguments(warn_flags)\n" + self.meson_source()
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("-fno-objc-msgsend-class-selector-stubs"), 1)
        self.assertTrue(patched.startswith("objc.get_supported_arguments(warn_flags)\n"))

    def test_meson_patcher_handles_qemu_common_flags_variant(self):
        source = self.meson_source().replace(
            "objc.get_supported_arguments(warn_flags)",
            "objc.get_supported_arguments(qemu_common_flags + warn_flags)",
        )
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertIn(
            "objc.get_supported_arguments(qemu_common_flags + warn_flags + "
            "['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')",
            patched,
        )


    def test_meson_patcher_fails_closed_if_objc_block_changes(self):
        source = self.meson_source().replace(
            "objc.get_supported_arguments(warn_flags)",
            "objc.get_supported_arguments(other_flags)",
        )
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler argument anchor"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_meson_patcher_fails_closed_if_objc_block_is_missing(self):
        source = self.meson_source().replace("if 'objc' in all_languages" + chr(10), "").replace("endif" + chr(10), "")
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler block not found exactly once"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_meson_patcher_rejects_duplicate_objc_blocks(self):
        source = self.meson_source().replace(
            "if 'objc' in all_languages" + chr(10),
            "if 'objc' in all_languages" + chr(10) + "if 'objc' in all_languages" + chr(10),
        )
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler block not found exactly once"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_meson_patcher_rejects_objc_flag_outside_its_block(self):
        source = self.meson_source() + patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"] + chr(10)
        with self.assertRaisesRegex(SystemExit, "outside its compiler block"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_meson_patcher_rejects_mixed_patched_and_unpatched_objc_calls(self):
        patched = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"]
        source = self.meson_source().replace(
            "objc.get_supported_arguments(warn_flags)",
            patched + chr(10) + "  objc.get_supported_arguments(warn_flags)",
        )
        with self.assertRaisesRegex(SystemExit, "unpatched Objective-C compiler call remains"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_ninja_verifier_requires_flag_on_actual_metal_compile_edge(self):
        verify_qemu_meson_link.verify_link(
            self.ninja_source("-fno-objc-msgsend-class-selector-stubs"),
            "/toolchain/libclang_rt.ios.a",
            require_objc_compile=True,
        )

    def test_ninja_verifier_rejects_missing_compile_flag_even_when_link_flags_exist(self):
        with self.assertRaisesRegex(SystemExit, "Metal Objective-C compile edge is missing"):
            verify_qemu_meson_link.verify_link(
                self.ninja_source("-DOTHER_FLAG"),
                "/toolchain/libclang_rt.ios.a",
                require_objc_compile=True,
            )

    def test_ninja_verifier_rejects_missing_metal_compile_edge(self):
        ninja = (
            "build libqemu-x86_64-softmmu.dylib: c_LINKER objects\n"
            "  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a\n"
        )
        with self.assertRaisesRegex(SystemExit, "no Metal Objective-C compile edge"):
            verify_qemu_meson_link.verify_link(
                ninja,
                "/toolchain/libclang_rt.ios.a",
                require_objc_compile=True,
            )


def source_for(anchor=None, extra_compile_block=False):
    compiler_call = (
        f"  add_project_arguments({anchor}, native: false, language: 'objc')\n"
        if anchor else ""
    )
    source = (
        "project('qemu', 'c')\n"
        "if 'objc' in all_languages\n"
        + compiler_call
        + "endif\n"
        "if 'objc' in all_languages\n"
        "  summary_info += {'Objective-C compiler': 'objc'}\n"
        "endif\n"
        "if 'objc' in all_languages\n"
        "  summary_info += {'OBJCFLAGS': 'objc_args'}\n"
        "endif\n"
        "if 'objc' in all_languages\n"
        "  summary_info += {'Objective-C enabled': 'yes'}\n"
        "endif\n"
        "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
        "emulator_link_args = []\n"
    )
    if extra_compile_block:
        source = source.replace(
            "if 'objc' in all_languages\n  summary_info",
            "if 'objc' in all_languages\n"
            "  add_project_arguments(objc.get_supported_arguments(warn_flags), native: false, language: 'objc')\n"
            "endif\n"
            "if 'objc' in all_languages\n  summary_info",
            1,
        )
    return source


class QEMUObjectiveCCompilerBlockRegressionTests(unittest.TestCase):
    def test_selects_compiler_block_among_four_objc_guards(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        expected = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"]
        self.assertEqual(patched.count("if 'objc' in all_languages"), 4)
        self.assertEqual(patched.count(expected), 1)
        self.assertIn("add_project_arguments(" + expected, patched)
        self.assertIn("summary_info += {'Objective-C compiler': 'objc'}", patched)

    def test_supports_upstream_qemu_common_flags_anchor(self):
        source = source_for("objc.get_supported_arguments(qemu_common_flags + warn_flags)")
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        expected = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(qemu_common_flags + warn_flags)"]
        self.assertEqual(patched.count(expected), 1)

    def test_patch_is_idempotent_with_multiple_feature_guards(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        once = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        twice = patch_qemu_meson_ios.patch_source(once, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(once, twice)

    def test_replaces_stale_runtime_path_without_touching_summary_blocks(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        first = patch_qemu_meson_ios.patch_source(source, "/old/libclang_rt.ios.a")
        updated = patch_qemu_meson_ios.patch_source(first, "/new/libclang_rt.ios.a")
        self.assertNotIn("/old/libclang_rt.ios.a", updated)
        self.assertIn("-Wl,-force_load,/new/libclang_rt.ios.a", updated)
        self.assertEqual(updated.count("if 'objc' in all_languages"), 4)

    def test_rejects_missing_compiler_argument_anchor(self):
        with self.assertRaisesRegex(SystemExit, "compiler block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source_for(None))

    def test_rejects_duplicate_compiler_blocks(self):
        with self.assertRaisesRegex(SystemExit, "compiler block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(
                source_for("objc.get_supported_arguments(warn_flags)", extra_compile_block=True)
            )

    def test_rejects_unterminated_objc_block(self):
        source = "if 'objc' in all_languages\n  objc.get_supported_arguments(warn_flags)\n"
        with self.assertRaisesRegex(SystemExit, "unterminated"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_rejects_patched_flag_outside_compiler_block(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        patch_value = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"]
        source += "if true\n  " + patch_value + "\nendif\n"
        with self.assertRaisesRegex(SystemExit, "outside its compiler block"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_rejects_mixed_patched_and_unpatched_compiler_call(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        patch_value = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"]
        source = source.replace(
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),",
            "  add_project_arguments(" + patch_value + ",\n"
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),",
            1,
        )
        with self.assertRaisesRegex(SystemExit, "unpatched Objective-C compiler call remains"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_rejects_duplicate_patched_compiler_call(self):
        source = source_for(None)
        patch_value = patch_qemu_meson_ios.OBJC_ARGUMENTS["objc.get_supported_arguments(warn_flags)"]
        source = source.replace(
            "if 'objc' in all_languages\nendif",
            "if 'objc' in all_languages\n  " + patch_value + "\n  " + patch_value + "\nendif",
            1,
        )
        with self.assertRaisesRegex(SystemExit, "duplicate"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_rejects_anchor_in_more_than_one_objc_block(self):
        source = source_for("objc.get_supported_arguments(warn_flags)", extra_compile_block=True)
        with self.assertRaisesRegex(SystemExit, "compiler block not found exactly once"):
            patch_qemu_meson_ios.patch_objc_compile_flag(source)

    def test_preserves_all_unrelated_objc_feature_guards(self):
        source = source_for("objc.get_supported_arguments(warn_flags)")
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("if 'objc' in all_languages"), 4)
        self.assertEqual(patched.count("endif"), source.count("endif"))


if __name__ == "__main__":
    unittest.main()
