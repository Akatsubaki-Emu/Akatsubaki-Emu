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
        self.assertIn("objc.get_supported_arguments(warn_flags, checked: 'off')", once)
        self.assertIn("objc.get_supported_arguments(['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')", once)
        self.assertNotIn("warn_flags + ['-fno-objc-msgsend-class-selector-stubs']", once)

    def test_meson_patcher_changes_only_the_objc_compiler_block(self):
        source = "objc.get_supported_arguments(warn_flags)\n" + self.meson_source()
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("-fno-objc-msgsend-class-selector-stubs"), 1)
        self.assertTrue(patched.startswith("objc.get_supported_arguments(warn_flags)\n"))

    def test_meson_patcher_ignores_later_objc_summary_conditionals(self):
        # Match all four Objective-C conditionals in upstream QEMU v10.0.12-utm:
        # one compiler-argument block and three summary-only blocks.
        source = self.meson_source() + (
            "if 'objc' in all_languages\n"
            "  summary_info += {'Objective-C compiler': ' '.join(meson.get_compiler('objc').cmd_array())}\n"
            "else\n"
            "  summary_info += {'Objective-C compiler': false}\n"
            "endif\n"
            "if 'objc' in all_languages\n"
            "  summary_info += {'OBJCFLAGS': ' '.join(get_option('objc_args') + option_cflags)}\n"
            "endif\n"
            "if 'objc' in all_languages\n"
            "  summary_info += {'QEMU_OBJCFLAGS': ' '.join(qemu_common_flags)}\n"
            "endif\n"
        )
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("if 'objc' in all_languages"), 4)
        self.assertEqual(patched.count("-fno-objc-msgsend-class-selector-stubs"), 1)
        self.assertIn("summary_info += {'Objective-C compiler'", patched)
        self.assertIn("summary_info += {'OBJCFLAGS'", patched)
        self.assertIn("summary_info += {'QEMU_OBJCFLAGS'", patched)


    def test_meson_patcher_handles_nested_if_before_compiler_call(self):
        compiler_call = (
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),\n"
            "      native: false, language: 'objc')\n"
        )
        nested = (
            "  if cc.has_argument('-fobjc-arc')\n"
            "    add_project_arguments(['-fobjc-arc'], native: false, language: 'objc')\n"
            "  endif # nested close\n"
        )
        source = self.meson_source().replace(compiler_call, nested + compiler_call)
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("-fno-objc-msgsend-class-selector-stubs"), 1)
        self.assertIn("if cc.has_argument('-fobjc-arc')", patched)
        self.assertEqual(patch_qemu_meson_ios.patch_source(patched, "/toolchain/libclang_rt.ios.a"), patched)


    def test_meson_patcher_rejects_unterminated_nested_if(self):
        compiler_call = (
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),\n"
            "      native: false, language: 'objc')\n"
        )
        nested = (
            "  if cc.has_argument('-fobjc-arc')\n"
            "    add_project_arguments(['-fobjc-arc'], native: false, language: 'objc')\n"
        )
        source = self.meson_source().replace(compiler_call, nested + compiler_call)
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler block is unterminated"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")


    def test_meson_patcher_handles_qemu_common_flags_variant(self):
        source = self.meson_source().replace(
            "objc.get_supported_arguments(warn_flags)",
            "objc.get_supported_arguments(qemu_common_flags + warn_flags)",
        )
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertIn(
            "objc.get_supported_arguments(qemu_common_flags + warn_flags, checked: 'off') + "
            "objc.get_supported_arguments(['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')",
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
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler block not found"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_meson_patcher_rejects_duplicate_objc_blocks(self):
        compiler_block = (
            "if 'objc' in all_languages\n"
            "  add_project_arguments(objc.get_supported_arguments(warn_flags),\n"
            "      native: false, language: 'objc')\n"
            "endif\n"
        )
        source = self.meson_source().replace(compiler_block, compiler_block + compiler_block)
        with self.assertRaisesRegex(SystemExit, "exactly one Objective-C compiler configuration block"):
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


if __name__ == "__main__":
    unittest.main()
