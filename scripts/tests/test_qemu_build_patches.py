#!/usr/bin/env python3
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_qemu_meson_ios
import patch_utm_qemu_ios
import verify_qemu_meson_link


class QEMUBuildPatchTests(unittest.TestCase):
    def test_qemu_meson_patch_is_idempotent_and_targets_emulator_link_args(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', "
            "cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
            "link_args = emulator_link_args\n"
        )
        runtime = "/toolchain/libclang_rt.ios.a"
        once = patch_qemu_meson_ios.patch_source(source, runtime)
        twice = patch_qemu_meson_ios.patch_source(once, runtime)
        self.assertEqual(once, twice)
        self.assertIn("config_host_data.set('CONFIG_POSIX_MEMALIGN', true)", twice)
        self.assertIn("emulator_link_args += ['-Wl,-force_load," + runtime + "']", twice)
        self.assertLess(twice.index("emulator_link_args = []"), twice.index("emulator_link_args +="))
        self.assertIn("link_args = emulator_link_args", twice)
        self.assertNotIn("add_project_link_arguments", twice)

    def test_qemu_meson_patch_replaces_a_stale_runtime_path(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
        )
        first = patch_qemu_meson_ios.patch_source(source, "/old/libclang_rt.ios.a")
        updated = patch_qemu_meson_ios.patch_source(first, "/new/libclang_rt.ios.a")
        self.assertNotIn("/old/libclang_rt.ios.a", updated)
        self.assertIn("-Wl,-force_load,/new/libclang_rt.ios.a", updated)
        self.assertEqual(updated.count("emulator_link_args += "), 1)

    def test_qemu_meson_patch_fails_if_emulator_link_anchor_changes(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
        )
        with self.assertRaisesRegex(SystemExit, "emulator_link_args declaration not found"):
            patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")

    def test_utm_patch_is_idempotent_and_verifies_actual_qemu_link(self):
        source = '''#!/bin/sh
generate_meson_cross() {
    echo "has_function_dup3 = false" >> $cross
}
QEMU_PLATFORM_BUILD_FLAGS="--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"
download () {
    URL=$1
    FILE="$(basename $URL)"
}
build () {
    if [ -z "$REBUILD" ]; then
        echo "${GREEN}Configuring ${NAME}...${NC}"
        ./configure --prefix="$PREFIX" --host="$CHOST" $@
    fi
    echo "${GREEN}Building ${NAME}...${NC}"
    make -j$NCPU
}
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS
'''
        once = patch_utm_qemu_ios.patch_script(source)
        twice = patch_utm_qemu_ios.patch_script(once)
        self.assertEqual(once, twice)
        self.assertIn("--target-list=x86_64-softmmu", twice)
        self.assertIn('python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"', twice)
        self.assertIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"', twice)
        self.assertNotIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$DIR/build/build.ninja"', twice)
        self.assertIn("http://ftp.gnu.org/gnu/libiconv/*", twice)
        self.assertIn("https://ftp.gnu.org/pub/gnu/libiconv/${URL##*/}", twice)
        shell_check = subprocess.run(["bash", "-n"], input=twice, text=True, capture_output=True)
        self.assertEqual(shell_check.returncode, 0, shell_check.stderr)

    def test_qemu_workflow_installs_both_spirv_dependencies(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("spirv-tools", source)
        self.assertIn("spirv-llvm-translator", source)

    def test_link_verifier_requires_runtime_on_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-force_load,/toolchain/libclang_rt.ios.a
build unrelated.dylib: c_LINKER other
  LINK_ARGS = -lm
'''
        verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")

    def test_link_verifier_rejects_runtime_missing_from_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -lm
'''
        with self.assertRaisesRegex(SystemExit, "emulator-specific link arguments"):
            verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")


if __name__ == "__main__":
    unittest.main()
