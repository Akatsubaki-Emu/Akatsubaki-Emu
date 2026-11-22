#!/usr/bin/env python3
"""Prevent silent duplicate keys and lifecycle/source-contract regressions."""
import ast
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

    def test_qemu_packager_has_one_complete_candidate_scan(self):
        root = Path(__file__).resolve().parents[2]
        package = (root / "scripts" / "package-utm-qemu-runtime.sh").read_text(encoding="utf-8")
        runtime_validator = (root / "scripts" / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")

        self.assertEqual(package.count('candidate=""'), 1)
        self.assertEqual(package.count('candidate="$file"'), 1)
        self.assertIn("qemu_system_shutdown_request", package)
        self.assertIn("isteam_qemu_set_jit_callbacks", package)
        self.assertIn("runtime-library-path.txt", package)
        self.assertIn("qemu_system_shutdown_request", runtime_validator)
        self.assertIn("isteam_qemu_set_jit_callbacks", runtime_validator)
        self.assertIn('dlsym(library, "isteam_qemu_set_jit_callbacks")', bridge)
        self.assertNotIn("duplicate_string", bridge)

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
        self.assertIn("memorySize >= programHeaderTableSize", declared)
        self.assertIn("mappedProgramHeaderAddress == declaredProgramHeaderAddress", source)


    def test_linux_syscall_range_validation_requires_mapped_memory(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        self.assertIn("private func findFreeAddress(startingAt start: UInt64, size: UInt64, limit: UInt64) -> UInt64?", source)
        self.assertIn("if noReplace { return errno(17) }", source)
        self.assertIn("private func validateRange(address: UInt64, length: UInt64) -> UInt64", source)
        self.assertIn("cursor = min(end, range.upperBound)", source)

    def test_guest_image_load_resets_old_syscall_state_before_replacing_memory(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        load = source.split("func loadELFImage", 1)[1].split("func reset", 1)[0]
        self.assertLess(load.index("try cpu.reset(entryPoint: 0)"), load.index("ELF64Loader().load"))


    def test_linux_syscall_write_splits_large_utf8_output_without_truncation(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        write_case = source.split("case 1:", 1)[1].split("case 3:", 1)[0]
        self.assertIn("for scalar in text.unicodeScalars", write_case)
        self.assertIn("chunkBytes + scalarByteCount > 4096", write_case)
        self.assertIn("log.write(\"[guest stdout] \" + text[start..<end])", write_case)


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


    def test_qemu_runtime_manual_runs_do_not_cancel_release_jobs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_qemu_build_patches.py").read_text(encoding="utf-8")
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("test_qemu_runtime_does_not_cancel_in_progress_release_build", tests)


    def test_qemu_acceleration_profiles_describe_actual_tcg_behavior(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        docs = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("TCG still uses JIT code generation", settings)
        self.assertNotIn("Slower compatibility fallback", settings)
        self.assertIn("tcg,tb-size=128,split-wx=on", builder)
        self.assertIn(' : "tcg"', builder)
        self.assertIn("QEMU TCG uses JIT code generation", docs)

    def test_linux_arm32_translator_requires_linux_syscall_abi(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "ExecutionBackendRouter.swift").read_text(encoding="utf-8")
        arm32 = source.split("case .linuxARM32ELF:", 1)[1].split("case .nativeARM64:", 1)[0]
        self.assertIn("required = [.linuxSyscallABI]", arm32)
        harness = (root / "scripts" / "tests" / "test_execution_backend_router.swift").read_text(encoding="utf-8")
        self.assertIn("!translatorOnlyPlan.isExecutableWithInstalledBackends", harness)
        self.assertIn("withABIPlan.isExecutableWithInstalledBackends", harness)

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


if __name__ == "__main__":
    unittest.main()
