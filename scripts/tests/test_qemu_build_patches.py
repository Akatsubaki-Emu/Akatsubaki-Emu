#!/usr/bin/env python3
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_qemu_meson_ios
import patch_qemu_stikjit_ios
import patch_utm_qemu_ios
import verify_qemu_meson_link


class QEMUBuildPatchTests(unittest.TestCase):
    def test_qemu_meson_patch_is_idempotent_and_targets_emulator_link_args(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', "
            "cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
            "emulator_link_args += ['-Wl,-force_load,libqemuutil.a']\n"
            "link_args = emulator_link_args\n"
        )
        runtime = "/toolchain/libclang_rt.ios.a"
        once = patch_qemu_meson_ios.patch_source(source, runtime)
        twice = patch_qemu_meson_ios.patch_source(once, runtime)
        self.assertEqual(once, twice)
        self.assertIn("config_host_data.set('CONFIG_POSIX_MEMALIGN', true)", twice)
        self.assertIn("emulator_link_args += ['-Wl,-objc_stubs_fast', '-lobjc', '-Wl,-force_load," + runtime + "']", twice)
        self.assertLess(twice.index("emulator_link_args = []"), twice.index("emulator_link_args +="))
        self.assertIn("link_args = emulator_link_args", twice)
        self.assertIn("emulator_link_args += ['-Wl,-force_load,libqemuutil.a']", twice)
        self.assertEqual(twice.count("emulator_link_args += "), 2)
        self.assertNotIn("add_project_link_arguments", twice)

    def test_qemu_meson_patch_replaces_a_stale_runtime_path(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
            "emulator_link_args += ['-Wl,-force_load,libqemuutil.a']\n"
        )
        first = patch_qemu_meson_ios.patch_source(source, "/old/libclang_rt.ios.a")
        legacy = first.replace(
            patch_qemu_meson_ios.MARKER_COMMENT,
            patch_qemu_meson_ios.LEGACY_MARKER_COMMENT
        )
        updated = patch_qemu_meson_ios.patch_source(legacy, "/new/libclang_rt.ios.a")
        self.assertNotIn(patch_qemu_meson_ios.LEGACY_MARKER_COMMENT, updated)
        self.assertNotIn("/old/libclang_rt.ios.a", updated)
        self.assertIn("-Wl,-force_load,/new/libclang_rt.ios.a", updated)
        self.assertIn("-Wl,-objc_stubs_fast", updated)
        self.assertIn("'-lobjc'", updated)
        self.assertIn("emulator_link_args += ['-Wl,-force_load,libqemuutil.a']", updated)
        self.assertEqual(updated.count("emulator_link_args += "), 2)

    def test_qemu_meson_patch_fails_if_owned_marker_is_detached(self):
        source = (
            "project('qemu', 'c')\n"
            "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))\n"
            "emulator_link_args = []\n"
        )
        patched = patch_qemu_meson_ios.patch_source(source, "/toolchain/libclang_rt.ios.a")
        detached = patched.replace(
            patch_qemu_meson_ios.MARKER_COMMENT + "\nemulator_link_args +=",
            patch_qemu_meson_ios.MARKER_COMMENT + "\n# upstream edit\nemulator_link_args +=",
            1
        )
        with self.assertRaisesRegex(SystemExit, "marker is not followed by its link argument"):
            patch_qemu_meson_ios.patch_source(detached, "/toolchain/libclang_rt.ios.a")

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
        self.assertIn('python3 "$ISTEAM_QEMU_JIT_PATCHER" "$QEMU_DIR/tcg/region.c"', twice)
        self.assertLess(twice.index("ISTEAM_QEMU_JIT_PATCHER"), twice.index("ISTEAM_QEMU_MESON_PATCHER"))
        self.assertIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"', twice)
        self.assertNotIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$DIR/build/build.ninja"', twice)
        self.assertIn("http://ftp.gnu.org/gnu/libiconv/*", twice)
        self.assertIn("https://ftp.gnu.org/pub/gnu/libiconv/${URL##*/}", twice)
        shell_check = subprocess.run(["bash", "-n"], input=twice, text=True, capture_output=True)
        self.assertEqual(shell_check.returncode, 0, shell_check.stderr)

    def test_fresh_launch_defaults_to_ubuntu(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src/Core/RuntimeSettings.swift").read_text(encoding="utf-8")
        launch = (root / "iSteam/LaunchSetupViewController.swift").read_text(encoding="utf-8")
        self.assertIn("?? .linuxVM", settings)
        self.assertIn('string(forKey: "iSteam.lastGuest") ?? "Ubuntu"', launch)
        self.assertIn("case .linuxVM:", launch)

    def test_qemu_tcg_profiles_both_request_split_wx(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src/QEMU/QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        self.assertIn('"tcg,tb-size=128,split-wx=on"', source)
        self.assertIn('"tcg,tb-size=64,split-wx=on"', source)

    def test_qemu_runtime_rejects_tcg_when_stikdebug_jit_is_not_ready(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src/QEMU/QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("JITCoordinator.shared.isStikDebugAvailable", source)
        self.assertIn("!JITCoordinator.shared.isJITReady", source)
        self.assertIn("Enable JIT for Akatsubaki Emu with StikDebug", source)


    def test_launch_setup_uses_jit_callbacks_before_presenting_vm(self):
        root = Path(__file__).resolve().parents[2]
        launch = (root / "iSteam/LaunchSetupViewController.swift").read_text(encoding="utf-8")
        native = (root / "src/QEMU/QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        launch_method = launch.split("@objc private func launchSession()", 1)[1].split("@objc private func chooseGuestImage()", 1)[0]
        complete_method = launch.split("private func completeLaunch", 1)[1].split("@objc private func chooseGuestImage()", 1)[0]
        self.assertIn("guard !launchInProgress", launch_method)
        self.assertIn("JITCoordinator.shared.requestJIT(from: self, onFailure:", launch_method)
        self.assertIn("let writableDiskURL = selectedWritableDiskURL", launch_method)
        self.assertIn("self?.completeLaunch(configuration: config, diskURL: diskURL, writableDiskURL: writableDiskURL)", launch_method)
        self.assertIn("completeLaunch(configuration: config, diskURL: diskURL, writableDiskURL: writableDiskURL)", launch_method)
        self.assertLess(launch_method.index("JITCoordinator.shared.requestJIT"), launch_method.index("completeLaunch"))
        self.assertIn("self.launchInProgress = false", launch_method)
        self.assertNotIn("waitForJIT", launch)
        self.assertIn("VMDisplayViewController(configuration: configuration", complete_method)
        self.assertIn("!JITCoordinator.shared.isJITReady", native)

    def test_qemu_stikjit_allocator_patch_is_idempotent_and_fails_closed(self):
        source = """#ifdef CONFIG_DARWIN
#include <mach/mach.h>
static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)
{
    return 0;
}
#endif
"""
        once = patch_qemu_stikjit_ios.patch_source(source)
        twice = patch_qemu_stikjit_ios.patch_source(once)
        self.assertEqual(once, twice)
        self.assertIn("iSteamJITIsReady", once)
        self.assertIn("iSteamJITPrepareRegion", once)
        self.assertIn("iSteamJITDetach", once)
        self.assertIn('__attribute__((visibility("default")))', once)
        self.assertIn("void isteam_qemu_set_jit_callbacks(", once)
        self.assertIn("void isteam_qemu_set_jit_callbacks(ISTEAMJITReadyFunction ready,", once)
        self.assertIn("isteam_jit_ready_callback = ready", once)
        self.assertIn("ISTEAMJITPrepareFunction prepare_region = isteam_jit_prepare_callback", once)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion")', once)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "iSteamJITIsReady")', once)
        self.assertIn("__builtin_available(iOS 26.0, *)", once)
        self.assertIn("mach_vm_remap(mach_task_self(), &buf_rw", once)
        self.assertIn("mach_vm_protect(mach_task_self(), buf_rw", once)
        with self.assertRaisesRegex(SystemExit, r"split-W\^X Darwin allocator not found"):
            patch_qemu_stikjit_ios.patch_source("#ifdef CONFIG_DARWIN\n#include <mach/mach.h>\n#endif\n")

    def test_windows_and_steamos_profiles_select_uefi_firmware(self):
        root = Path(__file__).resolve().parents[2]
        configuration = (root / "src/Core/VMConfiguration.swift").read_text(encoding="utf-8")
        runtime = (root / "src/QEMU/QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("var bootUEFI: Bool? = nil", configuration)
        self.assertIn("var requiresUEFI: Bool", configuration)
        self.assertIn("bootWindows: true, bootUEFI: true", configuration)
        self.assertIn("bootWindows: false, bootUEFI: false", configuration)
        self.assertIn("bootWindows: false, bootUEFI: true", configuration)
        self.assertIn("configuration.requiresUEFI", runtime)

    def test_qemu_runtime_does_not_cancel_in_progress_release_build(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("cancel-in-progress: false", source)

    def test_qemu_workflow_installs_both_spirv_dependencies(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("spirv-tools", source)
        self.assertIn("spirv-llvm-translator", source)

    def test_link_verifier_requires_runtime_on_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a
build unrelated.dylib: c_LINKER other
  LINK_ARGS = -lm
'''
        verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")

    def test_link_verifier_rejects_runtime_missing_from_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -lm
'''
        with self.assertRaisesRegex(SystemExit, "emulator-specific link arguments"):
            verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")

    def test_link_verifier_rejects_missing_objc_stub_generation(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a
'''
        with self.assertRaisesRegex(SystemExit, "Objective-C message-stub generation"):
            verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")

    def test_link_verifier_rejects_missing_libobjc(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -Wl,-force_load,/toolchain/libclang_rt.ios.a
'''
        with self.assertRaisesRegex(SystemExit, "Objective-C runtime"):
            verify_qemu_meson_link.verify_link(ninja, "/toolchain/libclang_rt.ios.a")


if __name__ == "__main__":
    unittest.main()
