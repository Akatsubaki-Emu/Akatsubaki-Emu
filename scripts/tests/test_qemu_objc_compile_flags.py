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
            "  add_project_arguments(objc.get_supported_arguments(qemu_common_flags + warn_flags),\n"
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
        source = "objc.get_supported_arguments(qemu_common_flags + warn_flags)\n" + self.meson_source()
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        self.assertEqual(patched.count("-fno-objc-msgsend-class-selector-stubs"), 1)
        self.assertTrue(patched.startswith("objc.get_supported_arguments(qemu_common_flags + warn_flags)\n"))

    def test_meson_patcher_fails_closed_if_objc_block_is_missing(self):
        source = self.meson_source().replace("if 'objc' in all_languages\n", "")
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler block not found"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
    def test_meson_patcher_fails_closed_if_objc_block_changes(self):
        source = self.meson_source().replace(
            "objc.get_supported_arguments(qemu_common_flags + warn_flags)",
            "objc.get_supported_arguments(warn_flags)",
        )
        with self.assertRaisesRegex(SystemExit, "Objective-C compiler argument anchor"):
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
