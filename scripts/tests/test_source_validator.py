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

    def test_gitlab_validation_pipeline_builds_both_static_elf_guests(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".gitlab-ci.yml").read_text(encoding="utf-8")
        for token in (
            "python3 scripts/build_hybrid_xchg_smoke_elf.py build/hybrid_xchg_smoke.elf",
            "./build/hybrid_xchg_smoke.elf",
            "python3 scripts/build_hybrid_runtime_smoke_elf.py build/hybrid_runtime_smoke.elf",
            "./build/hybrid_runtime_smoke.elf",
            "build/hybrid_runtime_smoke.elf",
            "expire_in: 7 days",
        ):
            with self.subTest(token=token):
                self.assertIn(token, workflow)

    def test_source_contracts_track_vnc_generation_and_shared_cache_digest(self):
        root = Path(__file__).resolve().parents[2]
        validator = (root / "scripts" / "validate-qemu-source.py").read_text(encoding="utf-8")
        vnc_test = (root / "scripts" / "tests" / "test_vnc_pointer_coalescing.py").read_text(encoding="utf-8")
        cache = (root / "src" / "Performance" / "TranslationCache.swift").read_text(encoding="utf-8")
        for token in (
            "guard !Task.isCancelled, self.sessionGeneration == generation else { return false }",
            "guard !Task.isCancelled, self.sessionGeneration == generation,",
            "guard self.sessionGeneration == generation, self.connection === candidate else { return false }",
            "SHA256Hex.digest(Data(key.utf8))",
        ):
            with self.subTest(token=token):
                self.assertIn(token, validator)
        self.assertNotIn("SHA256.hash(data: Data(key.utf8))", validator)
        self.assertIn("guard !Task.isCancelled, self.sessionGeneration == generation,", vnc_test)
        self.assertIn("guard self.sessionGeneration == generation, self.connection === candidate else { return false }", vnc_test)
        self.assertIn("SHA256Hex.digest(Data(key.utf8))", cache)


    def test_backend_error_contract_uses_typed_error_description(self):
        root = Path(__file__).resolve().parents[2]
        validator = (root / "scripts" / "validate-qemu-source.py").read_text(encoding="utf-8")
        machine = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        self.assertIn('"private(set) var initializationError: GuestEngineError?"', validator)
        self.assertIn('"let error = GuestEngineError.backendNotInstalled(configuration.architecture)"', validator)
        self.assertIn('"self.initializationError = error"', validator)
        self.assertIn('"state = .failed(error.localizedDescription)"', validator)
        self.assertIn('"throw error"', validator)
        self.assertIn('"initializationError = nil"', validator)
        self.assertIn('"scripts/tests/test_linux_elf_runtime_initialization.py": [', validator)
        self.assertIn("let error = GuestEngineError.backendNotInstalled(configuration.architecture)", machine)
        self.assertIn("self.initializationError = error", machine)
        self.assertIn("self.state = .failed(error.localizedDescription)", machine)
        self.assertNotIn("backendNotInstalled(configuration.architecture).localizedDescription", validator)



    def test_guest_machine_has_one_serialized_stop_entry_point(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("func stop()"), 1)
        self.assertIn("func requestStop()", source)
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

    def test_release_ipa_validates_both_mode_specific_qemu_manifests(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        ios_package = workflow.split("- name: Build and package iOS IPA", 1)[1].split(
            "- name: Build and package tvOS IPA", 1
        )[0]
        for token in (
            'for MODE in JIT TCI; do',
            'MODE_MANIFEST="$MODE_DIR/runtime-library-path.txt"',
            'MODE_EXPORTS="$MODE_DIR/exports.txt"',
            'test -s "$RUNTIME_DIR/$RUNTIME_REL"',
            'cp -R "$RUNTIME_DIR/QEMU/." "$APP/QEMU/"',
            'test -s "$APP/$RUNTIME_REL"',
            'elif grep -Eq \' _?isteam_qemu_set_jit_callbacks$\' "$MODE_EXPORTS"',
        ):
            with self.subTest(token=token):
                self.assertIn(token, ios_package)
        self.assertNotIn('test -s "$RUNTIME_DIR/QEMU/runtime-library-path.txt"', ios_package)
        self.assertEqual(ios_package.count('for MODE in JIT TCI; do'), 2)
        self.assertIn("test \"$(awk 'END { print NR }' \"$MODE_MANIFEST\")\" -eq 1", ios_package)
        self.assertIn("Unsafe QEMU $MODE runtime path", ios_package)
        self.assertIn('test -s "$MODE_DIR/exports.txt"', ios_package)


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
        self.assertEqual(source.count("required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)"), 1)
        self.assertEqual(source.count('if [[ "$mode" == "jit" ]]; then'), 1)
        self.assertEqual(source.count("required_symbols+=(isteam_qemu_set_jit_callbacks)"), 1)
        self.assertEqual(source.count('for symbol in "${required_symbols[@]}"; do'), 1)
        self.assertEqual(source.count("codesign --verify --strict"), 1)
        self.assertNotIn("optional graceful-shutdown export", source)
        self.assertNotIn("for tool in file lipo nm codesign; do", source)

    def test_native_runtime_probes_loadability_before_start(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("let requestedJIT = configuration.accelerator == .jit", source)
        self.assertIn("var runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)", source)
        self.assertIn("switch runtimeStatus", source)
        self.assertIn('Self.sendQMP("stop")', source)
        self.assertIn('Self.sendQMP("cont")', source)
        self.assertIn('Self.sendQMP("system_reset")', source)
        self.assertIn("func reset(sessionGeneration expected: UInt64) -> Bool", source)
        self.assertIn("func stop(sessionGeneration expected: UInt64) -> Bool", source)
        self.assertIn("guard expected == sessionGeneration else { return true }", source)
        self.assertIn("sessionKey == requestedSessionKey", source)
        self.assertIn("QEMUCommandBuilder.qmpSocketPath.utf8.count < 104", source)
        self.assertNotIn("releaseScopesWhenStopped()", source)

    def test_repository_validation_checks_runtime_validator_shell_syntax(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-repository.yml").read_text(encoding="utf-8")
        self.assertIn("bash -n scripts/package-utm-qemu-runtime.sh", workflow)
        self.assertIn("bash -n scripts/package-utm-qemu-tci-runtime.sh", workflow)
        self.assertIn("bash -n scripts/merge-qemu-runtime-variants.sh", workflow)
        self.assertIn("bash -n scripts/validate-qemu-runtime.sh", workflow)
        self.assertIn("bash -n scripts/validate-apple-package.sh", workflow)
        for script in (
            "scripts/package-utm-qemu-runtime.sh",
            "scripts/package-utm-qemu-tci-runtime.sh",
            "scripts/merge-qemu-runtime-variants.sh",
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
        ):
            self.assertIn(f"`{symbol}`", readme)
        self.assertIn("Only JIT mode additionally requires", readme)
        self.assertIn("TCI validation checks lifecycle/shutdown exports", readme)
        self.assertIn("Build verification: a successful hosted JIT+TCI UTM build and combined artifact have not yet been recorded", readme)
        self.assertNotIn("qemu_system_shutdown_request` is optional", readme)
        self.assertEqual(readme.count("The runtime library must be built for **physical iOS arm64**"), 1)
        self.assertEqual(readme.count("Physical-device runtime startup"), 1)

    def test_tci_packager_and_merge_keep_mode_specific_artifacts(self):
        root = Path(__file__).resolve().parents[2]
        tci = (root / "scripts" / "package-utm-qemu-tci-runtime.sh").read_text(encoding="utf-8")
        merge = (root / "scripts" / "merge-qemu-runtime-variants.sh").read_text(encoding="utf-8")
        self.assertIn("has_jit_callbacks=false", tci)
        self.assertIn("QEMU-TCI.framework", tci)
        self.assertIn('bash "$SCRIPT_DIR/validate-qemu-runtime.sh" "$OUT/$runtime_relative" tci', tci)
        self.assertIn("StikJIT callback export: absent by design", tci)
        self.assertIn('grep -Eq "[[:space:]]_?${symbol}$" "$JIT_DIR/exports.txt"', merge)
        self.assertIn('grep -Eq "[[:space:]]_?${symbol}$" "$TCI_DIR/exports.txt"', merge)
        self.assertIn("grep -Eq '[[:space:]]_?isteam_qemu_set_jit_callbacks$' \"$JIT_DIR/exports.txt\"", merge)
        self.assertIn("if grep -Eq '[[:space:]]_?isteam_qemu_set_jit_callbacks$' \"$TCI_DIR/exports.txt\"; then", merge)
        self.assertIn("manifest_lines=\"$(awk 'END { print NR }' \"$package/QEMU/runtime-library-path.txt\")\"", merge)
        self.assertIn('[[ "$manifest_lines" -eq 1 ]]', merge)
        self.assertIn('mkdir -p "$TEMP_OUT/Frameworks" "$TEMP_OUT/QEMU/JIT" "$TEMP_OUT/QEMU/TCI"', merge)

    def test_guest_process_manager_validates_pe64_before_classification(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestProcess.swift").read_text(encoding="utf-8")
        validation = source.index("WindowsPEImage.validateHeader(handle: handle, fileSize: UInt64(size))")
        classification = source.index("return .success(.windowsPE)")
        self.assertLess(validation, classification)
        self.assertIn("return .success(.unknown)", source)

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
        self.assertIn("typedef int (*qemu_main_loop_fn)(void);", bridge)
        self.assertIn("typedef void (*qemu_cleanup_fn)(int);", bridge)
        self.assertIn("#define ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI 5", bridge)
        self.assertIn("g_running = false;", bridge)
        main_loop_call = "int qemu_exit_status = g_qemu_main_loop();"
        self.assertLess(
            bridge.index(main_loop_call),
            bridge.index("g_running = false;", bridge.index(main_loop_call)),
        )
        self.assertLess(
            bridge.index("g_running = false;", bridge.index(main_loop_call)),
            bridge.index("if (g_qemu_cleanup) g_qemu_cleanup(qemu_exit_status);"),
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
        self.assertIn("let mapping = try fileBackedRange(forRVA: rva)", reader)
        self.assertIn("let offset = mapping.offset", reader)
        self.assertIn("let scanLength = min(limit, mapping.length)", reader)
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
        self.assertIn("while memory.hasMappedPages(offset: candidate, length: size)", source)
        self.assertIn("private func validateRange(address: UInt64, length: UInt64) -> UInt64", source)
        self.assertIn("while cursor < end", source)
        self.assertIn("memory.hasMappedPages(offset: cursor, length: 4096)", source)
        self.assertIn("cursor = next", source)


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


    def test_github_actions_runs_all_runtime_and_python_regression_suites(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (
            root / ".github" / "workflows" / "validate-repository.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("scripts/tests/test_execution_backend_router.swift", workflow)
        self.assertIn("scripts/tests/test_elf_loader_program_headers.swift", workflow)
        self.assertIn("scripts/tests/test_windows_pe_image.swift", workflow)
        self.assertIn("scripts/tests/test_static_elf_execution.swift", workflow)
        self.assertIn("scripts/tests/test_native_guest_memory.cpp", workflow)
        self.assertIn("clang++ -std=c++17 -Wall -Wextra -Werror", workflow)
        self.assertIn("cc -std=c11 -Wall -Wextra -Werror -pthread", workflow)
        self.assertIn("scripts/tests/test_vnc_key_state.swift", workflow)
        self.assertIn("python -m unittest discover -s scripts/tests -p 'test_*.py'", workflow)
        gitlab_ci = (root / ".gitlab-ci.yml").read_text(encoding="utf-8")
        self.assertIn('CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "api"', gitlab_ci)
        self.assertIn('$CI_COMMIT_BRANCH == "main"', gitlab_ci)
        self.assertIn("python3 scripts/validate-qemu-source.py", gitlab_ci)
        self.assertIn("python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v", gitlab_ci)
        self.assertIn("scripts/build_hybrid_xchg_smoke_elf.py build/hybrid_xchg_smoke.elf", gitlab_ci)
        self.assertEqual(workflow.count("      - .gitlab-ci.yml"), 2)


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


    def test_qemu_runtime_allows_parallel_builds_and_serializes_release_publication(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        qemu_job = workflow.split("\n  build-utm-runtime:\n", 1)[1].split("\n    steps:\n", 1)[0]
        self.assertNotIn("concurrency:", qemu_job)
        self.assertNotIn("group: qemu-runtime-", qemu_job)

        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        release_job = release.split("\n  release:\n", 1)[1]
        self.assertIn("group: isteam-release-publish-${{ matrix.channel }}", release_job)
        self.assertIn("cancel-in-progress: false", release_job)

    def test_qemu_runtime_uses_the_xcode_27_runner_toolchain(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "build-qemu-runtime.yml").read_text(encoding="utf-8")
        self.assertIn("runs-on: xcode-27", workflow)
        self.assertIn('XCODE_DEVELOPER_DIR="$(xcode-select -p)"', workflow)
        self.assertIn('if ! awk -v version="$XCODE_VERSION"', workflow)
        self.assertIn('split(version, p, "[.]")', workflow)
        self.assertIn("major > 27 || (major == 27 && minor >= 1)", workflow)
        self.assertIn("Expected Xcode 27.1 or later on the xcode-27 runner", workflow)

    def test_release_and_platform_validation_require_xcode_27_1_or_later(self):
        root = Path(__file__).resolve().parents[2]
        release = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        release_build = release.split("\n  build:\n", 1)[1].split("\n  release:\n", 1)[0]
        release_publish = release.split("\n  release:\n", 1)[1]
        validation = (root / ".github" / "workflows" / "validate-ios-build.yml").read_text(encoding="utf-8")
        validation_build = validation.split("\n  build-platform-simulators:\n", 1)[1]
        for name, job in (("release build", release_build), ("platform validation", validation_build)):
            with self.subTest(workflow=name):
                self.assertIn("runs-on: xcode-27", job)
                self.assertIn('XCODE_DEVELOPER_DIR="$(xcode-select -p)"', job)
                self.assertIn('if ! awk -v version="$XCODE_VERSION"', job)
                self.assertIn('split(version, p, "[.]")', job)
                self.assertIn("major > 27 || (major == 27 && minor >= 1)", job)
                self.assertIn("Expected Xcode 27.1 or later on the xcode-27 runner", job)
        self.assertIn("runs-on: ubuntu-24.04", release_publish)
        self.assertIn("sha256sum -c", release_publish)

    def test_xcode_version_guard_uses_numeric_major_and_minor_semantics(self):
        root = Path(__file__).resolve().parents[2]
        workflows = (
            root / ".github" / "workflows" / "build-qemu-runtime.yml",
            root / ".github" / "workflows" / "release.yml",
            root / ".github" / "workflows" / "validate-ios-build.yml",
        )
        awk_program = 'BEGIN { split(version, p, "[.]"); major = p[1] + 0; minor = p[2] + 0; exit !(major > 27 || (major == 27 && minor >= 1)) }'
        for workflow in workflows:
            source = workflow.read_text(encoding="utf-8")
            self.assertIn(awk_program, source, workflow.name)
        for version in ("27.1", "27.10", "28.0", "28.1", "29.0"):
            with self.subTest(version=version):
                result = subprocess.run(
                    ["awk", "-v", f"version={version}", awk_program],
                    check=False, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        for version in ("27.0", "26.4", "26.99", "27", "invalid"):
            with self.subTest(version=version):
                result = subprocess.run(
                    ["awk", "-v", f"version={version}", awk_program],
                    check=False, capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)


    def test_static_pie_relocation_uses_loader_method_not_shadowed_parameter(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "ELF64Loader.swift").read_text(encoding="utf-8")
        relocation = source.split("private func applyStaticPIERelocations", 1)[1].split(
            "private func loadSegment", 1
        )[0]
        self.assertIn("let relaFileOffset = self.fileOffset(", relocation)
        self.assertIn("forVirtualAddress: relaAddress", relocation)
        self.assertNotIn("let relaFileOffset = fileOffset(", relocation)


    def test_windows_pe_import_validation_compiles_guest_process_manager(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-ios-build.yml").read_text(encoding="utf-8")
        step = workflow.split("- name: Test bounded Windows PE import directory parsing", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("src/Runtime/GuestProcess.swift", step)
        self.assertIn("src/Runtime/WindowsPEImage.swift", step)
        self.assertIn("scripts/tests/test_windows_pe_image.swift", step)

    def test_platform_validation_compiles_physical_ios_arm64(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-ios-build.yml").read_text(encoding="utf-8")
        push = workflow.split("  push:", 1)[1].split("  pull_request:", 1)[0]
        for path in ("- src/**", "- iSteam/**", "- project.yml", "- scripts/tests/**"):
            with self.subTest(path=path):
                self.assertIn(path, push)
        device = workflow.split("\n  build-ios-device:\n", 1)[1]
        self.assertIn("-sdk iphoneos", device)
        self.assertIn("-destination 'generic/platform=iOS'", device)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", device)
        self.assertIn("build", device)


    def test_qemu_tci_fallback_is_only_used_for_automatic_backend(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        launch = (root / "iSteam" / "LaunchSetupViewController.swift").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("var allowsTCIFallback: Bool { self == .automatic }", settings)
        self.assertIn("let selectedAcceleration = RuntimeSettings.shared.acceleration", launch)
        self.assertIn("guard selectedAcceleration.allowsTCIFallback else", launch)
        self.assertLess(
            launch.index("guard selectedAcceleration.allowsTCIFallback else"),
            launch.index("QEMURuntimeStatus.inspect(requiresJIT: false)"),
        )
        self.assertIn("let allowsTCIFallback = RuntimeSettings.shared.acceleration.allowsTCIFallback", runtime)
        self.assertEqual(runtime.count("guard allowsTCIFallback else"), 2)


    def test_qemu_acceleration_profiles_describe_actual_tcg_behavior(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "src" / "Core" / "RuntimeSettings.swift").read_text(encoding="utf-8")
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        docs = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("QEMU TCG + JIT", settings)
        self.assertIn("QEMU TCI (no JIT)", settings)
        self.assertIn("Uses QEMU's threaded TCI interpreter without JIT entitlements or executable-memory support.", settings)
        self.assertIn("TCG with a 128 MiB translation-block cache and split-WX", settings)
        self.assertIn("?? .linuxVM", settings)
        self.assertNotIn("Slower compatibility fallback", settings)
        self.assertIn('configuration.accelerator == .jit ? "tcg,tb-size=128,split-wx=on" : "tcg"', builder)
        self.assertNotIn("tcg,tb-size=64,split-wx=on", builder)
        self.assertIn("JIT profile uses native TCG code generation", docs)
        self.assertIn("`ios-tci` dependency targets", docs)
        self.assertIn("successful hosted dual-runtime build and physical guest boot remain unverified", docs)


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
        self.assertIn("let configuration = VMConfiguration.defaultLinux", runtime)
        self.assertIn("configuration: configuration", runtime)
        self.assertNotIn("guestMemorySize", runtime)
        self.assertNotIn("memorySize: Self.guestMemorySize", runtime)
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
        self.assertIn("#if os(iOS)\n        return 14\n#else\n        return 11\n#endif", settings)
        self.assertIn("#if os(iOS)\n        case 13: return AkatsubakiAppIcon.allCases.count\n#endif", settings)
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

    def test_release_channel_metadata_is_bound_after_freshness_without_force_moving_tags(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        verify = workflow.index("- name: Verify combined release assets")
        final_check = workflow.index("- name: Re-check freshness immediately before publishing")
        metadata = workflow.index("- name: Set release metadata")
        publish = workflow.index("- name: Publish combined release")
        self.assertLess(verify, final_check)
        self.assertLess(final_check, metadata)
        self.assertLess(metadata, publish)
        metadata_step = workflow[metadata:publish]
        publish_step = workflow[publish:]
        self.assertIn('echo "tag=$RELEASE_CHANNEL" >> "$GITHUB_OUTPUT"', metadata_step)
        self.assertIn("tag_name: ${{ steps.meta.outputs.tag }}", publish_step)
        self.assertIn("target_commitish: ${{ github.sha }}", publish_step)
        self.assertIn("contents: write", workflow)
        self.assertIn("if: steps.final-freshness.outputs.publish == 'true'", publish_step)
        self.assertNotIn("git tag --force", workflow)
        self.assertNotIn("git push --force", workflow)

    def test_release_workflow_fails_when_any_required_job_is_skipped(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn("\n  enforce-no-skipped-jobs:\n", workflow)
        guard = workflow.split("\n  enforce-no-skipped-jobs:\n", 1)[1]
        self.assertIn("    if: always()\n", guard)
        self.assertNotIn("if: always() &&", guard)
        needs = guard.split("    needs:\n", 1)[1].split("    runs-on:", 1)[0]
        all_jobs = {
            line.strip()[:-1]
            for line in workflow.split("\njobs:\n", 1)[1].splitlines()
            if line.startswith("  ") and not line.startswith("   ") and line.endswith(":")
        }
        guarded_jobs = {
            line.strip()[2:]
            for line in needs.splitlines()
            if line.strip().startswith("- ")
        }
        all_jobs.discard("enforce-no-skipped-jobs")
        self.assertEqual(guarded_jobs, all_jobs, "The final guard must depend on every other top-level job.")
        self.assertIn("JOB_RESULTS: ${{ toJSON(needs) }}", guard)
        self.assertIn('if job.get("result") != "success"', guard)
        self.assertIn("raise SystemExit(1)", guard)

    def test_release_workflow_runs_for_main_push_and_reconciliation_completion(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        freshness = (root / "scripts" / "check-build-freshness.sh").read_text(encoding="utf-8")
        self.assertIn("  push:\n    branches: [main]\n", workflow)
        self.assertNotIn("paths-ignore:", workflow)
        self.assertIn(
            '  workflow_run:\n    workflows: ["Reconcile GitLab mirror history"]\n    types: [completed]\n    branches: [main]\n',
            workflow,
        )
        self.assertIn(".github/workflows/reconcile-gitlab-main.yml", freshness)

    def test_aot_c7_entry_guard_respects_guest_page_boundary(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        helper = source.split("private func canTranslateRegisterImmediateMOVAtCurrentWindow", 1)[1].split(
            "private func canTranslateLEAAtCurrentWindow", 1
        )[0]
        self.assertIn("opcodeOffset + 6 <= pageRemaining", helper)

    def test_aot_architecture_docs_match_translator_version(self):
        root = Path(__file__).resolve().parents[2]
        docs = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertIn("Translator version 10 emits", docs)
        self.assertIn("Translator version 10 enforces", docs)
        self.assertIn("CWDE/CDQE and CDQ/CQO", docs)
        self.assertIn("register-only MOVZX/MOVSX", docs)
        self.assertIn("MOVSXD", docs)
        self.assertIn("accumulator/register XCHG", docs)

    def test_kenran_buto_aot_is_opt_in_and_fails_closed(self):
        root = Path(__file__).resolve().parents[2]
        machine = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        launcher = (root / "src" / "Steam" / "GameLauncher.swift").read_text(encoding="utf-8")
        executor = (root / "src" / "Runtime" / "KenranButoAOTExecution.swift").read_text(encoding="utf-8")
        interpreter = (root / "src" / "Runtime" / "X86_64Interpreter.swift").read_text(encoding="utf-8")
        translator = (root / "src" / "Runtime" / "X86_64AOTTranslator.swift").read_text(encoding="utf-8")
        provider = (root / "iSteam" / "KenranButoAOTExecutableMemory.c").read_text(encoding="utf-8")
        self.assertIn("aotExecutor: KenranButoAOTExecuting? = nil", machine)
        self.assertIn("aotExecutor: KenranButoAOTExecutor()", launcher)
        self.assertIn("func refreshAvailability() -> Bool", executor)
        self.assertIn("func refreshAvailability() -> Bool", interpreter)
        self.assertIn("aotExecutor?.refreshAvailability() == true", interpreter)
        self.assertRegex(translator, r'static let translatorVersion = "\d+"')
        self.assertIn("case 0x98:", translator)
        self.assertIn("case 0x99:", translator)
        self.assertIn("arithmeticShiftRight", translator)
        eligibility = interpreter.split("private func canStartAOTBlock() -> Bool {", 1)[1].split(
            "private func canTranslateRegisterXCHGAtCurrentWindow", 1
        )[0]
        self.assertIn("case 0x98, 0x99:", eligibility)
        self.assertIn("case 0x0F:", translator)
        self.assertIn("case 0x63:", translator)
        self.assertIn("extendRegister", translator)
        self.assertIn("iSteamAOTExecutableMemoryIsAvailable()", provider)
        invoke = provider.split("bool iSteamAOTExecutableMemoryInvoke", 1)[1].split("void iSteamAOTExecutableMemoryDestroy", 1)[0]
        self.assertIn("iSteamAOTExecutableMemoryIsAvailable()", invoke)
        self.assertIn("private static let maximumAOTInstructionBatch = 16", interpreter)
        self.assertIn("private static let maximumX86InstructionLength = 15", interpreter)
        self.assertIn("let budget = Int(min(remaining, UInt64(Self.maximumAOTInstructionBatch)))", interpreter)
        self.assertIn("let maximumAOTBytes = min(", interpreter)
        self.assertIn("budget * Self.maximumX86InstructionLength", interpreter)
        self.assertIn("let stopCheckMask: UInt64 = aotIsAvailable ? 0x0f : 0xff", interpreter)

    def test_core_only_ipa_validator_accepts_numeric_ios_device_platform(self):
        root = Path(__file__).resolve().parents[2]
        validator = (root / "scripts" / "validate-core-only-ipa.sh").read_text(encoding="utf-8")
        self.assertIn("CFBundleSupportedPlatforms", validator)
        self.assertIn("BUILD_PLATFORM", validator)
        self.assertIn('"IOS"', validator)
        self.assertIn('"2"', validator)
        self.assertNotIn("grep -A5 'LC_BUILD_VERSION'", validator)

    def test_vnc_frames_are_rejected_after_session_replacement(self):
        root = Path(__file__).resolve().parents[2]
        vnc = (root / "src" / "QEMU" / "QEMUVNCClient.swift").read_text(encoding="utf-8")
        virtio = (root / "src" / "GPU" / "VirtIOGPU.swift").read_text(encoding="utf-8")
        metal = (root / "src" / "GPU" / "MetalGPUBackend.swift").read_text(encoding="utf-8")
        display = (root / "src" / "Display" / "VMDisplayViewController.swift").read_text(encoding="utf-8")
        self.assertIn("onFrame?(generation, frame.0, frame.1, frame.2, dirtyRegion)", vnc)
        self.assertIn("onSessionGenerationChanged?(generation)", vnc)
        self.assertIn("guard isCurrent else { return }", virtio)
        self.assertIn("pending.sessionGeneration == sessionGeneration", metal)
        self.assertIn("framebuffer === source", metal)
        self.assertIn("sessionGeneration: generation", display)

    def test_ios_guest_memory_budget_is_adaptive_and_revalidated(self):
        root = Path(__file__).resolve().parents[2]
        configuration = (root / "src" / "Core" / "VMConfiguration.swift").read_text(encoding="utf-8")
        validation = (root / "src" / "Core" / "VMConfigurationValidation.swift").read_text(encoding="utf-8")
        workflow = (root / ".github" / "workflows" / "validate-kenran-buto-aot.yml").read_text(encoding="utf-8")
        self.assertIn("recommendedLinuxMemoryMB", configuration)
        self.assertIn("linuxMemoryBudgetMB(availableMemoryMB:", configuration)
        self.assertIn("os_proc_available_memory()", configuration)
        self.assertIn("memoryMB: recommendedLinuxMemoryMB", configuration)
        self.assertIn("insufficientAvailableMemory", validation)
        self.assertIn("availableMemoryBytes: UInt64? = nil", validation)
        self.assertIn("max(512, memoryMB / 4)", validation)
        self.assertIn("test_vm_configuration_validation.swift", workflow)

    def test_qemu_uses_persistent_qmp_control_without_relaunching_process(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        backend = (root / "src" / "QEMU" / "QEMUBackend.swift").read_text(encoding="utf-8")
        engine = (root / "src" / "Core" / "VMEngine.swift").read_text(encoding="utf-8")
        builder = (root / "src" / "QEMU" / "QEMUCommandBuilder.swift").read_text(encoding="utf-8")
        self.assertIn("AF_UNIX", bridge)
        self.assertIn("qmp_capabilities", bridge)
        self.assertIn("MSG_NOSIGNAL", bridge)
        self.assertIn("static let shared = QEMUNativeRuntime()", runtime)
        self.assertIn("private var sessionGeneration: UInt64 = 0", runtime)
        self.assertIn("guard isPaused else", runtime)
        self.assertIn('Self.sendQMP("system_reset")', runtime)
        self.assertIn('Self.sendQMP("stop")', runtime)
        self.assertIn("private var sessionGeneration: UInt64?", backend)
        self.assertIn("runtime.stop(sessionGeneration: sessionGeneration)", backend)
        self.assertIn("if backend?.stop() ?? true", engine)
        self.assertIn("-no-shutdown", builder)
        self.assertIn("-qmp", builder)

    def test_txm_arena_tracks_exact_allocations_and_stress_regressions(self):
        root = Path(__file__).resolve().parents[2]
        arena = (root / "iSteam" / "AOTExecutableArena.c").read_text(encoding="utf-8")
        tests = (root / "scripts" / "tests" / "test_aot_executable_arena.c").read_text(encoding="utf-8")
        self.assertIn("iSteamAOTExecutableAllocation", arena)
        self.assertIn("allocation_cursor", arena)
        self.assertIn("test_partial_and_wrong_size_frees_are_rejected", tests)
        self.assertIn("test_randomized_allocation_and_free_stress", tests)

    def test_aot_workflow_validates_yaml_and_covers_runtime_regressions(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github" / "workflows" / "validate-kenran-buto-aot.yml").read_text(encoding="utf-8")
        required = (
            "Validate GitHub Actions workflow YAML",
            'YAML.load_file(path, aliases: true)',
            "scripts/tests/test_aot_executable_arena.c",
            "iSteam/AOTExecutableArena.c",
            "scripts/tests/test_native_guest_machine_smoke.swift",
            "scripts/tests/test_execution_backend_router.swift",
            ".github/workflows/build-qemu-runtime.yml",
            ".github/workflows/build-core-only-ios.yml",
            "iSteam/JITCoordinator.swift",
            "scripts/tests/test_ios_jit_memory_contract.py",
            "scripts/tests/test_jit_protocol.py",
            "scripts/tests/test_jit_coordinator.py",
            "Compile TXM/SPTM iOS arm64 JIT sources",
        )
        for token in required:
            with self.subTest(token=token):
                self.assertIn(token, workflow)

if __name__ == "__main__":
    unittest.main()
