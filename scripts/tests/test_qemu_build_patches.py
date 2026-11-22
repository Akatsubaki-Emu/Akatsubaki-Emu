#!/usr/bin/env python3
import subprocess
import sys
import unittest
import textwrap
from pathlib import Path
from tempfile import TemporaryDirectory

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
        self.assertIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"', twice)
        self.assertNotIn('python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$DIR/build/build.ninja"', twice)
        self.assertIn("http://ftp.gnu.org/gnu/libiconv/*", twice)
        self.assertIn("https://ftp.gnu.org/pub/gnu/libiconv/${URL##*/}", twice)
        self.assertIn('echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross', twice)
        without_objc_args = source.replace('    echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross\n', "")
        with self.assertRaisesRegex(SystemExit, "Objective-C flags are not propagated to Meson"):
            patch_utm_qemu_ios.patch_script(without_objc_args)
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
        self.assertNotIn(r'\\n', once)
        self.assertNotIn(r'\\\"', once)
        self.assertIn("#include <mach/mach_vm.h>", once)
        self.assertIn('dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")', once)
        self.assertIn("jit_protocol_mode < 0", once)
        self.assertIn("jit_protocol_mode > 0", once)
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
        with self.assertRaisesRegex(SystemExit, "unexpected host-symbol lookup"):
            patch_qemu_stikjit_ios.patch_source(
                once + '\\nvoid *invalid_callback = dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion");'
            )
        self.assertIn("mach_vm_remap(mach_task_self(), &buf_rw", once)
        self.assertIn("mach_vm_protect(mach_task_self(), buf_rw", once)
        with self.assertRaisesRegex(SystemExit, r"split-W\^X Darwin allocator not found"):
            patch_qemu_stikjit_ios.patch_source("#ifdef CONFIG_DARWIN\n#include <mach/mach.h>\n#endif\n")

    def test_qemu_stikjit_patcher_exports_required_runtime_symbols(self):
        symbols = """{
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
        once = patch_qemu_stikjit_ios.patch_exported_symbols(symbols)
        self.assertEqual(once, patch_qemu_stikjit_ios.patch_exported_symbols(once))
        generated = [
            "_" + line.strip()[:-1]
            for line in once.splitlines()
            if line.strip().endswith(";")
        ]
        self.assertIn("_qemu_system_shutdown_request", generated)
        self.assertIn("_isteam_qemu_set_jit_callbacks", generated)
        self.assertEqual(once.count("qemu_system_shutdown_request;"), 1)
        self.assertEqual(once.count("isteam_qemu_set_jit_callbacks;"), 1)
        with self.assertRaisesRegex(SystemExit, "expected exactly one closing"):
            patch_qemu_stikjit_ios.patch_exported_symbols("{\n  qemu_init;\n  qemu_main_loop;\n  qemu_cleanup;\n")


    def test_qemu_stikjit_patcher_updates_region_and_export_list_together(self):
        with TemporaryDirectory() as temporary:
            qemu_root = Path(temporary)
            region = qemu_root / "tcg" / "region.c"
            symbols = qemu_root / "system" / "qemu.symbols"
            region.parent.mkdir()
            symbols.parent.mkdir()
            region.write_text(
                "#ifdef CONFIG_DARWIN\n#include <mach/mach.h>\n"
                "static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)\n"
                "{\n    return 0;\n}\n#endif\n",
                encoding="utf-8",
            )
            symbols.write_text(
                "{\n  qemu_init;\n  qemu_main_loop;\n  qemu_cleanup;\n};\n",
                encoding="utf-8",
            )
            patch_qemu_stikjit_ios.patch_qemu_sources(region)
            first_region = region.read_text(encoding="utf-8")
            first_symbols = symbols.read_text(encoding="utf-8")
            self.assertIn("isteam_qemu_set_jit_callbacks", first_region)
            self.assertIn("qemu_system_shutdown_request;", first_symbols)
            self.assertIn("isteam_qemu_set_jit_callbacks;", first_symbols)
            patch_qemu_stikjit_ios.patch_qemu_sources(region)
            self.assertEqual(region.read_text(encoding="utf-8"), first_region)
            self.assertEqual(symbols.read_text(encoding="utf-8"), first_symbols)


    def test_qemu_workflow_probe_shell_syntax_and_steps_are_unique(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        probe = source.split("      - name: Verify Objective-C class-selector stub compatibility", 1)[1]
        probe = probe.split("      - name: Install UTM build dependencies", 1)[0]
        script = textwrap.dedent(probe.split("        run: |\n", 1)[1])
        result = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (
            "Verify Objective-C class-selector stub compatibility",
            "Install UTM build dependencies",
            "Cache UTM dependency build and sysroot",
            "Build UTM dependencies for physical iOS arm64",
            "Build UTM iOS archive",
            "Package and verify in-process QEMU runtime",
            "Upload verified QEMU runtime artifact",
        ):
            self.assertEqual(source.count("      - name: " + name), 1)


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

    def test_qemu_workflow_uses_supported_xcode_for_objc_class_selector_stubs(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-qemu-runtime.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("Verify Objective-C class-selector stub compatibility", source)
        self.assertIn("runs-on: xcode-27", source)
        self.assertIn('XCODE_APP="/Applications/Xcode_27.2.app"', source)
        self.assertIn('if [ "$XCODE_VERSION" != "27.2" ]; then', source)
        self.assertIn("utm-ios-arm64-deps-v14-", source)
        self.assertIn("PROBE_BINARY=", source)
        self.assertIn("-Wl,-objc_stubs_fast", source)
        self.assertIn("-lobjc -framework Metal", source)
        self.assertIn("-fno-objc-msgsend-class-selector-stubs", source)
        self.assertIn("export OBJCFLAGS=", source)
        self.assertIn("grep -Fq", source)
        self.assertIn('SYMBOLS="$(xcrun --sdk iphoneos nm -u "$PROBE_OBJECT")"', source)
        self.assertIn('if grep -Fq \'_objc_msgSendClass\' <<<"$SYMBOLS"; then', source)
        self.assertNotIn('nm -u "$PROBE_OBJECT" | grep', source)
        self.assertNotIn("\n; then\n", source)

    def test_release_tag_is_created_from_the_workflow_commit(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("tag_name: ${{ steps.meta.outputs.tag }}", source)
        self.assertIn("target_commitish: ${{ github.sha }}", source)


    def test_main_release_dispatch_is_limited_to_main_branch(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        source = workflow.read_text(encoding="utf-8")
        self.assertIn("validate-release-channel:", source)
        self.assertIn("needs: validate-release-channel", source)
        self.assertIn("inputs.channel == 'Main'", source)
        self.assertIn("github.ref != 'refs/heads/main'", source)
        self.assertIn("The Main release channel can only be dispatched from refs/heads/main", source)


    def test_visionos_release_channel_uses_distinct_bundle_identifiers(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        source = workflow.read_text(encoding="utf-8")
        step = source.split("- name: Build and package visionOS app", 1)[1].split("- name: Upload build artifact", 1)[0]
        self.assertIn('if [ "$RELEASE_CHANNEL" = "main" ]; then', step)
        self.assertIn('EXPECTED_BUNDLE="com.xthrx.isteam.visionos"', step)
        self.assertIn('EXPECTED_BUNDLE="com.xthrx.isteam.visionos.nightly"', step)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER="$EXPECTED_BUNDLE"', step)
        self.assertIn('grep -Fx "$EXPECTED_BUNDLE"', step)
        self.assertIn('bash scripts/validate-apple-package.sh build/iSteam-visionOS.ipa iSteamVision.app "$EXPECTED_BUNDLE"', step)


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
