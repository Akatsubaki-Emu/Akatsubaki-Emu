#!/usr/bin/env python3
import subprocess
import sys
import unittest
from tempfile import TemporaryDirectory
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
QEMU_SYMBOLS = """{
  qemu_init;
  qemu_main_loop;
  qemu_cleanup;
  bql_lock_impl;
  bql_unlock;
  g_assertion_message_expr;
  qemu_thread_create;
  replay_mutex_lock;
  replay_mutex_unlock;
};
"""
QEMU_EXPORTS = """_qemu_init
_qemu_main_loop
_qemu_cleanup
_qemu_system_shutdown_request
_isteam_qemu_set_jit_callbacks
"""
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
    echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross
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
        self.assertIn('echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross', twice)
        without_objc_args = source.replace('    echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross\\n', "")
        with self.assertRaisesRegex(SystemExit, "Objective-C flags are not propagated to Meson"):
            patch_utm_qemu_ios.patch_script(without_objc_args)
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
        self.assertIn("#include <mach/mach_vm.h>", once)
        self.assertIn('dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")', once)
        self.assertIn("ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN = -1", once)
        self.assertIn("ISTEAM_QEMU_JIT_PROTOCOL_STANDARD = 0", once)
        self.assertIn("ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG = 1", once)
        self.assertIn("ISTEAMJITProtocolModeFunction", once)
        self.assertIn("jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN", once)
        self.assertIn("jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG", once)
        self.assertIn("jit_protocol_mode != ISTEAM_QEMU_JIT_PROTOCOL_STANDARD", once)
        self.assertNotIn("jit_protocol_mode < 0", once)
        self.assertNotIn("jit_protocol_mode > 0", once)
        self.assertNotIn(r"\n", once)
        self.assertNotIn(r'\"', once)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "iSteamJITIsReady")', once)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion")', once)
        self.assertNotIn('dlsym(RTLD_DEFAULT, "iSteamJITDetach")', once)
        self.assertIn('__attribute__((visibility("default")))', once)
        self.assertIn("void isteam_qemu_set_jit_callbacks(", once)
        self.assertIn("void isteam_qemu_set_jit_callbacks(ISTEAMJITReadyFunction ready,", once)
        self.assertIn("isteam_jit_ready_callback = ready", once)
        self.assertIn("ISTEAMJITPrepareFunction prepare_region = isteam_jit_prepare_callback", once)
        self.assertIn("__builtin_available(iOS 26.0, *)", once)
        bridge = (Path(__file__).resolve().parents[2] / "iSteam/QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertIn(
            "set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);",
            bridge,
        )
        self.assertIn(
            "typedef void (*qemu_set_jit_callbacks_fn)(bool (*)(void), void *(*)(void *, size_t), void (*)(void));",
            bridge,
        )
        with self.assertRaisesRegex(SystemExit, "unexpected legacy protocol check"):
            patch_qemu_stikjit_ios.patch_source(
                once + '\\nvoid *invalid_callback = dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion");'
            )
        self.assertIn("mach_vm_remap(mach_task_self(), &buf_rw", once)
        self.assertIn("mach_vm_protect(mach_task_self(), buf_rw", once)
        with self.assertRaisesRegex(SystemExit, r"split-W\^X Darwin allocator not found"):
            patch_qemu_stikjit_ios.patch_source("#ifdef CONFIG_DARWIN\n#include <mach/mach.h>\n#endif\n")

    def test_qemu_export_list_patch_is_idempotent_and_fails_closed(self):
        once = patch_qemu_stikjit_ios.patch_export_symbols(QEMU_SYMBOLS)
        twice = patch_qemu_stikjit_ios.patch_export_symbols(once)
        self.assertEqual(once, twice)
        self.assertEqual(once.count("qemu_system_shutdown_request;"), 1)
        self.assertEqual(once.count("isteam_qemu_set_jit_callbacks;"), 1)
        self.assertIn("qemu_init;", once)
        self.assertIn("qemu_main_loop;", once)
        self.assertIn("qemu_cleanup;", once)
        export_lines = once.splitlines()
        closing_index = export_lines.index("};")
        for symbol in ("qemu_system_shutdown_request;", "isteam_qemu_set_jit_callbacks;"):
            positions = [index for index, line in enumerate(export_lines) if line.strip() == symbol]
            self.assertEqual(len(positions), 1)
            self.assertLess(positions[0], closing_index)
        with self.assertRaisesRegex(SystemExit, "missing expected anchors"):
            patch_qemu_stikjit_ios.patch_export_symbols("qemu_init;\n")
        with self.assertRaisesRegex(SystemExit, "outside the braced symbol block"):
            patch_qemu_stikjit_ios.patch_export_symbols(
                QEMU_SYMBOLS + "  qemu_system_shutdown_request;\n"
            )
        with self.assertRaisesRegex(SystemExit, "duplicate required exports"):
            patch_qemu_stikjit_ios.patch_export_symbols(
                QEMU_SYMBOLS + "  qemu_system_shutdown_request;\n  qemu_system_shutdown_request;\n"
            )

    def test_qemu_patch_file_updates_region_and_export_list_together(self):
        region_source = """#ifdef CONFIG_DARWIN
#include <mach/mach.h>
static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)
{
    return 0;
}
#endif
"""
        with TemporaryDirectory() as temporary_directory:
            qemu_root = Path(temporary_directory)
            (qemu_root / "tcg").mkdir()
            (qemu_root / "system").mkdir()
            region_path = qemu_root / "tcg" / "region.c"
            symbols_path = qemu_root / "system" / "qemu.symbols"
            region_path.write_text(region_source, encoding="utf-8")
            symbols_path.write_text(QEMU_SYMBOLS, encoding="utf-8")

            patch_qemu_stikjit_ios.patch_file(region_path)
            patched_region = region_path.read_text(encoding="utf-8")
            patched_symbols = symbols_path.read_text(encoding="utf-8")
            self.assertIn("iSteamJITGetProtocolMode", patched_region)
            self.assertIn("jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN", patched_region)
            self.assertIn("qemu_system_shutdown_request;", patched_symbols)
            self.assertIn("isteam_qemu_set_jit_callbacks;", patched_symbols)

            patch_qemu_stikjit_ios.patch_file(region_path)
            self.assertEqual(
                symbols_path.read_text(encoding="utf-8").count("isteam_qemu_set_jit_callbacks;"),
                1,
            )

    def test_ios_targets_link_iokit_and_export_tristate_jit_protocol(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "project.yml").read_text(encoding="utf-8")
        stable = project.split("  iSteam:", 1)[1].split("  iSteamNightly:", 1)[0]
        nightly = project.split("  iSteamNightly:", 1)[1].split("  iSteamVision:", 1)[0]
        for name, target in (("stable", stable), ("nightly", nightly)):
            with self.subTest(target=name):
                self.assertIn("- sdk: IOKit.framework", target)
                self.assertIn("-Wl,-exported_symbol,_iSteamJITGetProtocolMode", target)

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

    def test_qemu_workflow_disables_unsupported_objc_class_selector_stubs(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("Verify Objective-C class-selector stub compatibility", source)
        self.assertIn("-fno-objc-msgsend-class-selector-stubs", source)
        self.assertIn("export OBJCFLAGS=", source)
        self.assertIn("grep -Fq", source)
        self.assertNotIn("\n; then\n", source)
        self.assertIn('SYMBOLS="$(xcrun --sdk iphoneos nm -u "$PROBE_OBJECT")"', source)
        self.assertIn("if grep -Fq '_objc_msgSendClass' <<< \"$SYMBOLS\"; then", source)

    def test_link_verifier_requires_runtime_and_exports_on_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a -Wl,-exported_symbols_list,system/qemu-ld64.symbols
build unrelated.dylib: c_LINKER other
  LINK_ARGS = -lm
'''
        verify_qemu_meson_link.verify_link(
            ninja, "/toolchain/libclang_rt.ios.a", QEMU_EXPORTS
        )

    def test_link_verifier_rejects_runtime_missing_from_qemu_target_edge(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -lm -Wl,-exported_symbols_list,system/qemu-ld64.symbols
'''
        with self.assertRaisesRegex(SystemExit, "emulator-specific link arguments"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", QEMU_EXPORTS
            )

    def test_link_verifier_rejects_missing_objc_stub_generation(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a -Wl,-exported_symbols_list,system/qemu-ld64.symbols
'''
        with self.assertRaisesRegex(SystemExit, "Objective-C message-stub generation"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", QEMU_EXPORTS
            )

    def test_link_verifier_rejects_missing_libobjc(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -Wl,-force_load,/toolchain/libclang_rt.ios.a -Wl,-exported_symbols_list,system/qemu-ld64.symbols
'''
        with self.assertRaisesRegex(SystemExit, "Objective-C runtime"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", QEMU_EXPORTS
            )

    def test_link_verifier_rejects_missing_export_list_link_argument(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a
'''
        with self.assertRaisesRegex(SystemExit, "generated exported-symbol list"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", QEMU_EXPORTS
            )

    def test_link_verifier_rejects_missing_required_bridge_export(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a -Wl,-exported_symbols_list,system/qemu-ld64.symbols
'''
        exports_without_setter = QEMU_EXPORTS.replace(
            "_isteam_qemu_set_jit_callbacks\n", ""
        )
        with self.assertRaisesRegex(SystemExit, "required bridge exports"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", exports_without_setter
            )

    def test_link_verifier_rejects_missing_lifecycle_export(self):
        ninja = '''build libqemu-x86_64-softmmu.dylib: c_LINKER objects
  LINK_ARGS = -Wl,-objc_stubs_fast -lobjc -Wl,-force_load,/toolchain/libclang_rt.ios.a -Wl,-exported_symbols_list,system/qemu-ld64.symbols
'''
        exports_without_cleanup = QEMU_EXPORTS.replace("_qemu_cleanup\n", "")
        with self.assertRaisesRegex(SystemExit, "required bridge exports"):
            verify_qemu_meson_link.verify_link(
                ninja, "/toolchain/libclang_rt.ios.a", exports_without_cleanup
            )


if __name__ == "__main__":
    unittest.main()
