#!/usr/bin/env python3
"""Prevent silent duplicate keys and lifecycle/source-contract regressions."""
import ast
import subprocess
import unittest
from pathlib import Path


class SourceValidatorTests(unittest.TestCase):
    def test_required_source_contracts_have_no_duplicate_dictionary_keys(self):
        source = Path(__file__).resolve().parents[1] / "validate-qemu-source.py"
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
        assignment = next(
            (
                node for node in ast.walk(tree)
                if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == "required"
                        for target in node.targets)
            ),
            None,
        )
        self.assertIsNotNone(assignment, "required source-contract dictionary was not found")
        self.assertIsInstance(assignment.value, ast.Dict)
        keys = [
            key.value for key in assignment.value.keys
            if isinstance(key, ast.Constant) and isinstance(key.value, str)
        ]
        duplicates = sorted({key for key in keys if keys.count(key) > 1})
        self.assertFalse(duplicates, f"duplicate required source-contract keys: {duplicates}")

        for key, value in zip(assignment.value.keys, assignment.value.values):
            if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                continue
            if not isinstance(value, ast.List):
                continue
            tokens = [
                item.value for item in value.elts
                if isinstance(item, ast.Constant) and isinstance(item.value, str)
            ]
            duplicate_tokens = sorted({token for token in tokens if tokens.count(token) > 1})
            self.assertFalse(
                duplicate_tokens,
                f"duplicate source-contract tokens for {key.value}: {duplicate_tokens}",
            )

    def test_guest_machine_has_one_serialized_stop_entry_point(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("func stop()"), 1)
        self.assertIn("requestActiveStop()", source)
        self.assertIn("memory.clear()", source)

    def test_pause_request_cannot_miss_the_cpu_activation_window(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        activation = source.split("private func setActiveCPU", 1)[1].split("private func clearPendingStopRequest", 1)[0]
        interruption = source.split("private func requestActiveStop", 1)[1].split("init(configuration:", 1)[0]
        pause = source.split("func pause()", 1)[1].split("func stop()", 1)[0]
        stop = source.split("func stop()", 1)[1].split("func resume()", 1)[0]
        self.assertIn("pendingStopRequested", activation)
        self.assertIn("if shouldStop { backend?.requestStop() }", activation)
        self.assertIn("if backend == nil { pendingStopRequested = true }", interruption)
        self.assertIn("clearPendingStopRequest()", pause)
        self.assertIn("clearPendingStopRequest()", stop)

    def test_release_ipa_requires_all_five_qemu_exports(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        ios_package = workflow.split("- name: Build and package iOS IPA", 1)[1].split(
            "- name: Build and package tvOS IPA", 1
        )[0]
        for symbol in (
            "qemu_init",
            "qemu_main_loop",
            "qemu_cleanup",
            "qemu_system_shutdown_request",
            "isteam_qemu_set_jit_callbacks",
        ):
            with self.subTest(symbol=symbol):
                self.assertIn(f"grep -Eq ' _?{symbol}$'", ios_package)

    def test_qemu_packager_has_one_complete_candidate_scan(self):
        root = Path(__file__).resolve().parents[2]
        package = (root / "scripts" / "package-utm-qemu-runtime.sh").read_text(encoding="utf-8")
        runtime_validator = (root / "scripts" / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")

        self.assertEqual(package.count('candidate=""'), 1)
        self.assertEqual(package.count('candidate="$file"'), 1)
        self.assertIn("qemu_system_shutdown_request", package)
        self.assertIn("isteam_qemu_set_jit_callbacks", package)
        self.assertIn("dynamically linked shared library", package)
        self.assertLess(package.index("dynamically linked shared library"), package.index("candidate_exports="))
        self.assertIn("dynamically linked shared library", runtime_validator)
        self.assertIn("vtool -show-build", package)
        self.assertIn("platform[[:space:]]+IOS([[:space:]]|$)", package)
        self.assertIn("vtool -show-build", runtime_validator)
        self.assertIn("platform[[:space:]]+IOS([[:space:]]|$)", runtime_validator)
        self.assertIn("runtime-library-path.txt", package)
        self.assertIn("qemu_system_shutdown_request", runtime_validator)
        self.assertIn("isteam_qemu_set_jit_callbacks", runtime_validator)
        self.assertIn('dlsym(library, "isteam_qemu_set_jit_callbacks")', bridge)
        self.assertNotIn("duplicate_string", bridge)

    def test_runtime_validator_has_one_complete_tool_and_export_scan(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "scripts" / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        self.assertEqual(source.count("for tool in file lipo nm codesign vtool; do"), 1)
        self.assertEqual(
            source.count("for symbol in qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request isteam_qemu_set_jit_callbacks; do"),
            1,
        )
        self.assertEqual(source.count("codesign --verify --strict"), 1)
        self.assertNotIn("optional graceful-shutdown export", source)
        self.assertNotIn("for tool in file lipo nm codesign; do", source)

    def test_native_runtime_probes_loadability_before_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("switch QEMURuntimeStatus.inspect()", source)
        self.assertNotIn("switch QEMURuntimeStatus.locate()", source)

    def test_repository_validation_checks_runtime_validator_shell_syntax(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-repository.yml").read_text(encoding="utf-8")
        self.assertIn("bash -n scripts/package-utm-qemu-runtime.sh", workflow)
        self.assertIn("bash -n scripts/validate-qemu-runtime.sh", workflow)
        self.assertIn("bash -n scripts/validate-apple-package.sh", workflow)
        for script in (
            "scripts/package-utm-qemu-runtime.sh",
            "scripts/validate-qemu-runtime.sh",
            "scripts/validate-apple-package.sh",
        ):
            result = subprocess.run(
                ["bash", "-n", str(root / script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, f"{script}: {result.stderr}")

    def test_qemu_runtime_documentation_has_one_consistent_required_export_contract(self):
        root = Path(__file__).resolve().parents[2]
        readme = (root / "runtime" / "qemu" / "README.md").read_text(encoding="utf-8")
        for symbol in (
            "qemu_init",
            "qemu_main_loop",
            "qemu_cleanup",
            "qemu_system_shutdown_request",
            "isteam_qemu_set_jit_callbacks",
        ):
            self.assertIn(f"`{symbol}`", readme)
        self.assertNotIn("qemu_system_shutdown_request` is optional", readme)
        self.assertEqual(readme.count("The runtime library must be built for **physical iOS arm64**"), 1)
        self.assertEqual(readme.count("Physical-device runtime startup"), 1)

    def test_qemu_ios_platform_guard_rejects_simulator_platforms(self):
        pattern = "platform[[:space:]]+IOS([[:space:]]|$)"
        device = subprocess.run(
            ["grep", "-Eq", pattern],
            input="platform IOS\n",
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(device.returncode, 0)
        for platform in ("IOSSIMULATOR", "IOS_SIMULATOR", "MACOS", "MACCATALYST"):
            result = subprocess.run(
                ["grep", "-Eq", pattern],
                input=f"platform {platform}\n",
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1, platform)

    def test_native_bridge_enables_strict_c11_strnlen_and_covers_cleanup_race(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        test = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn("#define _POSIX_C_SOURCE 200809L", bridge)
        self.assertIn("g_running = false;", bridge)
        self.assertLess(
            bridge.index("g_qemu_main_loop();"),
            bridge.index("g_running = false;", bridge.index("g_qemu_main_loop();")),
        )
        self.assertLess(
            bridge.index("g_running = false;", bridge.index("g_qemu_main_loop();")),
            bridge.index("if (g_qemu_cleanup) g_qemu_cleanup();"),
        )
        self.assertIn("#include <stdlib.h>", test)
        self.assertIn("fake_qemu_cleanup_started_count", test)
        self.assertIn("fake_qemu_shutdown_count", test)

    def test_host_shared_file_import_and_read_enforce_the_transfer_limit(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "HostDeviceBridge.swift").read_text(encoding="utf-8")
        receive = source.split("func receiveFile", 1)[1].split("func readSharedFile", 1)[0]
        read = source.split("func readSharedFile", 1)[1].split("func writeSharedFile", 1)[0]
        self.assertIn("sourceSize <= maximumInMemoryTransferBytes", receive)
        self.assertIn("maximumCopyBytes = maximumInMemoryTransferBytes + 1", receive)
        self.assertIn("input.read(upToCount:", receive)
        self.assertIn("output?.write(contentsOf:", receive)
        self.assertIn("copiedSize == copiedBytes", receive)
        self.assertIn("copiedBytes == sourceSize", receive)
        self.assertNotIn("copyItem(at:", receive)
        self.assertIn("maximumInMemoryTransferBytes + 1", read)
        self.assertIn("handle.read(upToCount:", read)
        self.assertIn("data.count == size", read)

    def test_external_drive_copy_rejects_directories_before_copying(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "ExternalDriveStore.swift").read_text(encoding="utf-8")
        copy = source.split("func copyDocument", 1)[1]
        self.assertIn("resourceValues(forKeys: [.isRegularFileKey])", copy)
        self.assertIn("guard values.isRegularFile == true", copy)
        self.assertLess(copy.index("guard values.isRegularFile == true"), copy.index("copyItem(at:"))

    def test_translation_cache_pruning_keeps_newest_entry_last_on_timestamp_ties(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Performance" / "TranslationCache.swift").read_text(encoding="utf-8")
        ordering = source.split("entries.sort", 1)[1].split("while entries.count", 1)[0]
        self.assertIn("if $0.url == newestFile { return false }", ordering)
        self.assertIn("if $1.url == newestFile { return true }", ordering)
        self.assertIn("$0.url.lastPathComponent < $1.url.lastPathComponent", ordering)


    def test_emulation_log_byte_bound_is_scoped_to_the_correct_source_contract(self):
        root = Path(__file__).resolve().parents[2]
        validator = (root / "scripts" / "validate-qemu-source.py").read_text(encoding="utf-8")
        crash_start = validator.index('"iSteam/CrashLogger.swift": [')
        crash_end = validator.index("],", crash_start)
        emulation_start = validator.index('"src/Core/EmulationLog.swift": [')
        emulation_end = validator.index("],", emulation_start)
        crash_contract = validator[crash_start:crash_end]
        emulation_contract = validator[emulation_start:emulation_end]
        self.assertNotIn("String(decoding: message.utf8.prefix(8192)", crash_contract)
        self.assertIn("String(decoding: message.utf8.prefix(8192)", emulation_contract)
        self.assertIn("currentLogBytes <= maximumLogBytes - byteCount", emulation_contract)


    def test_qemu_stop_uses_atomic_main_loop_lifecycle_gate(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        self.assertIn("#include <stdatomic.h>", source)
        self.assertIn("static atomic_bool g_main_loop_active", source)
        self.assertIn("atomic_store(&g_main_loop_active, true)", source)
        self.assertIn("atomic_store(&g_main_loop_active, false)", source)
        self.assertIn("atomic_load(&g_main_loop_active)", source)


    def test_profile_directory_enumeration_failure_blocks_incomplete_export(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Steam" / "GameRuntimeProfile.swift").read_text(encoding="utf-8")
        self.assertIn("private func profileFiles() throws -> [URL]", source)
        self.assertIn("guard let files = try? profileFiles() else { return true }", source)
        self.assertIn("refusing to export an incomplete library backup", source)


    def test_controller_button_release_uses_the_press_time_mapping(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "ControllerInputManager.swift").read_text(encoding="utf-8")
        self.assertIn("private func mappedAction(for name: String, source: String, pressed: Bool,", source)
        self.assertIn("profile: ControllerMappingProfile) -> String {", source)
        self.assertIn("activeButtonActions[source] = action", source)
        self.assertIn("activeButtonActions.removeValue(forKey: source)", source)
        self.assertIn('let buttonSource = source + ":button:" + name', source)


    def test_required_source_contracts_match_the_current_repository_files(self):
        root = Path(__file__).resolve().parents[2]
        validator = root / "scripts" / "validate-qemu-source.py"
        tree = ast.parse(validator.read_text(encoding="utf-8"), filename=str(validator))
        assignment = next(
            node for node in ast.walk(tree)
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "required"
                    for target in node.targets)
        )
        contracts = ast.literal_eval(assignment.value)
        for relative_path, tokens in contracts.items():
            source = (root / relative_path).read_text(encoding="utf-8")
            for token in tokens:
                with self.subTest(path=relative_path, token=token):
                    self.assertIn(token, source)


    def test_motion_look_is_connected_to_guest_pointer_lock(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        motion = source.split("private func configureMotionInput()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("motion.onLookDelta =", motion)
        self.assertIn("VRSettings.shared.pointerLockEnabled", motion)
        self.assertIn("vncClient.movePointer(dx: Float(yaw), dy: Float(pitch))", motion)
        self.assertIn("if vrSettings.mode == .cardboard { motion.start() }", motion)


    def test_crash_logger_uses_utf8_byte_limits_and_reserves_record_space(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "CrashLogger.swift").read_text(encoding="utf-8")
        self.assertIn("String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self)", source)
        self.assertIn("Int64(maximumLogBytes - data.count)", source)
        self.assertIn("size.int64Value > maximumExistingSize", source)


    def test_crash_logger_does_not_append_when_rotation_fails(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "CrashLogger.swift").read_text(encoding="utf-8")
        self.assertIn("guard rotateLatestLog() else { return }", source)
        self.assertIn("private func rotateLatestLog() -> Bool", source)


    def test_pe_string_scan_maps_one_contiguous_file_range(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "WindowsPEImage.swift").read_text(encoding="utf-8")
        reader = source.split("private func readCString", 1)[1].split("\n    private static func require", 1)[0]
        self.assertIn("let offset = try fileOffset(forRVA: rva)", reader)
        self.assertIn("let available = try contiguousFileLength(forRVA: rva)", reader)
        self.assertIn("file[range].firstIndex(of: 0)", reader)
        self.assertNotIn("for delta in 0..<limit", reader)


    def test_guest_backend_replacement_restores_loaded_entrypoint_and_stack(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        install = source.split("func installCPUBackend", 1)[1].split("func hostDeviceInfo", 1)[0]
        self.assertIn("backend.reset(entryPoint: loadedEntryPoint)", install)
        self.assertIn("backend.setInitialStackPointer(initialStackPointer)", install)
        self.assertIn("loadedEntryPoint = image.entryPoint", source)


    def test_elf_program_header_segment_matches_the_mapped_file_table(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        declared = source.split("if type == 6", 1)[1].split("if type == 2", 1)[0]
        self.assertIn("fileOffset == phoff", declared)
        self.assertIn("fileSize >= programHeaderTableSize", declared)
        self.assertIn("memorySize >= fileSize", declared)
        self.assertIn("mappedProgramHeaderAddress == declaredProgramHeaderAddress", source)


    def test_linux_syscall_range_validation_requires_mapped_memory(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("private func findFreeAddress(startingAt start: UInt64, size: UInt64, limit: UInt64) -> UInt64?", source)
        self.assertIn("if noReplace { return errno(17) }", source)
        self.assertIn("private func validateRange(address: UInt64, length: UInt64) -> UInt64", source)
        self.assertIn("cursor = min(end, range.upperBound)", source)

    def test_guest_image_load_resets_cpu_and_clears_memory_once_in_loader(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        loader = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        load = source.split("func loadELFImage", 1)[1].split("func reset", 1)[0]
        loader_body = loader.split("func load(", 1)[1].split("private func", 1)[0]
        before_loader = load.split("ELF64Loader().load", 1)[0]
        self.assertNotIn("memory.clear()", before_loader)
        self.assertLess(load.index("try cpu.reset(entryPoint: 0)"), load.index("ELF64Loader().load"))
        self.assertLess(loader_body.index("memory.clear()"), loader_body.index("for (segment, fileOffset) in pending"))
        self.assertIn("memory.clear()", load.split("} catch {", 1)[1])
        self.assertIn("_ = try? cpu.reset(entryPoint: 0)", load.split("} catch {", 1)[1])
        self.assertNotIn("cpu?.reset(entryPoint: 0)", load.split("} catch {", 1)[1])


    def test_linux_syscall_write_splits_large_utf8_output_without_truncation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        write_case = source.split("case 1:", 1)[1].split("case 3:", 1)[0]
        output = source.split("private func logGuestOutput", 1)[1].split("private func writeTimespec", 1)[0]
        self.assertIn("logGuestOutput(bytes, descriptor: descriptor)", write_case)
        self.assertIn("let stream = descriptor == 2 ? \"stderr\" : \"stdout\"", output)
        self.assertIn("for scalar in text.unicodeScalars", output)
        self.assertIn("chunkBytes + scalarByteCount > 4096", output)
        self.assertIn('log.write("[guest \\(stream)] " + chunk)', output)


    def test_gitlab_ci_runs_all_runtime_and_python_regression_suites(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".gitlab-ci.yml").read_text(encoding="utf-8")
        self.assertIn("scripts/tests/test_elf_loader_program_headers.swift", workflow)
        self.assertIn("scripts/tests/test_windows_pe_image.swift", workflow)
        self.assertIn("scripts/tests/test_static_elf_execution.swift", workflow)
        self.assertIn("scripts/tests/test_native_guest_memory.cpp", workflow)
        self.assertIn("g++ -std=c++17 -Wall -Wextra -Werror", workflow)
        self.assertIn("scripts/tests/test_vnc_key_state.swift", workflow)
        self.assertIn("scripts/tests/test_native_guest_memory.cpp", workflow)
        self.assertIn("g++ -std=c++17 -Wall -Wextra -Werror", workflow)
        self.assertIn("apt-get install -y --no-install-recommends bash build-essential", workflow)
        self.assertLess(
            workflow.index("apt-get install -y --no-install-recommends bash build-essential"),
            workflow.index("cc -std=c11"),
        )
        self.assertIn("python -m unittest discover -s scripts/tests -p 'test_*.py'", workflow)


    def test_guest_backend_replacement_resets_previous_syscall_state(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        install = source.split("func installCPUBackend", 1)[1].split("func hostDeviceInfo", 1)[0]
        self.assertIn("try currentCPU.reset(entryPoint: loadedEntryPoint)", install)
        self.assertLess(install.index("try currentCPU.reset"), install.index("try backend.reset"))


    def test_linux_getrandom_fills_a_single_bounded_buffer(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        random = source.split("private func getRandom", 1)[1].split("private func writeTimespec", 1)[0]
        self.assertIn("var data = Data(count: count)", random)
        self.assertIn("data.withUnsafeMutableBytes", random)
        self.assertIn("generator.next().littleEndian", random)
        self.assertIn("update(from: sourceBase.assumingMemoryBound(to: UInt8.self)", random)
        self.assertIn("flags & ~UInt64(0x7)", random)
        self.assertNotIn("(0..<Int(length)).map", random)


    def test_guest_time_structures_are_written_in_one_bounded_native_call(self):
        root = Path(__file__).resolve().parents[2]
        memory = (root / "src" / "Runtime" / "GuestMemory.swift").read_text(encoding="utf-8")
        syscalls = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        pair = memory.split("func writeUInt64Pair", 1)[1].split("func writeUInt64(", 1)[0]
        self.assertIn("isteam_guest_memory_write(native, offset, base, 16)", pair)
        self.assertIn("memory.writeUInt64Pair(seconds, nanoseconds, offset: address)", syscalls)
        self.assertIn("memory.writeUInt64Pair(seconds, microseconds, offset: address)", syscalls)
        for name in ("test_static_elf_execution.swift", "test_x86_64_interpreter.swift", "test_linux_syscall_dispatcher.swift"):
            harness = (root / "scripts" / "tests" / name).read_text(encoding="utf-8")
            self.assertIn("func writeUInt64Pair", harness)


    def test_guest_time_fraction_fields_are_within_linux_ranges(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        timespec = source.split("private func writeTimespec", 1)[1].split("private func writeTimeval", 1)[0]
        timeval = source.split("private func writeTimeval", 1)[1].split("private func errno", 1)[0]
        self.assertIn("min(UInt64(999_999_999)", timespec)
        self.assertIn("min(UInt64(999_999)", timeval)


    def test_qemu_runtime_does_not_cancel_active_builds_or_release_jobs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        qemu_job = workflow.split("\n  build-utm-runtime:\n", 1)[1].split("\n    steps:\n", 1)[0]
        self.assertIn("group: qemu-runtime-${{ github.workflow }}-${{ github.ref }}", qemu_job)
        self.assertIn("cancel-in-progress: false", qemu_job)

        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        release_job = release.split("\n  release:\n", 1)[1]
        self.assertIn("group: isteam-release-publish-${{ matrix.channel }}", release_job)
        self.assertIn("cancel-in-progress: false", release_job)

    def test_qemu_runtime_pins_xcode_27_1_on_supported_runner(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        self.assertIn("runs-on: xcode-27", workflow)
        self.assertIn('XCODE_APP="/Applications/Xcode_27.1.app"', workflow)
        self.assertIn('sudo xcode-select --switch "$XCODE_APP/Contents/Developer"', workflow)
        self.assertIn('if [ "$XCODE_VERSION" != "27.1" ]; then', workflow)


    def test_release_and_platform_validation_pin_xcode_26_2(self):
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        release_build = release.split("\n  build:\n", 1)[1].split("\n  release:\n", 1)[0]
        release_publish = release.split("\n  release:\n", 1)[1]
        validation = (root / ".github" / "workflows" / "validate-ios-build.yml").read_text(encoding="utf-8")
        validation_build = validation.split("\n  build-platform-simulators:\n", 1)[1]
        for name, job in (("release build", release_build), ("platform validation", validation_build)):
            with self.subTest(workflow=name):
                self.assertIn("runs-on: macos-26", job)
                self.assertIn('XCODE_APP="/Applications/Xcode_26.2.app"', job)
                self.assertIn('sudo xcode-select --switch "$XCODE_APP/Contents/Developer"', job)
                self.assertIn('if [ "$XCODE_VERSION" != "26.2" ]; then', job)
        self.assertIn("runs-on: ubuntu-24.04", release_publish)
        self.assertIn("sha256sum -c", release_publish)


    def test_qemu_acceleration_profiles_describe_actual_tcg_behavior(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        docs = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("TCG with a 64 MiB split-WX translation buffer; still requires JIT executable memory", settings)
        self.assertIn("?? .linuxVM", settings)
        self.assertNotIn("Slower compatibility fallback", settings)
        self.assertIn("tcg,tb-size=128,split-wx=on", builder)
        self.assertIn("tcg,tb-size=64,split-wx=on", builder)
        self.assertIn("QEMU TCG uses JIT code generation", docs)

    def test_linux_arm32_translator_requires_linux_syscall_abi(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "ExecutionBackendRouter.swift").read_text(encoding="utf-8")
        arm32 = source.split("case .linuxARM32ELF:", 1)[1].split("case .nativeARM64:", 1)[0]
        self.assertIn("required = [.linuxSyscallABI]", arm32)
        harness = (root / "scripts" / "tests" / "test_execution_backend_router.swift").read_text(encoding="utf-8")
        self.assertIn("!translatorOnlyPlan.isExecutableWithInstalledBackends", harness)
        self.assertIn("withABIPlan.isExecutableWithInstalledBackends", harness)

    def test_linux_elf_launch_uses_bounded_guest_machine_batches(self):
        root = Path(__file__).resolve().parents[2]
        launcher = (root / "src" / "Steam" / "GameLauncher.swift").read_text(encoding="utf-8")
        self.assertNotIn("completion: (@escaping", launcher)
        runtime = launcher.split("final class LinuxELFRuntime", 1)[1]
        self.assertIn("format == .linuxELF", launcher)
        self.assertIn("LinuxELFRuntime.shared.launch(", launcher)
        self.assertIn("machine.loadELFImage(at: executable, arguments: arguments)", runtime)
        self.assertIn("machine.runBatch(maxInstructions: Self.batchInstructionLimit)", runtime)
        self.assertIn("queue.asyncAfter", runtime)
        self.assertIn("private func executeNextBatch", runtime)
        self.assertIn("self.executeNextBatch(machine: machine, token: token)", runtime)
        self.assertNotIn("self.runNextBatch(machine: machine, token: token)", runtime)
        self.assertIn("machine.stop()", runtime)

    def test_custom_resolution_editor_enforces_the_64_mib_framebuffer_budget(self):
        settings = (Path(__file__).resolve().parents[2] / "iSteam/SettingsViewController.swift").read_text()
        self.assertIn("UInt64(w) * UInt64(h) * 4 <= UInt64(framebufferLimit)", settings)
        self.assertIn("framebuffer up to 64 MiB", settings)
        self.assertIn("framebuffer no larger than 64 MiB", settings)
        self.assertIn("self?.showInvalidResolutionAlert(); return", settings)

    def test_entitlement_settings_are_hidden_on_non_ios_and_visionos_targets(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "iSteam" / "SettingsViewController.swift").read_text(encoding="utf-8")
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertIn("#if os(iOS)\n        return 13\n#else\n        return 11\n#endif", settings)
        did_select = settings.split("override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)", 1)[1]
        action = did_select.split("case 11:", 1)[1].split("case 12:", 1)[0]
        reference = action.index("EntitlementSettingsView()")
        guard = action.rfind("#if os(iOS)", 0, reference)
        end = action.find("#endif", reference)
        self.assertGreater(guard, -1)
        self.assertGreater(end, reference)
        vision_target = project.split("  iSteamVision:", 1)[1].split("\n    settings:", 1)[0]
        self.assertIn("- EntitlementSettingsView.swift", vision_target)

    def test_console_uses_the_runtime_router_instead_of_direct_box64(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "ConsoleViewController.swift").read_text(encoding="utf-8")
        self.assertIn("GameLauncher.shared.launch(", source)
        self.assertNotIn("Box64Bridge.run(", source)
        self.assertIn("GameStore.shared.recordLaunchAccepted", source)

    def test_imported_games_are_reachable_from_the_ios_library(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "LibraryViewController.swift").read_text(encoding="utf-8")
        self.assertIn("GameLibraryViewController()", source)
        self.assertIn("super.init(style: .insetGrouped)", source)
        self.assertIn("GameStore.shared.search(\"\")", source)
        self.assertIn("ConsoleViewController(game:", source)

    def test_guest_machine_pause_works_between_bounded_execution_batches(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        pause = source.split("func pause()", 1)[1].split("func stop()", 1)[0]
        self.assertIn("_ = requestActiveStop()", pause)
        self.assertIn("if state == .configured", pause)
        self.assertIn("state = .paused", pause)


    def test_controller_profile_cache_and_metal_pool_release_contracts(self):
        root = Path(__file__).resolve().parents[2]
        controller = (root / "src" / "Display" / "ControllerMappingStore.swift").read_text(encoding="utf-8")
        metal = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")

        profile = controller.split("var profile: ControllerMappingProfile", 1)[1].split("func reset()", 1)[0]
        self.assertIn("private var cachedProfile: ControllerMappingProfile?", controller)
        self.assertIn("if let cachedProfile { return cachedProfile }", profile)
        self.assertIn("cachedProfile = value", profile)
        self.assertIn("cachedProfile = newValue", profile)
        self.assertIn("cachedProfile = .standard", controller)
        self.assertIn("private var framebufferSlots: [FramebufferSlot] = []", metal)
        stop = metal.split("func stop()", 1)[1].split("func submit", 1)[0]
        self.assertIn("framebufferGeneration &+= 1", stop)
        self.assertIn("framebuffer = nil", stop)
        self.assertIn("framebufferSlots.removeAll(keepingCapacity: false)", stop)


    def test_shared_directory_symlink_cannot_redefine_host_file_root(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "HostDeviceBridge.swift").read_text(encoding="utf-8")
        resolver = source.split("private func sharedFileURL", 1)[1].split("private static func machineIdentifier", 1)[0]
        self.assertIn("let requestedRoot = sharedDirectoryURL.standardizedFileURL", resolver)
        self.assertIn("guard resolvedRoot.path == root.path else", resolver)
        self.assertIn("resolved.path.hasPrefix(rootPrefix)", resolver)


    def test_touch_gamepad_restores_normalized_layout_while_editing(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Display" / "TouchGamepadView.swift").read_text(encoding="utf-8")
        layout = source.split("override func layoutSubviews()", 1)[1].split("private func installEditGesturesIfNeeded", 1)[0]
        self.assertIn("if !restoreLayout() {", layout)
        self.assertNotIn("didApplyLayout", source)
        self.assertNotIn("applyDefaultLayout()\n            } else if", layout)


    def test_repository_validation_does_not_cancel_active_runs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-repository.yml").read_text(encoding="utf-8")
        self.assertIn("  cancel-in-progress: false", workflow)
        self.assertNotIn("  cancel-in-progress: true", workflow)


    def test_guest_shared_paths_reject_embedded_nul_before_url_resolution(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "HostDeviceBridge.swift").read_text(encoding="utf-8")
        resolver = source.split("private func sharedFileURL", 1)[1].split("private static func machineIdentifier", 1)[0]
        nul_guard = '!relativePath.contains("\\0")'
        self.assertIn(nul_guard, resolver)
        self.assertLess(resolver.index(nul_guard), resolver.index("appendingPathComponent(relativePath)"))

    def test_library_backup_import_uses_one_consistent_game_snapshot(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Steam" / "DroidDeckFeatureServices.swift").read_text(encoding="utf-8")
        import_flow = source.split("func importBackup(from source: URL)", 1)[1].split("enum TransferError", 1)[0]
        self.assertEqual(import_flow.count("GameStore.shared.games"), 1)
        self.assertIn("let existingIDs = Set(current.map(\\.id))", import_flow)
        self.assertIn("let validGameIDs = existingIDs.union(seen)", import_flow)
        self.assertLess(import_flow.index("var current = GameStore.shared.games"), import_flow.index("for profile in backup.profiles"))
        self.assertLess(import_flow.index("let validGameIDs = existingIDs.union(seen)"), import_flow.index("for profile in backup.profiles"))

if __name__ == "__main__":
    unittest.main()
