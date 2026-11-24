#!/usr/bin/env python3
"""Guard against malformed QEMU bridge source and accidental regressions."""
from pathlib import Path
import sys

required = {
    "src/QEMU/VNCKeyState.swift": [
        "private var keySources: [UInt32: Set<String>] = [:]",
        "private var movementSources: [String: UInt8] = [:]",
        "static func movementMask(for x: Float, y: Float) -> UInt8",
        "mutating func setKey(",
        "mutating func setMovement(",
        "mutating func releaseAll()",
    ],
    "scripts/tests/test_vnc_key_state.swift": [
        "keyboard source release preserves a controller-held key",
        "movement source release preserves another source",
        "releaseAll clears every source",
    ],
    "src/QEMU/QEMUVNCClient.swift": [
        "pendingSendGroup = DispatchGroup()",
        "group.enter()",
        "group.leave()",
        "previousGroup.notify(queue: queue)",
        "framebufferWidth = width",
        "width <= Self.maxFramebufferBytes / height / 4",
        "for attempt in 0..<120",
        "32bpp, 24-bit depth, little endian, true colour; memory order B,G,R,X.",
        "Raw rectangles and DesktopSize updates only.",
        "if encoding == -223",
        "guard count <= 4096",
        "rectangleBytes <= Self.maxFramebufferBytes - updateBytes",
        "private var keyState = VNCKeyState()",
        "keyState.setKey(keysym, source: source, isDown: down)",
        "sendKey(key, down: down, source: source + \":\" + name)",
        "keyState.setMovement(desiredMask, source: source)",
        "keyState.releaseAll()",
        "self.connected = false",
        "private var sessionGeneration: UInt64 = 0",
        "guard !Task.isCancelled, self.sessionGeneration == generation else { return false }",
        "guard !Task.isCancelled, self.sessionGeneration == generation,",
        "self.connection === candidate else { return false }",
        "guard activated else {",
        "let wasCurrent = self.withStateLock",
        "guard self.sessionGeneration == generation, self.connection === candidate else { return false }",
        "self.sessionGeneration == generation && self.connection === candidate && self.connected",
        "self.connection = nil",
        "self.pendingSendGroup = DispatchGroup()",
        "_ = self.keyState.releaseAll()",
        "if wasCurrent",
        "private func enqueueSend(_ data: Data, to connection: NWConnection,",
        "guard dx.isFinite, dy.isFinite",
        "let boundedX = max(-Float(framebufferWidth)",
        "let boundedY = max(-Float(framebufferHeight)",
    ],
    "scripts/tests/test_vnc_pointer_coalescing.py": [
        "test_pointer_updates_coalesce_per_connection_on_ordered_send_queue",
        "test_cancelled_reader_cannot_install_connection_after_stop",
        "test_reconnect_does_not_publish_unhandshaken_or_stale_connection",
        "guard !Task.isCancelled, self.connection === candidate else { return false }",
        "let wasCurrent = self.withStateLock",
        "guard self.connection === candidate else { return false }",
        "self.pendingSendGroup = DispatchGroup()",
        "if wasCurrent",
        "_ = self.keyState.releaseAll()",
    ],
    "src/Runtime/WindowsPELoader.swift": [
        "fileSize <= 512 * 1024 * 1024",
        "case unreadableFile, tooSmall, tooLarge",
        "WindowsPEImage.parse(data)",
        "is64Bit: true",
    ],
    "src/Runtime/WindowsPEImage.swift": [
        "unterminated PE string within its mapped section",
        "let descriptorRVA = UInt64(directory.rva) + UInt64(index) * 20",
        "descriptorCursor.offset(forRVA: UInt32(descriptorRVA), length: 20)",
        "UInt64(sizeOfHeaders) >= UInt64(table + tableSize.partialValue)",
        "import directory range is invalid",
        "relocation directory range is invalid",
        "private func contiguousFileLength(forRVA rva: UInt32) throws -> Int",
        "file[range].firstIndex(of: 0)",
        "Section(name: name,\n                virtualAddress:",
        "virtualSize: try u32(data, offset + 8)",
        "rawOffset: try u32(data, offset + 20)",
        "imageEndOverflow",
        "SizeOfHeaders does not cover the section table",
        "overlapping virtual sections",
        "overlapping raw sections",
        "entry point is not backed by executable section data",
        "private let virtualSections: [Section]",
        "private let sectionsAreSortedByRVA: Bool",
        "private static let linearSectionLookupThreshold = 16",
        "if sections.count <= Self.linearSectionLookupThreshold",
        "while lower < upper",
        "virtualSections[middle].virtualAddress <= rva",
        "private func fileBackedRange(forRVA rva: UInt32, allowEnd: Bool = false)",
        "private struct RVAFileCursor",
        "UInt64(rva) == nextRVA",
        "length <= remainingBytes",
        "var descriptorCursor = RVAFileCursor(image: self)",
        "var thunkCursor = RVAFileCursor(image: self)",
        "var relocationCursor = RVAFileCursor(image: self)",
        "let sectionsAreSortedByRVA = zip(sections, sections.dropFirst())",
        "String(bytes: data[offset..<(offset + 8)].prefix { $0 != 0 }, encoding: .ascii)",
    ],
    "iSteam/JITCoordinator.swift": [
        "if #available(iOS 26.0, *)",
        "return iSteamJITIsSupported()",
        "scheme = \"stikdebug\"",
        "host = \"enable-jit\"",
        "script-name",
        "#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)",
        "isJITProtocolKnown",
        "guard isJITProtocolKnown else",
    ],
    "iSteam/CrashLogger.swift": [
        "queueKey = DispatchSpecificKey<UInt8>()",
        "String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self)",
        "Int64(maximumLogBytes - data.count)",
        "guard rotateLatestLog() else { return }",
        "private func rotateLatestLog() -> Bool",
        "performSynchronouslyOnQueue",
        "boundedString(details, maximumBytes: 500_000)",
        "data.write(to: latestLogURL, options: .atomic)",
        "maximumLogBytes = 5 * 1024 * 1024",
        "previous-crash.log",
    ],
    "iSteam/ELFValidator.swift": [
        "guard fileType == 2 || fileType == 3",
        "unsupportedFileType",
    ],
    "iSteam/LaunchSetupViewController.swift": [
        "guestControl.selectedSegmentIndex = 2",
        "executable-library route currently accepts Windows PE metadata only",
        "SteamOS Gaming Mode",
        "VMConfiguration.defaultSteamOS",
    ],
    "src/Performance/TranslationCache.swift": [
        "SHA256.hash(data: Data(key.utf8))",
    ],
    "scripts/tests/test_windows_pe_image.swift": [
        "relocationDirectoryRVA: UInt32 = 0",
        "Import descriptor crossing raw section boundary was accepted",
        "Header RVA range crossing SizeOfHeaders was accepted",
        "Import directory smaller than one descriptor was accepted",
        "Relocation directory smaller than one block was accepted",
        "PE string scanning crossed a section raw-data boundary",
        "Zero-length PE boundary mapping changed",
        "32 sections exercise the binary-search path",
        "32-section PE binary lookup returned an incorrect file offset",
        "Sequential import thunk cursor returned incorrect ordinals",
        "Cross-section import thunk cursor failed to remap",
        "Cross-section relocation cursor failed to remap",
        "func startAccessingSecurityScopedResource() -> Bool { false }",
    ],
    "src/Runtime/RuntimeComponentManifest.swift": [
        "resolvingSymlinksInPath()",
        "rootPrefix",
    ],
    "scripts/tests/test_linux_elf_runtime_initialization.py": [
        "test_guest_machine_retains_typed_initialization_errors",
        "test_linux_elf_runtime_propagates_initialization_error",
        "test_stop_requests_interruption_without_blocking_the_calling_thread",
    ],
    "src/Runtime/LinuxSyscallDispatcher.swift": [
        "func configure(programBreak: UInt64, stackBase: UInt64) throws",
        "private func findFreeAddress(startingAt start: UInt64, size: UInt64, limit: UInt64) -> UInt64?",
        "private func mappedRangesAfterMapping(",
        "private func mappedRangesAfterRemoving(",
        "private func firstMappedRangeEnding(after address: UInt64) -> Int",
        "private func validateRange(address: UInt64, length: UInt64) -> UInt64",
        "guard !endOverflow, end <= memory.size",
        "let nextMappedRanges = mappedRangesAfterMapping(",
        "let nextMappedRanges = mappedRangesAfterRemoving(address..<end)",
        "mappedRanges = nextMappedRanges",
        "memory.mapTransaction(",
        "memory.resizeBreak(from: previousBreak, to: requested)",
        "memory.unmap(offset: address, length: size)",
        "result.insert(newRange, at: lower)",
        "result.append(range.lowerBound..<newRange.lowerBound)",
        "result.append(newRange.upperBound..<range.upperBound)",
        "result.append(range.lowerBound..<removed.lowerBound)",
        "result.append(removed.upperBound..<range.upperBound)",
        "for scalar in text.unicodeScalars",
        "chunkBytes + scalarByteCount > 4096",
        "logGuestOutput(bytes, descriptor: descriptor)",
        "private func logGuestOutput(_ bytes: Data, descriptor: UInt64)",
        "let stream = descriptor == 2 ? \"stderr\" : \"stdout\"",
        "log.write(\"[guest \\(stream)] \" + chunk)",
        "log.write(\"[guest \\(stream)] <\\(bytes.count) non-UTF8 bytes>\")",
        "guard arg4 == UInt64.max, arg5 == 0",
        "case 9:",
        "case 20:",
        "closedStandardDescriptorMask",
        "isStandardDescriptorClosed(_ descriptor: UInt64) -> Bool",
        "closedStandardDescriptorMask |= bit",
        "case 3:",

        "writeVector(descriptor: arg0, vectors: arg1, count: arg2)",
        "private func writeVector(descriptor: UInt64, vectors: UInt64, count: UInt64) -> UInt64",
        "maximumVectorCount: UInt64 = 1024",
        "maximumVectorBytes: UInt64 = 1_048_576",
        "logGuestOutput(output, descriptor: descriptor)",
        "case 12:",
        "case 228:",
        "case 318:",
        "getRandom(at: arg0, length: arg1, flags: arg2)",
        "flags & ~UInt64(0x7)",
        "var data = Data(count: count)",
        "data.withUnsafeMutableBytes",
        "generator.next().littleEndian",
        "MemoryLayout<UInt64>.size",
        "update(from: sourceBase.assumingMemoryBound(to: UInt8.self)",
        "private func mapAnonymous(",
        "private func setBreak(",
        "min(UInt64(999_999_999)",
        "min(UInt64(999_999)",

            ],
    ".github/workflows/build-qemu-runtime.yml": [
    ],
    ".github/workflows/validate-qemu-runtime-pr.yml": [
        "pull_request:",
        "branches: [main]",
        "uses: ./.github/workflows/build-qemu-runtime.yml",
        "rebuild_dependencies: false",
        "src/QEMU/**",
        "iSteam/JIT26Protocol.c",
    ],
    "scripts/tests/test_qemu_runtime_lookup.py": [
        "test_fallback_runtime_scan_filters_jit_and_tci_artifacts",
        "test_capability_probe_accepts_tci_when_jit_runtime_is_missing",
        "test_runtime_start_falls_back_to_tci_when_jit_is_unavailable",
    ],
    "scripts/tests/test_merge_qemu_runtime_variants.py": [
        "def test_rejects_substring_only_lifecycle_exports",
        "def test_rejects_substring_only_jit_callback_export",
        "def test_allows_unrelated_tci_symbol_with_jit_callback_prefix",
        "def test_rejects_multiline_runtime_manifest",
    ],
    "scripts/tests/test_qemu_build_patches.py": [
        "test_tci_build_uses_upstream_ios_se_scheme_and_product",
        "test_qemu_dependency_cache_version_matches_validation_contracts",
        "test_qemu_runtime_pr_workflow_calls_reusable_build",
        "test_qemu_stikjit_patcher_exports_required_runtime_symbols",
        "test_qemu_stikjit_allocator_patch_is_idempotent_and_fails_closed",
        "test_qemu_stikjit_patcher_updates_region_and_export_list_together",
        "test_qemu_workflow_probe_shell_syntax_and_steps_are_unique",
        "test_qemu_runtime_exports_are_matched_exactly",
        "test_qemu_workflow_ios_vm_map_probe_shell_syntax",
        "test_build_workflows_do_not_serialize_or_cancel_builds",
        "def test_windows_and_steamos_profiles_select_uefi_firmware",
        "test_link_verifier_rejects_missing_objc_stub_generation",
        "test_link_verifier_rejects_missing_libobjc",
        "test_qemu_runtime_packager_preserves_firmware_bundle_directories",
        "test_build_freshness_script_ignores_only_non_build_paths",
        "#include <mach/vm_map.h>",
        "#define mach_vm_remap vm_remap",
        "#define mach_vm_protect vm_protect",
        "#define mach_vm_deallocate vm_deallocate",
        "test_release_publication_is_serialized_and_skips_stale_main_builds",
        "test_qemu_xcode_minimum_accepts_later_major_versions",
        "test_qemu_runtime_packaging_scripts_have_valid_shell_syntax",
    ],
    "scripts/tests/test_jit_coordinator.py": [
        "test_stikdebug_availability_is_limited_to_physical_ios_devices",
        "targetEnvironment(simulator)",
        "targetEnvironment(macCatalyst)",
    ],
    "scripts/tests/test_guest_time_pair.py": [
        "func writeUInt64Pair",
        "isteam_guest_memory_write(native, offset, base, 16)",
        "memory.writeUInt64Pair(seconds, nanoseconds, offset: address)",
        "memory.writeUInt64Pair(seconds, microseconds, offset: address)",
    ],
    "scripts/tests/test_linux_getrandom_allocation.py": [
        "var data = Data(count: count)",
        "data.withUnsafeMutableBytes",
        "generator.next().littleEndian",
        "MemoryLayout<UInt64>.size",
        "update(from: sourceBase.assumingMemoryBound(to: UInt8.self)",
    ],
    "scripts/tests/test_linux_mapping_order.py": [
        "private func mappedRangesAfterMapping(",
        "private func mappedRangesAfterRemoving(",
        "private func firstMappedRangeEnding(after address: UInt64) -> Int",
        "let nextMappedRanges = mappedRangesAfterMapping(",
        "let nextMappedRanges = mappedRangesAfterRemoving(address..<end)",
        "result.insert(newRange, at: lower)",
        "result.append(range.lowerBound..<newRange.lowerBound)",
        "result.append(newRange.upperBound..<range.upperBound)",
        "result.append(range.lowerBound..<removed.lowerBound)",
        "result.append(removed.upperBound..<range.upperBound)",
        "mappedRanges = nextMappedRanges",
        "memory.mapTransaction(",
        "memory.unmap(offset: address, length: size)",
        "firstMappedRangeEnding(after: candidate)",
        "firstMappedRangeEnding(after: initialProgramBreak)",
    ],
    "scripts/tests/test_native_guest_memory.cpp": [
        "1ULL << 30",
        "isteam_guest_memory_allocated_pages",
        "constexpr uint64_t partialSize = pageSize + 17;",
        "isteam_guest_memory_zero(partial, pageSize, partialSize - pageSize)",
        "isteam_guest_memory_allocated_pages(partial) == 0",
    ],
    "scripts/tests/test_linux_syscall_dispatcher.swift": [
        "Linux x86-64 brk/mmap/munmap/mprotect/writev/time/random/identity and reset tests passed",
        "dispatcher.dispatch(number: 9999",
        "precondition(hintedAddress == 0x48000)",
        "precondition(fixedAddress == mapped)",
        "precondition(noReplaceValue == UInt64(bitPattern: Int64(-17)))",
        "precondition(protectionAfterUnmapValue == UInt64(bitPattern: Int64(-12)))",
        "precondition(badTimezoneValue == UInt64(bitPattern: Int64(-14)))",
        "precondition(invalidMmapFDValue == UInt64(bitPattern: Int64(-22)))",
        "let partialFixed = dispatcher.dispatch(number: 9, arguments: [0x47000, 8192, 3, 0x32, UInt64.max, 0])!",
        "precondition(memory.read(offset: 0x47000, length: 3) == Data([0, 0, 0]))",
        "precondition(memory.read(offset: 0x49000, length: 3) == Data([0x11, 0x22, 0x33]))",
        "let heapUnmap = dispatcher.dispatch(number: 11, arguments: [0x40000, 4096, 0, 0, 0, 0])!",
        "precondition(heapUnmapValue == 0)",
        "precondition(memory.read(offset: 0x40000, length: 2) == nil)",
        "precondition(memory.read(offset: 0x4B000, length: 3) == nil)",
        "precondition(memory.read(offset: mapped, length: 3) == Data([0, 0, 0]))",
        "precondition(memory.read(offset: mapped + 4096, length: 3) == Data([4, 5, 6]))",
        "let unmapRemainder = dispatcher.dispatch(number: 11, arguments: [mapped + 4096, 4096, 0, 0, 0, 0])!",
        "precondition(written == 12_000)",
        "let unicodeOutput = String(repeating: \"🙂\", count: 3_000)",
        "precondition(unicodeWritten == UInt64(unicodeOutput.utf8.count))",
        "Linux writev (syscall 20) concatenates bounded guest iovecs without",
        "number: 20, arg0: 1, arg1: 0x3F2000, arg2: 2",
        "precondition(outputLog.messages.last == \"[guest stdout] hello world\")",
        "precondition(outputLog.messages.last == \"[guest stderr] 🙂\")",
        "precondition(tooManyVectorsValue == UInt64(bitPattern: Int64(-22)))",
        "precondition(noVectorsValue == 0)",
    ],
    "src/Runtime/LinuxProcessStackBuilder.swift": [
        "struct ProgramHeaders",
        "static let stackSize = 1024 * 1024",
        "(3, programHeaders.address)",
        "(25, randomAddress)",
        "(31, argumentPointers[0])",
        "stackPointer & 0xF == 0",
    ],
    "src/Runtime/ELF64Loader.swift": [
        "($0.flags & 0x1) != 0",
        "loadable executable segment",
        "case unsupportedFileType(UInt16), unsupportedDynamicImage, programHeadersNotMapped, fileTooLarge",
        "version == 1",
        "if type == 2",
        "type == 3 || type == 7",
        "applyStaticPIERelocations",
        "let relaFileOffset = self.fileOffset(",
        "relocationType == 8",
        "relaEntrySize == 24",
        "alignment & (alignment - 1) == 0",
        "loadBias % alignment == 0",
        "dynamicSegment.virtualAddress",
        "orderedSegments",
        "loadedEntryPoint - $0.guestAddress < $0.fileSize",
        "programHeaderAddress",
        "programHeadersNotMapped",
        "fileSize <= UInt64(data.count) - fileOffset",
        "declaredProgramHeaderAddress",
        "mappedProgramHeaderAddress",
        "fileOffset == phoff",
        "fileSize >= programHeaderTableSize",
        "memorySize >= fileSize",
        "maximumGuestAddress",
    ],
    "src/Runtime/X86_64ALU.swift": [
        "static func add(",
        "static func and(",
        "static func or(",
        "static func multiply(",
        "static func shift(",
        "static func subtract(",
        "static func condition(",
        "static func makeFlags(",
        "static func condition(_ code: UInt8, flags: UInt64) -> Bool",
        "switch code & 0x0F",
        "default: return false",
        "static func add8(",
        "static func subtract8(",
        "static func and8(",
        "static func or8(",
        "static func xor8(",
        "private static func makeFlags8(",
        "case 0x0: return flags & overflow != 0",
        "case 0x1: return flags & overflow == 0",
        "case 0x2: return flags & carry != 0",
        "case 0x3: return flags & carry == 0",
        "case 0x4: return flags & zero != 0",
        "case 0x5: return flags & zero == 0",
        "case 0x6: return flags & (carry | zero) != 0",
        "case 0x7: return flags & (carry | zero) == 0",
        "case 0x8: return flags & sign != 0",
        "case 0x9: return flags & sign == 0",
        "case 0xA: return flags & parity != 0",
        "case 0xB: return flags & parity == 0",
        "case 0xC: return (flags & sign != 0) != (flags & overflow != 0)",
        "case 0xD: return (flags & sign != 0) == (flags & overflow != 0)",
        "case 0xE: return flags & zero != 0 || (flags & sign != 0) != (flags & overflow != 0)",
        "case 0xF: return flags & zero == 0 && (flags & sign != 0) == (flags & overflow != 0)",
    ],
        "src/Runtime/X86_64Interpreter.swift": [
        "func setInitialStackPointer(_ pointer: UInt64) throws",
        "func configureLinuxProcess(programBreak: UInt64, stackBase: UInt64) throws",
        "registers[4] = pointer",
        "case 0xB8...0xBF: // MOV r32, imm32 or MOV r64, imm64",
        "registers[index] = UInt64(immediate)",
        "let width64 = rex & 0x08 != 0",
        "X86_64ALU.add(lhs, rhs",
        "X86_64ALU.subtract(lhs, rawImmediate",
        "X86_64ALU.multiply(",
        "X86_64ALU.condition(opcode & 0x0F",
        "case 0x89, 0x8B:",
        "case 0x8D:",
        "case 0xC7:",
        "case 0xF7:",
        "case 0xC1, 0xD1, 0xD3:",
        "case 0x63:",
        "case 0x69, 0x6B:",
        "second == 0xAF",
        "second == 0xB6 || second == 0xBE",
        "second == 0xB7 || second == 0xBF",
        "case 0xFF:",
        "group == 0 || group == 1",
        "case 0xC9:",
        "let framePointer = registers[5]",
        "let (nextStackPointer, overflow) = framePointer.addingReportingOverflow(8)",
        "case 0xC2:",
        "case 0x09, 0x0B:",
        "case 0x29, 0x2B, 0x39, 0x3B:",
        "case 0x68: // PUSH sign-extended imm32",
        "case 0x6A: // PUSH sign-extended imm8",
        "private func fetchUInt16() -> UInt16?",
        "private func decodeRM(_ modrm: UInt8, rex: UInt8, trailingImmediateBytes: UInt8 = 0, includeSegmentBase: Bool = true)",
        "let addressBase = usesRIPRelative ? rip &+ UInt64(trailingImmediateBytes) : base",
        "private func readByteOperand(_ operand: Operand, modrm: UInt8, rex: UInt8) -> UInt8?",
        "private func readWordOperand(_ operand: Operand) -> UInt16?",
        "usesRIPRelative",
        "let segmentedAddress = address &+ (includeSegmentBase ? activeSegmentBase : 0)",
        "let scale = UInt64(1) << ((sib >> 6) & 3)",
        "registers[index] = width64 ? value : UInt64(UInt32(truncatingIfNeeded: value))",
        "let nextStackPointer = registers[4] - 8",
        "memory.writeUInt64(registers[index], offset: nextStackPointer)",
        "if index == 4",
        "registers[4] = value",
        "guard let adjustment = fetchUInt16() else",
        "return .memoryFault(address: operandAddress(decoded.operand))",
        "case 0xC3:",
        "let takeBranch = X86_64ALU.condition(opcode & 0x0F, flags: flags)",
        "let takeBranch = X86_64ALU.condition(second & 0x0F, flags: flags)",
        "case 0xB0...0xB7: // MOV r8, imm8",
        "case 0x88, 0x8A: // MOV r/m8, r8 and MOV r8, r/m8",
        "case 0xC6: // MOV r/m8, imm8",
        "private func readByteRegister(_ encodedIndex: Int, rex: UInt8) -> UInt8",
        "private func writeByteRegister(_ value: UInt8, encodedIndex: Int, rex: UInt8)",
        "private func writeByteOperand(_ value: UInt8, to operand: Operand, modrm: UInt8, rex: UInt8) -> Bool",
        "guard ((modrm >> 3) & 7) == 0 else {",
        "case 0x00, 0x02, 0x08, 0x0A, 0x20, 0x22, 0x28, 0x2A, 0x30, 0x32, 0x38, 0x3A, 0x84:",
        "X86_64ALU.add8(lhs, rhs, flags: flags)",
        "X86_64ALU.subtract8(lhs, rhs, flags: flags)",
        "case 0x80: // ADD/OR/AND/SUB/XOR/CMP r/m8, imm8",
        "case 0xA8: // TEST AL, imm8",
        "X86_64ALU.add8(lhs, immediate, flags: flags)",
        "case 0x70...0x7F:",
        "second >= 0x80 && second <= 0x8F",
        "case 0xF6: // TEST, NOT and NEG r/m8",
        "case 0xFE: // INC and DEC r/m8",
        "second >= 0x40 && second <= 0x4F",
        "second >= 0x90 && second <= 0x9F",
        "second == 0x1F",
        "guard let decoded = decodeRM(modrm, rex: rex) else {",
        "guard let _ = decodeRM(modrm, rex: rex) else {",
        "return .memoryFault(address: rip)",

        "private var fsBase: UInt64 = 0",
        "private var gsBase: UInt64 = 0",
        "activeSegmentBase = fsBase",
        "activeSegmentBase = gsBase",
        "dispatchArchPrctl(operation: registers[7], argument: registers[6])",
        "private func dispatchArchPrctl(operation: UInt64, argument: UInt64) -> UInt64",
        "includeSegmentBase: Bool = true",
        "if number == 158",
        "registers[1] = rip",
        "registers[11] = flags",
    ],
    "scripts/tests/test_static_elf_execution.swift": [
        "KENRAN_BUTO_AOT_TESTS",
        "aotExecutor.refreshAvailability()",
        "aotExecutor.blocksExecuted > 0",
        "unsupported_LEA_and_syscall_side_exits=verified",
        "Static ET_EXEC execution and static PIE load-bias/relative-relocation checks passed",
        "hello from static ELF",
        "func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool",
        "interpreter.run(maxInstructions: 64)",
        "func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool",
        "enum GuestMemoryTransactionResult: Int32",
        "func hasMappedPages(offset: UInt64, length: UInt64) -> Bool",
        "func mapTransaction(offset: UInt64, length: UInt64, permissions: UInt8,",
        "func resizeBreak(from oldBreak: UInt64, to newBreak: UInt64) -> GuestMemoryTransactionResult",
    ],
    "scripts/tests/test_linux_process_stack.swift": [
        "auxiliary[3] == 0x40040",
        "auxiliary[25] == result.randomAddress",
        "Image/stack overlap should fail.",
    ],
    "scripts/tests/test_x86_64_interpreter.swift": [
        "stackPointerInterpreter.setInitialStackPointer(0x100)",
        "precondition(arithmetic.registerValue(3) == 2)",
        "precondition(signed.registerValue(3) == 2)",
        "precondition(signed.conditionFlags & X86_64ALU.sign != 0)",
        "precondition(ripRelativeMemory.readUInt32(offset: 0x80) == 0x12345678)",
        "precondition(sibMemory.readUInt64(offset: 0x108) == 0x1122334455667788)",
        "precondition(lea.registerValue(3) == 128)",
        "precondition(leave.registerValue(4) == 0x200)",
        "precondition(indirect.registerValue(3) == 0x42)",
        "precondition(retImmediate.registerValue(4) == 0x110)",
        "precondition(ret.registerValue(4) == 64)",
        "retMemory.write(Data([0x0F, 0x0B]), offset: 8)",
        "syscallInterpreter.configureLinuxProcess(programBreak: 0x1000, stackBase: 0x3F0000)",
        "precondition(orInterpreter.registerValue(0) == 3)",
        "precondition(c7.registerValue(0) == 0x12345678)",
        "precondition(movsxd.registerValue(0) == UInt64.max)",
        "precondition(imul.registerValue(0) == UInt64.max - 5)",
        "precondition(imulOverflow.conditionFlags & X86_64ALU.overflow != 0)",
        "precondition(imulImmediate.registerValue(0) == 0xFFFF_FFF8)",
        "precondition(movExtend.registerValue(1) == 0xFFFF_F234)",
        "precondition(byteExtend.registerValue(1) == 0xFFFF_FFF2)",
        "precondition(highByte.registerValue(0) == 24)",
        "precondition(test64.conditionFlags & X86_64ALU.zero == 0)",
        "precondition(unsupportedF7Exit == .unsupportedInstruction(address: 0))",
        "0x0F, 0xBE, 0x0D, 0x12, 0x00, 0x00, 0x00",
        "precondition(shiftLeft.registerValue(0) == 0)",
        "precondition(shiftRight.registerValue(0) == 0x4000_0000)",
        "precondition(shiftArithmetic.registerValue(0) == 0xC000_0000)",
        "precondition(shiftCL.registerValue(0) == 4)",
        "precondition(testImmediate.registerValue(0) == 0x8000_0000)",
        "precondition(notInterpreter.registerValue(0) == 0xEDCB_A987)",
        "precondition(negInterpreter.registerValue(0) == 0xFFFF_FFFF)",
        "precondition(incInterpreter.registerValue(0) == 0)",
        "precondition(decInterpreter.registerValue(0) == 0xFFFF_FFFF)",
        "precondition(ripC7Memory.readUInt32(offset: 0x20) == 0x12345678)",
        "precondition(ripTest.conditionFlags & X86_64ALU.zero == 0)",
        "precondition(ripIMUL.registerValue(0) == 0xFFFF_FFF8)",
        "precondition(ripAddMemory.readUInt32(offset: 0x20) == 7)",
        "precondition(truncatedShortExit == .memoryFault(address: 1))",
        "precondition(truncatedNearExit == .memoryFault(address: 2))",
        "precondition(memoryArithmetic.registerValue(3) == 5)",
        "precondition(memoryArithmeticMemory.readUInt32(offset: 0x80) == 5)",
        "precondition(lea32.registerValue(3) == 0x108)",
        "precondition(truncatedRetExit == .memoryFault(address: 1))",
        "precondition(indirectFaultExit == .memoryFault(address: 0x1006))",
        "precondition(zeroShift.registerValue(0) == 1)",
        "precondition(zeroShift.conditionFlags & X86_64ALU.carry != 0)",
        "func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool",
        "precondition(byteImmediate.registerValue(0) == 0x1234_AA78)",
        "precondition(byteStoreMemory.readByte(offset: 0x20) == 0x56)",
        "precondition(byteLoad.registerValue(0) == 0xAB)",
        "precondition(byteImmediateStoreMemory.readByte(offset: 0x20) == 0x7F)",
        "precondition(rexByte.registerValue(8) == 0x7F)",
        "precondition(unsupportedC6Exit == .unsupportedInstruction(address: 0))",
        "precondition(byteAdd.registerValue(0) == 0)",
        "precondition(byteSubtract.registerValue(0) == 0xFF)",
        "precondition(byteTest.conditionFlags & X86_64ALU.zero == 0)",
        "precondition(byteCompare.conditionFlags & X86_64ALU.carry != 0)",
        "precondition(byteImmediateAdd.registerValue(0) == 0x80)",
        "precondition(byteImmediateAdd.conditionFlags & X86_64ALU.overflow != 0)",
        "precondition(byteImmediateCompare.registerValue(0) == 0xFF)",
        "precondition(byteTestImmediate.conditionFlags & X86_64ALU.zero != 0)",
        "precondition(unsupportedByteImmediateExit == .unsupportedInstruction(address: 0))",
        "Data([0x48, 0x0F, 0xBF, 0x05, 0x78, 0x00, 0x00, 0x00, 0xF4])",
        "precondition(signExtend.registerValue(0) == 0xFFFFFFFFFFFF80FF)",
        "let shortParityMemory = GuestMemory(size: 64)",
        "let nearParityMemory = GuestMemory(size: 64)",
        "for combination in 0..<32",
        "let byteFlagMemory = GuestMemory(size: 64)",
        "let conditionalMoveMemory = GuestMemory(size: 64)",
        "let multiByteNopMemory = GuestMemory(size: 64)",
        "let truncatedByteIncMemory = GuestMemory(size: 2)",
        "let truncatedMultiByteNopMemory = GuestMemory(size: 3)",

        "let fsSegmentMemory = GuestMemory(size: 0x2000)",
        "let relativeCallFaultMemory = GuestMemory(size: 64)",
        "precondition(relativeCallFault.registerValue(4) == 72)",
        "let indirectCallFaultMemory = GuestMemory(size: 64)",
        "precondition(indirectCallFault.registerValue(4) == 72)",
        "let indirectPushFaultMemory = GuestMemory(size: 64)",
        "precondition(indirectPushFault.registerValue(4) == 72)",
        "let leaveFaultMemory = GuestMemory(size: 64)",
        "precondition(leaveFault.registerValue(4) == 56)",
        "precondition(fsSegmentMemory.readByte(offset: 0x1020) == 0x5A)",
        "precondition(fsSegmentMemory.readUInt64(offset: 0x1080) == 0x1000)",
        "precondition(syscallInterpreter.registerValue(1) == 21)",
        "precondition(syscallInterpreter.registerValue(11) == 0x46)",
        "enum GuestMemoryTransactionResult: Int32",
        "func hasMappedPages(offset: UInt64, length: UInt64) -> Bool",
        "func mapTransaction(offset: UInt64, length: UInt64, permissions: UInt8,",
        "func protect(offset: UInt64, length: UInt64, permissions: UInt8) -> Bool",
        "func unmap(offset: UInt64, length: UInt64) -> Bool",
        "func resizeBreak(from oldBreak: UInt64, to newBreak: UInt64) -> GuestMemoryTransactionResult",
    ],
    "src/QEMU/QEMUCommandBuilder.swift": [
        "firmwareVariables: URL? = nil",
        "\"-vnc\", \"127.0.0.1:0\"",
        "let gpu = configuration.bootWindows ? \"VGA\" : configuration.gpu.rawValue",
        "let networkDevice = configuration.bootWindows ? \"e1000e\" : \"virtio-net-pci\"",
        "\"-device\", \"ich9-ahci,id=sata0\"",
        "\"-monitor\", \"none\", \"-serial\", \"none\", \"-parallel\", \"none\"",
        "\"ide-hd,drive=isteam-disk,bus=sata0.0,bootindex=1\"",
        "\"ide-cd,drive=isteam-cdrom,bus=sata0.1,bootindex=1\"",
        "\"vhdxfile\"",
        "\"conectix\"",
        "case vdi",
        "case vpc",
        "bootFromISO ? \"order=d,menu=on,strict=off\" : \"order=c,menu=on,strict=off\"",
        "QEMUDiskImageFormat.detect(at: diskImage)",
        "Self.escapeDriveValue(diskImage.path)",
        "replacingOccurrences(of: \",\", with: \",,\")",
        "tcg,tb-size=128,split-wx=on",
        "configuration.accelerator == .jit ? \"tcg,tb-size=128,split-wx=on\" : \"tcg\"",
    ],
    "src/Core/VMEngine.swift": [
        "var onStateChange: ((State) -> Void)?",
        "private func setState(_ newState: State)",
        "startupDeadline = .now() + 60",
        "within 60 seconds",
        "backend = candidate",
        "if backend?.stop() ?? true",
    ],
    "src/QEMU/QEMUNativeRuntime.swift": [
        "let requestedJIT = configuration.accelerator == .jit",
        "var runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)",
        "isteam_qemu_start",
        "findUEFIFirmwarePair(in directory: URL)",
        "findUEFIVariables(matching firmware: URL, in directory: URL)",
        "OVMF_CODE.fd",
        "OVMF_VARS.fd",
        "OVMF_CODE_4M.fd",
        "OVMF_VARS_4M.fd",
        "edk2-x86_64-code.fd",
        "edk2-x86_64-vars.fd",
        "makeWritableUEFIVariables(from template: URL, for configurationID: UUID)",
        "resolvedDirectory.path.hasPrefix(supportRoot.path + \"/\")",
        "destinationOfSymbolicLink(atPath: destination.path)",
        "destinationValues?.isRegularFile == true",
        "destinationValues?.isDirectory == true",
        "private static func containedRegularFile(named names: [String], in directory: URL) -> URL?",
        "resolvingSymlinksInPath().standardizedFileURL",
        "resolved.path.hasPrefix(prefix)",
        "resourceValues(forKeys: [.isRegularFileKey])",
        "values?.isRegularFile == true",
        "firmwareVariables: selectedFirmwareVariables",
        "startAccessingSecurityScopedResource()",
        "configuration.requiresUEFI",
        "private var sessionGeneration: UInt64 = 0",
        "guard isPaused else",
        "advanceSessionGeneration()",
        "func reset(sessionGeneration expected: UInt64) -> Bool",
        "func stop(sessionGeneration expected: UInt64) -> Bool",
        "guard expected == sessionGeneration else { return true }",
        "func isRunning(sessionGeneration expected: UInt64?) -> Bool",
        "func isActive(sessionGeneration expected: UInt64?) -> Bool",
        "func lastError(sessionGeneration expected: UInt64?) -> String?",
    ],
    "src/QEMU/QEMUBackend.swift": [
        "private var sessionGeneration: UInt64?",
        "sessionGeneration = try runtime.start",
        "runtime.stop(sessionGeneration: sessionGeneration)",
        "runtime.reset(sessionGeneration: sessionGeneration)",
        "runtime.isRunning(sessionGeneration: sessionGeneration)",
        "runtime.isActive(sessionGeneration: sessionGeneration)",
        "runtime.lastError(sessionGeneration: sessionGeneration)",
    ],
    "iSteam/QEMUNativeBridge.c": [
        "bool isteam_qemu_validate_library(",
        "dlopen(library_path, RTLD_NOW | RTLD_LOCAL)",
        "char *argument_storage = malloc(total_argument_bytes);",
        "copied_argv[i] = argument_storage + argument_offset;",
        "memcpy(copied_argv[i], argv[i], argument_length + 1u)",
        'dlsym(library, "qemu_init")',
        "typedef void (*qemu_init_fn)(int, char **);",
        "typedef int (*qemu_main_loop_fn)(void);",
        "typedef void (*qemu_cleanup_fn)(int);",
        "#define ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI 5",
        "g_qemu_init(g_argc, g_argv);",
        "int qemu_exit_status = g_qemu_main_loop();",
        "if (g_qemu_cleanup) g_qemu_cleanup(qemu_exit_status);",
        'dlsym(library, "qemu_main_loop")',
        'dlsym(library, "qemu_cleanup")',
        'dlsym(library, "qemu_system_shutdown_request")',
        'dlsym(library, "isteam_qemu_set_jit_callbacks")',
        "set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);",
        "static bool g_starting = false;",
        "static _Thread_local char error_copy",
        "ISTEAM_QEMU_MAX_ARGUMENTS 4096",
        "ISTEAM_QEMU_MAX_ARGUMENT_BYTES",
        "ISTEAM_QEMU_MAX_TOTAL_ARGUMENT_BYTES",
        "strnlen(argv[i], ISTEAM_QEMU_MAX_ARGUMENT_BYTES + 1u)",
        "error_buffer && error_capacity > 0",
        "MSG_NOSIGNAL",
    ],
    "scripts/tests/fake_qemu_runtime.c": [
        "#ifndef FAKE_QEMU_NO_JIT_CALLBACK",
        "void isteam_qemu_set_jit_callbacks",
        "fake_qemu_jit_callbacks_installed",
        "void qemu_init(int argc, char *argv[])",
        "poison_nonzero_return_register();",
        "int qemu_main_loop(void)",
        "return 37;",
        "void qemu_cleanup(int status)",
        "atomic_store(&cleanup_status, status);",
        "atomic_store(&shutdown_cause, cause);",
    ],
    "scripts/package-utm-qemu-runtime.sh": [
        " _?isteam_qemu_set_jit_callbacks$",
        "isteam_qemu_set_jit_callbacks",
        "MODE_DIRECTORY",
        "QEMU-TCI.framework",
        "vtool -show-build",
        "platform[[:space:]]+IOS([[:space:]]|$)",
        "dynamically linked shared library",
        'source_dir="$(dirname "$firmware_file")"',
        '[ "$source_dir" = "$data_dir" ] && continue',
        'target_dir="$OUT/QEMU/firmware/$relative_dir"',
        'cp "$firmware_file" "$target_dir/"',
        'bash "$SCRIPT_DIR/validate-qemu-runtime.sh" "$OUT/$runtime_relative" "$MODE"',
    ],
    "scripts/package-utm-qemu-tci-runtime.sh": [
        'APP="$ARCHIVE_ROOT/Products/Applications/UTM SE.app"',
        "UTM SE.app missing from archive",
        "has_jit_callbacks=false",
        "QEMU-TCI.framework",
        'bash "$SCRIPT_DIR/validate-qemu-runtime.sh" "$OUT/$runtime_relative" tci',
        "No UTM QEMU TCI dynamic library with lifecycle/shutdown exports and without the StikJIT callback export was found.",
        "runtime-library-path.txt",
    ],
    "scripts/merge-qemu-runtime-variants.sh": [
        "required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)",
        "manifest_lines=\"$(awk 'END { print NR }' \"$package/QEMU/runtime-library-path.txt\")\"",
        '[[ "$manifest_lines" -eq 1 ]]',
        'grep -Eq "[[:space:]]_?${symbol}$" "$JIT_DIR/exports.txt" || fail "JIT artifact is missing required export: $symbol"',
        'grep -Eq "[[:space:]]_?${symbol}$" "$TCI_DIR/exports.txt" || fail "TCI artifact is missing required export: $symbol"',
        "grep -Eq '[[:space:]]_?isteam_qemu_set_jit_callbacks$' \"$JIT_DIR/exports.txt\"",
        "if grep -Eq '[[:space:]]_?isteam_qemu_set_jit_callbacks$' \"$TCI_DIR/exports.txt\"; then",
        'mkdir -p "$TEMP_OUT/Frameworks" "$TEMP_OUT/QEMU/JIT" "$TEMP_OUT/QEMU/TCI"',
        'cp -a "$JIT_DIR/QEMU/." "$TEMP_OUT/QEMU/JIT/"',
        'cp -a "$TCI_DIR/QEMU/." "$TEMP_OUT/QEMU/TCI/"',
    ],
    "scripts/validate-qemu-runtime.sh": [
        "for tool in file lipo nm codesign vtool; do",
        "required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)",
        'if [[ "$mode" == "jit" ]]; then',
        "required_symbols+=(isteam_qemu_set_jit_callbacks)",
        'for symbol in "${required_symbols[@]}"; do',
        "codesign --verify --strict",
        "vtool -show-build",
        "platform[[:space:]]+IOS([[:space:]]|$)",
        "dynamically linked shared library",
    ],
    "runtime/qemu/README.md": [
        "QEMURuntimeStatus.inspect(requiresJIT:)",
        "qemu_system_shutdown_request",
        "isteam_qemu_set_jit_callbacks",
        "physical iOS 17.4",
        "Physical-device runtime startup",
    ],
    "src/QEMU/QEMURuntimeStatus.swift": [
        "bundleRoot = bundle.bundleURL.resolvingSymlinksInPath()",
        "bundlePrefix",
        "resolvingSymlinksInPath()",
        "isteam_qemu_validate_library(",
        "validateLoadableLibrary(libraryURL, dataDirectory: dataDirectory,",
        "requiresJIT: requiresJIT",
        "QEMU-TCI.framework/QEMU",
        "The no-JIT QEMU TCI runtime is not packaged.",
        "The bundled QEMU library failed its load/export validation.",
    ],
    "src/Runtime/RuntimeCapabilityRegistry.swift": [
        "enum RuntimeCapabilityLevel: String, CaseIterable",
        "case notProbed",
        "static let current = inspect(probeQEMU: false)",
        "level: .loadable",
        "level == .operational",
        "if probeQEMU",
        "QEMURuntimeStatus.inspect(bundle: bundle, requiresJIT: true)",
    ],
    "src/Steam/GameLauncher.swift": [
        "RuntimeCapabilityRegistry.current",
        "capabilities.backendAvailability",
        '"[runtime-capability] "',
        "WindowsPELoader().load(executable)",
        "directoryValues?.isDirectory == true",
        "format == .windowsPE || format == .linuxELF",
        "LinuxELFRuntime.shared.launch(",
        "machine.loadELFImage(at: executable, arguments: arguments)",
        "machine?.requestStop()",
        "queue.async { machine.stop() }",
        "machine.runBatch(maxInstructions: Self.batchInstructionLimit)",
        "queue.asyncAfter",
        "private static let guestMemorySize: UInt64 = 1024 * 1024 * 1024",
        "completion: ((Result<GuestCPUExit, Error>) -> Void)? = nil",
    ],
    "src/Core/VMSaveSlotStore.swift": [
        "maximumMetadataBytes = 1 * 1024 * 1024",
        "values.isRegularFile == true",
        "data.count <= maximumMetadataBytes",
        "bookmark.count <= maximumMetadataBytes / 2",
        "legacySafeFilename(_ name: String)",
        "safeFilename(_ name: String)",
        "isValidName(_ name: String)",
        "configuration.name == expectedName",
        "startAccessingSecurityScopedResource()",
    ],
    "src/Runtime/ExecutionBackendRouter.swift": [
        "antiCheatAssessment == .notRequested",
        "return dynamicTranslationBackend != nil",
        "Cached AOT translations require a dynamic engine",
        "case .linuxARM32ELF:",
        "required = [.linuxSyscallABI]",
    ],
    "scripts/tests/test_execution_backend_router.swift": [
        "let translatorOnly = RuntimeBackendAvailability(installed: [.a32rt])",
        "translatorOnlyPlan.missingRequiredLayers == [.linuxSyscallABI]",
        "!translatorOnlyPlan.isExecutableWithInstalledBackends",
        "withABIPlan.isExecutableWithInstalledBackends",
        "fullSystemPlan.fullSystemFallback == .qemuTCG",
    ],
    "src/Core/RuntimeSettings.swift": [
        "?? .linuxVM",
        "return stored.isAvailable ? stored : .automatic",
        "case qemuInterpreter = \"QEMU TCI (no JIT)\"",
        "TCG with a 128 MiB translation-block cache and split-WX; requires physical iOS 26+ and a supported StikDebug JIT session.",
        "case .automatic, .qemuJIT, .qemuInterpreter: return true",
        "Uses QEMU's threaded TCI interpreter without JIT entitlements or executable-memory support. Slower than JIT; startup validates the bundled device-arm64 TCI runtime.",
    ],
    "src/Core/VMConfiguration.swift": [
        "static var defaultAccelerator: Accelerator",
        "case .automatic, .qemuJIT: return .jit",
        "case .qemuInterpreter, .hypervisor: return .tcg",
        "var bootUEFI: Bool? = nil",
        "var requiresUEFI: Bool",
        "bootWindows: true, bootUEFI: true",
        "bootWindows: false, bootUEFI: false",
        "bootWindows: false, bootUEFI: true",
    ],
    "src/Core/VMConfigurationValidation.swift": [
        "guard architecture == .x86_64",
        "case .unsupportedArchitecture(let architecture)",
        "if gpu != .virtioGPU",
        "case .unsupportedGPU(let gpu)",
        "framebufferBytes <= 64 * 1024 * 1024",
        "fit the 64 MiB framebuffer limit",
    ],
    "src/Display/TouchStickMath.swift": [
        "struct TouchStickMovement",
        "private let inverseRadius: CGFloat",
        "inverseRadius = 1 / value",
        "func transform(dx: CGFloat, dy: CGFloat) -> TouchStickMovement",
        "offsetX * inverseRadius",
    ],
    "scripts/tests/test_touch_stick_math.swift": [
        "TouchStickMath(radius: radius)",
        "checked += 1",
        "Touch stick transform equivalence passed",
    ],
    "scripts/tests/test_qemu_native_bridge_jit_validation.py": [
        "def test_qemu_main_loop_and_cleanup_use_upstream_status_abi(self):",
        "typedef int (*qemu_main_loop_fn)(void);",
        "typedef void (*qemu_cleanup_fn)(int);",
        "int qemu_exit_status = g_qemu_main_loop();",
        "if (g_qemu_cleanup) g_qemu_cleanup(qemu_exit_status);",
        "return 37;",
        "def test_qemu_arguments_use_one_contiguous_allocation(self):",
        "def test_qemu_init_uses_the_upstream_void_abi(self):",
        "typedef void (*qemu_init_fn)(int, char **);",
        "g_qemu_init(g_argc, g_argv);",
        "void qemu_init(int argc, char *argv[])",
        "poison_nonzero_return_register();",
        "self.assertIn(\"malloc(total_argument_bytes)\", start)",
        "def test_jit_callback_export_is_required_only_for_jit_runtime(self):",
        "typedef void (*qemu_set_jit_callbacks_fn)",
        "set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);",
    ],
    "scripts/tests/test_qemu_native_bridge.c": [
        "tooManyArguments[4097]",
        "oversizedArgument",
        "QEMU arguments exceed the configured size limits",
        'fake_qemu_cleanup_status") == 37',
        'fake_qemu_shutdown_cause") == 5',
    ],
    "src/Runtime/GuestBlockDevice.swift": [
        "case invalidGeometry, outOfBounds, readOnly, shortRead",
        "UInt64(size) % sectorSize == 0",
        "static let maximumTransferBytes = 16 * 1024 * 1024",
        "byteCount <= UInt64(Self.maximumTransferBytes)",
        "data.count <= Self.maximumTransferBytes",
        "startAccessingSecurityScopedResource()",
        "FileHandle(forUpdating: url)",
        "handle.synchronize()",
    ],
    "scripts/tests/test_elf_loader_program_headers.swift": [
        "Mismatched PT_PHDR virtual address was accepted",
        "GuestMemory(size: 8 * 1024 * 1024)",
        "Mismatched PT_PHDR file offset was accepted",
        "Truncated PT_PHDR table size was accepted",
        "Truncated PT_PHDR memory size was accepted",
    ],
    "src/Runtime/GuestMemory.swift": [
        "private let native: OpaquePointer?",
        "var isAvailable: Bool",
        "func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool",
        "isteam_guest_memory_write(native, offset, base, 16)",
        "func writeByte(_ value: UInt8, offset: UInt64) -> Bool",
    ],
    "src/Runtime/GuestMachine.swift": [
        "func loadELFImage(at url: URL, arguments: [String] = [], environment: [String: String] = [:])",
        "LinuxProcessStackBuilder().build(",
        "cpu.setInitialStackPointer(stack.stackPointer)",
        "cpu.configureLinuxProcess(programBreak: programBreak, stackBase: stack.stackBase)",
        "initialStackPointer",
        "loadedEntryPoint",
        "backend.reset(entryPoint: loadedEntryPoint)",
        "try currentCPU.reset(entryPoint: loadedEntryPoint)",
        "backend.setInitialStackPointer(initialStackPointer)",
        "maximumGuestBytes: UInt64 = 16 * 1024 * 1024 * 1024",
        "guard self.memory.isAvailable",
        "case memoryUnavailable",
        "private(set) var initializationError: GuestEngineError?",
        "let error = GuestEngineError.backendNotInstalled(configuration.architecture)",
        "self.initializationError = error",
        "state = .failed(error.localizedDescription)",
        "throw error",
        "initializationError = nil",
        "withExecutionLock",
        "hasLoadedImage",
        "activeCPULock",
        "func requestStop()",
        "requestActiveStop",
        "A caller can pause between bounded execution batches as well.",
        "state == .configured",
        "executionLock.lock()",
        "memory.clear()",
        "_ = try? cpu.reset(entryPoint: 0)",
    ],
    "src/Steam/GameArtworkStore.swift": [
        "CGImageSourceGetCount(image) <= 200",
        "width <= 8192, height <= 8192",
        "width <= (16 * 1024 * 1024) / height",
        "private let directory: URL",
        "private func ensureDirectory() throws",
        "try ensureDirectory()",
        "CGImageSourceCreateThumbnailAtIndex(image, 0, thumbnailOptions) != nil",
        "kCGImageSourceThumbnailMaxPixelSize: 512",
        "kCGImageSourceShouldCacheImmediately: true",
        "org.webmproject.webp",
    ],
    "src/Runtime/ExternalDriveStore.swift": [
        "maximumBytes: Int? = 64 * 1024 * 1024",
        "values.isRegularFile == true",
        "CocoaError(.fileReadTooLarge)",
        "replaceItemAt(destination, withItemAt: temporary)",
        "guard values.isRegularFile == true",
    ],
    "src/Windows/GameCompatibilityDatabase.swift": [
        "private func loadRecords() throws",
        "DatabaseError.corruptDatabase",
        "fileSize <= 5 * 1024 * 1024",
    ],
    "iSteam/GameStore.swift": [
        "func validate() -> Bool",
        "var isReadable: Bool",
        "games.count <= 10_000",
        "GameRuntimeProfileStore.shared.removeProfile(for: id)",
    ],
    "src/Steam/GameLibraryQuery.swift": [
        "for game in games",
        "for rawTag in game.tags",
        "let key = tag.folding(options: .caseInsensitive, locale: .current)",
        "if seen.insert(key).inserted",
        "tags.append(tag)",
    ],
    "src/Steam/GameRuntimeProfile.swift": [
        "var hasUnreadableProfiles: Bool",
        "private func profileFiles() throws -> [URL]",
        "guard let files = try? profileFiles() else { return true }",
        "profile.validate()",
        "launchArguments.count <= 256",
        "environment.count <= 128",
        "compatibilityNotes.utf8.count <= 16_384",
        "environment.keys.allSatisfy",
        "1024 * 1024",
        "corruptStoredProfile",
        "UInt64(preferredResolutionWidth) * UInt64(preferredResolutionHeight) * 4 <= 64 * 1024 * 1024",
        "UUID(uuidString: file.deletingPathExtension().lastPathComponent) == profile.gameID",
        "private func readProfile(at file: URL)",
    ],
    "src/Display/VMDisplayViewController.swift": [
        "source: \"keyboard\"",
        "source: \"touchgamepad\"",
        "x, y, source in self?.vncClient.setMovement",
        "private let configuration: VMConfiguration",
        "self.configuration = configuration",
        "gamepad?.releaseAllButtons()",
        "vncClient.start()",
        "engine.onStateChange",
        "configuration.displayWidth, height: configuration.displayHeight",
        "configuration.displayFPS",
        "vncClient.onFrame",
        "guest • \\(self.configuration.displayWidth)",
        "vncClient.onStatus",
        "engine.start(diskImage: diskImage, writableDiskImage: writableDiskImage)",
        "MotionInputManager.shared.stop()",
        "motion.onLookDelta =",
        "VRSettings.shared.pointerLockEnabled",
        "vncClient.movePointer(dx: Float(yaw), dy: Float(pitch))",
        "ControllerInputManager.shared.stop()",
        "vncClient.stop()",
        "releaseGuestInputs()",
    ],
    "src/Runtime/HostDeviceBridge.swift": [
        "resolvingSymlinksInPath()",
        "let requestedRoot = sharedDirectoryURL.standardizedFileURL",
        "let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL",
        "guard resolvedRoot.path == root.path else",
        "withAccess(to: source)",
        "maximumInMemoryTransferBytes = 64 * 1024 * 1024",
        "case fileTooLarge",
        "case fileChangedDuringTransfer",
        "copiedBytes == sourceSize",
        "data.count == size",
    ],
    "src/Steam/DroidDeckFeatureServices.swift": [
        "NSFileCoordinator()",
        "writingItemAt: destination",
        "guard game.validate(), seen.insert(game.id).inserted",
    ],
    "src/GPU/MetalGPUBackend.swift": [
        "view.framebufferOnly = false",
        "view.autoResizeDrawable = false",
        "let drawableSize = CGSize(width: width, height: height)",
        "if self.view.drawableSize != drawableSize { self.view.drawableSize = drawableSize }",
        "displayUpdateScheduled = false",
        "guard shouldSchedule else { return }",
        "source.texture.width == drawable.texture.width",
        "source.texture.height == drawable.texture.height",
        "framebufferSlots.removeAll(keepingCapacity: false)",
    ],
    "iSteam/QEMUNativeBridge.h": [
        "#define ISTEAM_NONNULL _Nonnull",
        "#define ISTEAM_NONNULL",
    ],
    "iSteam/Box64Bridge.c": [
        "dlsym(RTLD_DEFAULT, \"box64_library_main\")",
        "g_box64_working_directory_lock",
        "fchdir(originalDirectory)",
    ],
    "iSteam/JIT26Protocol.c": [
        "#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR",
        "iSteamJITIsSupported",
        "IORegistryEntryFromPath(",
        '"IODeviceTree:/chosen/memory-map"',
        "ISTEAM_JIT_PROTOCOL_UNKNOWN",
        "iSteamJITGetProtocolMode",
    ],
    "src/Core/EmulationLog.swift": [
        "private let maximumLogBytes: UInt64 = 5 * 1024 * 1024",
        "String(decoding: message.utf8.prefix(8192), as: UTF8.self)",
        "guard byteCount <= maximumLogBytes, openLogIfNeeded() else { return }",
        "currentLogBytes <= maximumLogBytes - byteCount",
        "emulation.previous.log",
    ],
    "src/Display/ControllerInputManager.swift": [
        "GCController.stopWirelessControllerDiscovery()",
        "var onMove: ((Float, Float, String) -> Void)?",
        "var onButton: ((String, Bool, String) -> Void)?",
        "private func sourceID(for controller: GCController) -> String",
        "private let buttonActionLock = NSLock()",
        "private var activeButtonActions: [String: String] = [:]",
        "private func mappedAction(for name: String, source: String, pressed: Bool,",
        "profile: ControllerMappingProfile) -> String",
        "activeButtonActions[source] = action",
        "activeButtonActions.removeValue(forKey: source)",
        "source + \":button:\" + name",
        "source + \":left\"",
        "source + \":right\"",
        "private func detachHandlers(from pad: GCExtendedGamepad)",
        "detachHandlers(from: pad)",
        "pad.leftTrigger",
        "pad.dpad.up",
        "if let leftThumbstickButton = pad.leftThumbstickButton",
        "if let rightThumbstickButton = pad.rightThumbstickButton",
    ],
    "src/Display/KeyboardOverlayView.swift": [
        "onKeyEvent: ((String, Bool) -> Void)?",
        "activeModifiers",
        "releaseAllKeys()",
    ],
    "src/Display/MotionInputManager.swift": [
        "queue.maxConcurrentOperationCount = 1",
        "withStateLock",
        "motion.isDeviceMotionActive",
    ],
    "src/Display/ControllerMappingStore.swift": [
        "!$0.value.isEmpty",
        "private var cachedProfile: ControllerMappingProfile?",
        "if let cachedProfile { return cachedProfile }",
        "private func loadProfile()",
        "cachedProfile = newValue",
        "cachedProfile = .standard",
    ],
    "src/Display/TouchGamepadView.swift": [
        "iSteam.touchGamepad.layout.v3",
        "if !restoreLayout() {",
        "control.center.x / bounds.width",
        "saveLayout()",
        "releaseButtons()",
        "func releaseAllButtons()",
    ],
    "iSteam/NativeGuestMemory.cpp": [
        "const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);",
        "static_cast<uint64_t>(amount) == pageLength",
    ],
    ".github/workflows/validate-repository.yml": [
        "bash -n scripts/validate-qemu-runtime.sh",
        "test_execution_backend_router.swift",
        "test_elf_loader_program_headers.swift",
        "test_static_elf_execution.swift",
        "test_native_guest_memory.cpp",
        "clang++ -std=c++17 -Wall -Wextra -Werror",
        "cc -std=c11 -Wall -Wextra -Werror -pthread",
        "test_vnc_key_state.swift",
        "test_windows_pe_image.swift",
        "python -m unittest discover -s scripts/tests -p 'test_*.py'",
    ],
    ".github/workflows/validate-ios-build.yml": [
        "src/Runtime/LinuxSyscallDispatcher.swift",
        "      - src/**",
        "      - iSteam/**",
        "      - project.yml",
        "      - scripts/tests/**",
        "build-ios-device:",
        "-sdk iphoneos",
        "-destination 'generic/platform=iOS'",
        "CODE_SIGNING_ALLOWED=NO",
        "Test VNC key-state source arbitration",
        "scripts/tests/test_vnc_key_state.swift",
        "runs-on: xcode-27",
        'XCODE_DEVELOPER_DIR="$(xcode-select -p)"',
        'if ! awk -v version="$XCODE_VERSION"',
        'major > 27 || (major == 27 && minor >= 1)',
        
    ],
    "scripts/check-build-freshness.sh": [
        "git fetch --no-tags --unshallow origin main",
        "git rev-parse --is-shallow-repository",
        "git diff --name-only -z",
        "scripts/tests/*",
        "scripts/validate-qemu-source.py",
        "build_relevant_change",
    ],
    "scripts/patch_qemu_stikjit_ios.py": [
        "def patch_exported_symbols(source: str) -> str",
        "def patch_qemu_sources(region_path: Path) -> None",
        "qemu_system_shutdown_request;",
        "isteam_qemu_set_jit_callbacks;",
        "system/qemu.symbols",
        "isteam_qemu_set_jit_callbacks",
        "__attribute__((visibility(\"default\")))",
        "isteam_jit_prepare_callback",
        "#if TARGET_OS_IPHONE",
        "#elif TARGET_OS_IOS",
        "#include <mach/mach_init.h>",
        "#include <mach/vm_map.h>",
        "#define mach_vm_address_t vm_address_t",
        "#define mach_vm_offset_t vm_offset_t",
        "#define mach_vm_size_t vm_size_t",
        "#define mach_vm_remap vm_remap",
        "#define mach_vm_protect vm_protect",
        "#define mach_vm_deallocate vm_deallocate",
        "#include <mach/mach_vm.h>",
        "iSteamJITGetProtocolMode",
        'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
        "jit_protocol_mode < 0",
        "jit_protocol_mode > 0",
        "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
    ],
    "iSteam/JIT26Protocol.h": [
        "ISTEAM_JIT_PROTOCOL_UNKNOWN",
        "ISTEAM_JIT_PROTOCOL_STANDARD",
        "ISTEAM_JIT_PROTOCOL_STIKDEBUG",
        "iSteamJITGetProtocolMode",
    ],
    "project.yml": [
        "- sdk: IOKit.framework",
        "-Wl,-exported_symbol,_iSteamJITGetProtocolMode",
    ],
    "scripts/patch_qemu_tci_exports.py": [
        "REQUIRED_EXPORTS",
        "SHUTDOWN_EXPORT",
        "JIT_CALLBACK_EXPORT",
        "def patch_exported_symbols(source: str) -> str",
        "QEMU TCI shutdown export verification failed",
        "QEMU TCI export list still contains the StikJIT callback",
    ],
    "scripts/tests/test_qemu_tci_exports.py": [
        "def test_tci_exports_add_shutdown_and_remove_jit_callback",
        "def test_patch_is_idempotent",
        "def test_missing_lifecycle_export_is_rejected",
        "def test_duplicate_shutdown_export_is_rejected",
        "def test_duplicate_jit_callback_is_rejected",
        "def test_export_file_is_updated_idempotently",
    ],
    "scripts/patch_utm_qemu_ios.py": [
        "ISTEAM_QEMU_TCI_EXPORT_PATCHER is required for TCI mode",
        'python3 "$ISTEAM_QEMU_TCI_EXPORT_PATCHER" "$QEMU_DIR/system/qemu.symbols"',
        "has_function_posix_memalign = true",
        "--target-list=x86_64-softmmu",
        'python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"',
        'python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"',
    ],
    "scripts/patch_qemu_meson_ios.py": [
        "CONFIG_POSIX_MEMALIGN', true)",
        "OBJC_BLOCK_MARKER",
        "checked: 'require'",
        "-fno-objc-msgsend-class-selector-stubs",
        "emulator_link_args += ['-Wl,-objc_stubs_fast', '-lobjc', '-Wl,-force_load,",
        "A valid IOS_COMPILER_RT path is required",
    ],
    "scripts/verify_qemu_meson_link.py": [
        "build libqemu-x86_64-softmmu.dylib:",
        "def verify_objc_compile_edge",
        "spice-display-metal.m.o",
        "-fno-objc-msgsend-class-selector-stubs",
        "require_objc_compile=True",
        "LINK_ARGS",
        "emulator-specific link arguments",
        "-Wl,-objc_stubs_fast",
        "-lobjc",
        "-Wl,-force_load,",
    ],
    ".github/workflows/blank.yml": [
        "timeout-minutes: 25",
        "for attempt in 1 2 3 4 5; do",
        "grep -Eiq '429|rate limit exceeded|too many requests'",
        'sleep "$delay"',
        "git fetch --no-tags gitlab main",
        'git merge-base --is-ancestor "${GITLAB_SHA}" "${GITHUB_SHA}"',
        "cancel-in-progress: false",
    ],
    "scripts/tests/test_gitlab_sync_workflow.py": [
        "def test_sync_job_waits_longer_than_gitlab_rate_limit_window",
        "def test_sync_job_retries_only_rate_limit_responses",
        "def test_sync_job_rechecks_gitlab_ancestry_before_retry",
        "def test_sync_job_never_force_pushes",
        "def test_sync_jobs_are_serialized_without_cancellation",
    ],
    "scripts/tests/test_qemu_objc_compile_flags.py": [
        "def test_meson_patcher_adds_required_objc_flag_and_is_idempotent",
        "def test_meson_patcher_changes_only_the_objc_compiler_block",
        "def test_meson_patcher_fails_closed_if_objc_block_changes",
        "def test_meson_patcher_handles_qemu_common_flags_variant",
        "def test_meson_patcher_ignores_later_objc_summary_conditionals",
        "def test_meson_patcher_handles_nested_if_before_compiler_call",
        "def test_meson_patcher_rejects_unterminated_nested_if",
        "def test_meson_patcher_fails_closed_if_objc_block_is_missing",
        "def test_meson_patcher_rejects_duplicate_objc_blocks",
        "def test_meson_patcher_rejects_objc_flag_outside_its_block",
        "def test_meson_patcher_rejects_mixed_patched_and_unpatched_objc_calls",
        "def test_ninja_verifier_requires_flag_on_actual_metal_compile_edge",
        "def test_ninja_verifier_rejects_missing_compile_flag_even_when_link_flags_exist",
        "def test_ninja_verifier_rejects_missing_metal_compile_edge",
    ],
    "scripts/tests/test_x86_condition_dispatch.py": [
        "condition = alu.split(\"static func condition(_ code: UInt8, flags: UInt64) -> Bool {\", 1)[1]",
        'self.assertNotIn("let carrySet", condition)',
        "self.assertNotIn(\"guard let takeBranch = X86_64ALU.condition\", interpreter)",
        'self.assertIn("case 0x0: return flags & overflow != 0", condition)',
        'self.assertIn("case 0x6: return flags & (carry | zero) != 0", condition)',
        'self.assertIn("case 0xA: return flags & parity != 0", condition)',
        "self.assertIn(\"case 0x70...0x7F:\", interpreter)",
        "self.assertIn(\"second >= 0x80 && second <= 0x8F\", interpreter)",
        "self.assertIn(\"case 0xF6: // TEST, NOT and NEG r/m8\", interpreter)",
        "case 0xFE: // INC and DEC r/m8",
        "self.assertIn(\"second >= 0x40 && second <= 0x4F\", interpreter)",
        "self.assertIn(\"second >= 0x90 && second <= 0x9F\", interpreter)",
        "self.assertIn(\"second == 0x1F\", interpreter)",
        "self.assertIn(\"guard let _ = decodeRM(modrm, rex: rex) else {\", interpreter)",
    ],
    "iSteam/ConsoleViewController.swift": [
        "GameLauncher.shared.launch(",
        "GameStore.shared.recordLaunchAccepted(id: game.id)",
        "LinuxELFRuntime.shared.stop()",
    ],
    "iSteam/LibraryViewController.swift": [
        "GameLibraryViewController()",
        "GameStore.shared.search(\"\")",
        "ConsoleViewController(game: games[indexPath.row])",
        "super.init(style: .insetGrouped)",
        "required init?(coder: NSCoder)",
    ],
    "scripts/tests/test_source_validator.py": [
        "def test_native_bridge_enables_strict_c11_strnlen_and_covers_cleanup_race(self):",
        "int qemu_exit_status = g_qemu_main_loop();",
        "g_qemu_cleanup(qemu_exit_status)",
        "def test_linux_elf_launch_uses_bounded_guest_machine_batches(self):",
        "def test_console_uses_the_runtime_router_instead_of_direct_box64(self):",
        "def test_imported_games_are_reachable_from_the_ios_library(self):",
        "def test_qemu_ios_platform_guard_rejects_simulator_platforms(self):",
        "def test_static_pie_relocation_uses_loader_method_not_shadowed_parameter(self):",
        "def test_platform_validation_compiles_physical_ios_arm64(self):",
    ],
}
failed = False
for name, tokens in required.items():
    source = Path(name).read_text(encoding="utf-8")
    for token in tokens:
        if token not in source:
            print(f"{name}: missing required integration {token!r}", file=sys.stderr)
            failed = True

# Catch the accidental literal backslash-n that previously entered Swift comments.
builder = Path("src/QEMU/QEMUCommandBuilder.swift").read_text(encoding="utf-8")
if r"\n" in builder:
    print("src/QEMU/QEMUCommandBuilder.swift: literal escaped newline found in source", file=sys.stderr)
    failed = True


# The QEMU dependency build must patch Meson and verify the actual link edge
# before running the expensive QEMU compile.
qemu_workflow = Path(".github/workflows/build-qemu-runtime.yml").read_text(encoding="utf-8")
repository_validation = Path(".github/workflows/validate-repository.yml").read_text(encoding="utf-8")
if "utm-ios-arm64-deps-v15-" not in repository_validation or "utm-ios-arm64-deps-v14-" in repository_validation:
    print("Repository validation workflow cache contract does not match the QEMU runtime workflow.", file=sys.stderr)
    failed = True
for step in (
    "Checkout Akatsubaki Emu",
    "Checkout UTM with submodules",
    "Select Xcode",
    "Verify Objective-C class-selector stub compatibility",
    "Verify iOS vm_map compatibility",
    "scripts/check-build-freshness.sh",
    "scripts/check-build-freshness.sh",
    "Install UTM build dependencies",
    "Cache UTM dependency build and sysroot",
    "Build UTM dependencies for physical iOS arm64",
    "Build UTM TCI dependencies for physical iOS arm64",
    "Build UTM iOS archive",
    "Build UTM iOS TCI archive",
    "Package and verify in-process QEMU runtime",
    "Upload verified QEMU runtime artifact",
):
    marker = "- name: " + step
    if qemu_workflow.count(marker) != 1:
        print(f"QEMU workflow: expected exactly one {marker!r} step", file=sys.stderr)
        failed = True
for token in (
    "UTM/build-iOS-TCI-arm64",
    "UTM/sysroot-iOS-TCI-arm64",
    "./scripts/build_dependencies.sh -p ios-tci -a arm64",
    "./scripts/build_utm.sh -k iphoneos -s iOS-SE -a arm64 -o UTMBuildTCI",
    "test -d 'UTMBuildTCI.xcarchive/Products/Applications/UTM SE.app'",
    'mode_dir="build/qemu-runtime/QEMU/$mode"',
    "for mode in JIT TCI; do",
    "Physical iOS arm64 runtime variants: JIT and TCI",
):
    if token not in qemu_workflow:
        print(f"QEMU workflow: TCI build/package contract is missing {token!r}", file=sys.stderr)
        failed = True

if 'SYMBOLS="$(xcrun --sdk iphoneos nm -u "$PROBE_OBJECT")"' not in qemu_workflow:
    print("QEMU workflow: Objective-C symbol inspection command is missing", file=sys.stderr)
    failed = True
if "if grep -Fq '_objc_msgSendClass' <<<\"$SYMBOLS\"; then" not in qemu_workflow:
    print("QEMU workflow: Objective-C class-selector stub probe is malformed", file=sys.stderr)
    failed = True
if "\n; then\n" in qemu_workflow:
    print("QEMU workflow: Objective-C class-selector probe contains a stray shell terminator", file=sys.stderr)
    failed = True
for token in [
    "scripts/patch_utm_qemu_ios.py",
    "scripts/patch_qemu_meson_ios.py",
    "scripts/verify_qemu_meson_link.py",
    "Verify Objective-C class-selector stub compatibility",
    "Verify iOS vm_map compatibility",
    "ios-vm-map-compat-probe.c",
    "mach/vm_map.h",
    "mach_vm_remap",
    "mach_vm_protect",
    "mach_vm_deallocate",
    "-fno-objc-msgsend-class-selector-stubs",
    "export OBJCFLAGS=",
    'grep -Eq "[[:space:]]_?${symbol}$" "$exports"',
    "manifest_lines=\"$(awk 'END { print NR }' \"$manifest\")\"",
    'test "$manifest_lines" -eq 1',
    "utm-ios-arm64-deps-v15-",
    "spirv-tools",
    "spirv-llvm-translator",
    "steps.xcode.outputs.version",
    "runs-on: xcode-27",
    'XCODE_DEVELOPER_DIR="$(xcode-select -p)"',
    'awk -v version="$XCODE_VERSION"',
    'split(version, p, "[.]")',
        "major > 27 || (major == 27 && minor >= 1)",
    "Expected Xcode 27.1 or later on the xcode-27 runner",
    "PROBE_BINARY=",
    "-Wl,-objc_stubs_fast",
    "-lobjc -framework Metal",
]:
    if token not in qemu_workflow:
        print(f"QEMU workflow: missing build-integrity step {token!r}", file=sys.stderr)
        failed = True
if "--extra-ldflags=-Wl,-force_load" in qemu_workflow:
    print("QEMU workflow: obsolete configure-level compiler-rt workaround remains", file=sys.stderr)
    failed = True


# A release IPA must never be published without its native QEMU runtime.
release_workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
for token in [
    'bash scripts/check-build-freshness.sh "$GITHUB_SHA"',
    "group: isteam-release-publish-${{ matrix.channel }}",
    "if: steps.freshness.outputs.publish == 'true'",
]:
    if token not in release_workflow:
        print(f"release workflow: build freshness or release serialization contract is missing: {token}", file=sys.stderr)
        failed = True
if "- scripts/validate-qemu-source.py" not in release_workflow:
    print("release workflow: source-contract validator changes should not trigger full release builds", file=sys.stderr)
    failed = True
for token in [
    "- .github/workflows/validate-ios-build.yml",
    "- .github/workflows/validate-repository.yml",
    "- scripts/tests/**",
]:
    if token not in release_workflow:
        print(f"release workflow: validation-only path should not trigger QEMU release builds: {token}", file=sys.stderr)
        failed = True
release_job_count = release_workflow.count("\n  release:\n")
if release_job_count != 1:
    print(f"release workflow: expected exactly one release job, found {release_job_count}", file=sys.stderr)
    failed = True
release_build_start = release_workflow.find("\n  build:\n")
release_publish_start = release_workflow.find("\n  release:\n", release_build_start)
if release_build_start < 0 or release_publish_start < 0:
    print("release workflow: Apple build and publishing jobs are missing", file=sys.stderr)
    failed = True
else:
    release_build_job = release_workflow[release_build_start:release_publish_start]
    for token in [
        "runs-on: xcode-27",
        'XCODE_DEVELOPER_DIR="$(xcode-select -p)"',
        'awk -v version="$XCODE_VERSION"',
        'split(version, p, "[.]")',
        "major > 27 || (major == 27 && minor >= 1)",
    ]:
        if token not in release_build_job:
            print(f"release workflow: Apple build job missing {token!r}", file=sys.stderr)
            failed = True
    release_publish_job = release_workflow[release_publish_start:]
    for token in ["runs-on: ubuntu-24.04", "sha256sum -c"]:
        if token not in release_publish_job:
            print(f"release workflow: publishing job missing {token!r}", file=sys.stderr)
            failed = True

runtime_download_start = release_workflow.find("- name: Download required iOS QEMU runtime artifact")
runtime_download_end = release_workflow.find("\n      - uses: actions/cache@", runtime_download_start)
if runtime_download_start < 0 or runtime_download_end < 0:
    print("release workflow: required QEMU runtime download step is missing", file=sys.stderr)
    failed = True
else:
    runtime_download = release_workflow[runtime_download_start:runtime_download_end]
    for token in ["uses: actions/download-artifact@", "name: AkatsubakiEmu-qemu-runtime-ios-arm64", "path: build/qemu-runtime"]:
        if token not in runtime_download:
            print(f"release workflow: required same-run runtime download setting missing: {token}", file=sys.stderr)
            failed = True
    if "needs: qemu-runtime" not in release_workflow:
        print("release workflow: platform builds must depend on the same-run qemu-runtime job", file=sys.stderr)
        failed = True
    if "continue-on-error:" in runtime_download or "if_no_artifact_found: warn" in runtime_download:
        print("release workflow: runtime download must fail closed", file=sys.stderr)
        failed = True

ios_package_start = release_workflow.find("- name: Build and package iOS IPA")
ios_package_end = release_workflow.find("\n      - name: Build and package tvOS IPA", ios_package_start)
if ios_package_start < 0 or ios_package_end < 0:
    print("release workflow: iOS package step is missing", file=sys.stderr)
    failed = True
else:
    ios_package = release_workflow[ios_package_start:ios_package_end]
    for token in [
        'test -d "$RUNTIME_DIR/QEMU/JIT"',
        'test -d "$RUNTIME_DIR/QEMU/TCI"',
        'for MODE in JIT TCI; do',
        'MODE_MANIFEST="$MODE_DIR/runtime-library-path.txt"',
        'MODE_EXPORTS="$MODE_DIR/exports.txt"',
        'test -s "$MODE_MANIFEST"',
        'test -s "$MODE_EXPORTS"',
        'test -s "$RUNTIME_DIR/$RUNTIME_REL"',
        'test "$(awk \'END { print NR }\' "$MODE_MANIFEST")" -eq 1',
        'case "$RUNTIME_REL" in',
        "Frameworks/*)",
        "if printf",
        "grep -Eq",
        "Unsafe QEMU $MODE runtime path",
        "grep -Eq ' _?qemu_init$' \"$MODE_EXPORTS\"",
        "grep -Eq ' _?qemu_main_loop$' \"$MODE_EXPORTS\"",
        "grep -Eq ' _?qemu_cleanup$' \"$MODE_EXPORTS\"",
        "grep -Eq ' _?qemu_system_shutdown_request$' \"$MODE_EXPORTS\"",
        'if [ "$MODE" = "JIT" ]; then',
        "grep -Eq ' _?isteam_qemu_set_jit_callbacks$' \"$MODE_EXPORTS\"",
        'elif grep -Eq \' _?isteam_qemu_set_jit_callbacks$\' "$MODE_EXPORTS"; then',
        'cp -R "$RUNTIME_DIR/QEMU/." "$APP/QEMU/"',
        'test -s "$APP/$RUNTIME_REL"',
        'No QEMU $MODE data files were embedded.',
    ]:
        if token not in ios_package:
            print(f"release workflow: runtime packaging guard missing: {token}", file=sys.stderr)
            failed = True
    if 'test -s "$RUNTIME_DIR/QEMU/runtime-library-path.txt"' in ios_package:
        print("release workflow: obsolete root-level QEMU manifest assumption remains", file=sys.stderr)
        failed = True
    if "No verified QEMU runtime artifact is available" in ios_package:
        print("release workflow: must not silently publish IPA without QEMU", file=sys.stderr)
        failed = True


# The no-JIT bridge test must use a fake library that truly lacks the JIT callback.
fake_qemu_runtime = Path("scripts/tests/fake_qemu_runtime.c").read_text(encoding="utf-8")
native_bridge_test = Path("scripts/tests/test_qemu_native_bridge.c").read_text(encoding="utf-8")
validation_workflow = Path(".github/workflows/validate-repository.yml").read_text(encoding="utf-8")
for token in (
    "-DFAKE_QEMU_NO_JIT_CALLBACK",
    'test-qemu-native-bridge" jit',
    'test-qemu-native-bridge" tci',
    "libfakeqemu-jit.so",
    "libfakeqemu-tci.so",
):
    if token not in validation_workflow:
        print(f"repository validation workflow: missing JIT/TCI bridge test {token!r}", file=sys.stderr)
        failed = True
if "#ifndef FAKE_QEMU_NO_JIT_CALLBACK" not in fake_qemu_runtime:
    print("fake QEMU runtime: no-JIT fixture does not omit the callback export", file=sys.stderr)
    failed = True
for token in ('assert(argc == 3);', 'strcmp(argv[1], "jit")', 'strcmp(argv[1], "tci")'):
    if token not in native_bridge_test:
        print(f"native QEMU bridge test: missing mode selection {token!r}", file=sys.stderr)
        failed = True


# ENDBR64 support must remain exact: F3 0F 1E FA only, with malformed,
# truncated, unprefixed and unrelated F3-prefixed forms covered by regressions.
x86_interpreter_source = Path("src/Runtime/X86_64Interpreter.swift").read_text(encoding="utf-8")
x86_interpreter_tests = Path("scripts/tests/test_x86_64_interpreter.swift").read_text(encoding="utf-8")
for token in ("var endbrPrefix = false", "second == 0x1E", "modrm == 0xFA"):
    if token not in x86_interpreter_source:
        print(f"x86-64 interpreter: missing ENDBR64 decoder contract {token!r}", file=sys.stderr)
        failed = True
for token in ("endbr64Memory", "malformedEndbr64Memory", "truncatedEndbr64Memory", "unprefixedEndbr64Memory", "invalidF3Memory"):
    if token not in x86_interpreter_tests:
        print(f"x86-64 interpreter tests: missing ENDBR64 prefix regression {token!r}", file=sys.stderr)
        failed = True


# Kenran Buto AOT ABI v1, split-WX provider and interpreter-cooperative dispatch.
aot_header = Path("iSteam/JIT26Protocol.h").read_text(encoding="utf-8")
aot_memory = Path("iSteam/KenranButoAOTExecutableMemory.c").read_text(encoding="utf-8")
aot_execution = Path("src/Runtime/KenranButoAOTExecution.swift").read_text(encoding="utf-8")
aot_interpreter = Path("src/Runtime/X86_64Interpreter.swift").read_text(encoding="utf-8")
aot_guest_machine = Path("src/Runtime/GuestMachine.swift").read_text(encoding="utf-8")
aot_launcher = Path("src/Steam/GameLauncher.swift").read_text(encoding="utf-8")
aot_translator = Path("src/Runtime/X86_64AOTTranslator.swift").read_text(encoding="utf-8")
for token in ("KENRAN_BUTO_AOT_ABI_VERSION", "KenranButoAOTGuestState",
              "KenranButoAOTMemoryCallbacks", "iSteamAOTExecutableMemoryInvoke",
              "iSteamAOTExecutableMemoryMappedSize", "iSteamAOTGuestMemoryRead",
              "iSteamAOTGuestMemoryWrite"):
    if token not in aot_header:
        print(f"AOT ABI missing {token!r}", file=sys.stderr)
        failed = True
for token in ("_Static_assert(offsetof(KenranButoAOTGuestState,gpr)==8",
              "_Static_assert(sizeof(KenranButoAOTGuestState)==96",
              "iSteamAOTGuestStateIsValid(s)", "iSteamAOTGuestMemoryRead",
              "iSteamAOTGuestMemoryWrite", "iSteamAOTExecutableMemoryMappedSize",
              "r->mapped_size", "mprotect((void *)execute,mapped,PROT_READ|PROT_EXEC)",
              "r->finalized=true"):
    if token not in aot_memory:
        print(f"AOT memory provider missing {token!r}", file=sys.stderr)
        failed = True
invoke = aot_memory.split("bool iSteamAOTExecutableMemoryInvoke", 1)[1].split(
    "void iSteamAOTExecutableMemoryDestroy", 1
)[0]
if "iSteamAOTExecutableMemoryIsAvailable()" not in invoke:
    print("AOT invoke does not recheck live executable-memory readiness", file=sys.stderr)
    failed = True
guard = aot_memory.find("if(status!=KERN_SUCCESS||(maximum&VM_PROT_WRITE)==0)")
cleanup_end = aot_memory.find("return NULL;", guard)
if guard < 0 or cleanup_end < 0 or "deallocate_mach_address(write,mapped)" not in aot_memory[guard:cleanup_end]:
    print("AOT TXM remap failure path does not release writable alias", file=sys.stderr)
    failed = True
for token in ("KenranButoAOTGuestState", "makeMemoryCallbacks(for:memory)",
              "iSteamAOTExecutableMemoryInvoke", "maximumCachedBlocks=64",
              "iSteamAOTExecutableMemoryMappedSize(created)", "state.gpr==gpr",
              "state.memory==cb", "state.rflags==rflags",
              "state.instructions_executed<=UInt64(t.instructionCount)",
              "candidate.allocatedBytes", "func refreshAvailability()"):
    if token not in aot_execution:
        print(f"AOT executor missing {token!r}", file=sys.stderr)
        failed = True
for token in ("aotExecutor.execute(", "rip = result.exitRip", "aotExecutor?.invalidateAll()",
              "canStartAOTBlock()", "aotPageRemaining",
              "let budget = Int(min(remaining, 16))",
              "let stopCheckMask: UInt64 = aotIsAvailable ? 0x0f : 0xff",
              "if stopRequested { return .interrupted }"):
    if token not in aot_interpreter:
        print(f"AOT interpreter integration missing {token!r}", file=sys.stderr)
        failed = True
for token in ("aotExecutor: KenranButoAOTExecuting? = nil",
              "X86_64Interpreter(memory: self.memory, aotExecutor: aotExecutor)"):
    if token not in aot_guest_machine:
        print(f"GuestMachine AOT injection contract missing {token!r}", file=sys.stderr)
        failed = True
if "aotExecutor: KenranButoAOTExecutor()" not in aot_launcher:
    print("Linux ELF launch boundary does not inject KenranButoAOTExecutor", file=sys.stderr)
    failed = True
for token in ("maximumInstructions", "maximumOutputBytes", "maximumGuestBytes",
              "maximumInstructionBudget = 4096", "maximumOutputBudget = 1_048_576",
              "maximumGuestByteBudget = 65_536", "guestCode.withUnsafeBytes { raw in",
              "UnsafeBufferPointer(", "var output = [UInt32]()", "private struct EncodedWords",
              "machineCode: code.withUnsafeBytes { Data($0) }", "output.append(word.littleEndian)"):
    if token not in aot_translator:
        print(f"AOT translator missing bounded/fixed-buffer contract {token!r}", file=sys.stderr)
        failed = True
aot_allocation_test = Path("scripts/tests/test_aot_translator_allocation_hot_path.py").read_text(encoding="utf-8")
for token in ("test_guest_input_is_borrowed_without_copying_to_a_byte_array",
              "test_translated_output_uses_one_word_buffer_and_one_final_data_copy",
              "test_each_instruction_uses_a_fixed_four_word_emission_buffer",
              "test_move_immediate_does_not_allocate_chunk_or_word_arrays",
              "test_output_capacity_is_bounded_by_input_and_instruction_budgets",
              "test_words_are_stored_in_little_endian"):
    if token not in aot_allocation_test:
        print(f"AOT allocation regression missing {token!r}", file=sys.stderr)
        failed = True
aot_tests = Path("scripts/tests/test_x86_64_interpreter.swift").read_text(encoding="utf-8")
for token in ("#if KENRAN_BUTO_AOT_TESTS", "iSteamAOTGuestMemoryRead",
              "sideExit!.exitRip == 0x100A",
              "Kenran Butō AOT native block execution",
              "cachedBlockCount", "cachedExecutableBytes",
              "unavailableAOT.executeCalls == 0",
              "readyAOT.executeCalls == 0"):
    if token not in aot_tests:
        print(f"AOT runtime regression missing {token!r}", file=sys.stderr)
        failed = True
aot_workflow = Path(".github/workflows/validate-kenran-buto-aot.yml").read_text(encoding="utf-8")
for token in ("KenranButoAOTExecutableMemory.c", "KenranButoAOTExecution.swift",
              "test_x86_64_interpreter.swift", "test_aot_translator_allocation_hot_path.py",
              "-D KENRAN_BUTO_AOT_TESTS"):
    if token not in aot_workflow:
        print(f"AOT workflow missing {token!r}", file=sys.stderr)
        failed = True


# VNC session generation must survive every asynchronous framebuffer boundary.
vnc_client = Path("src/QEMU/QEMUVNCClient.swift").read_text(encoding="utf-8")
gpu_contract = Path("src/GPU/GPUBackend.swift").read_text(encoding="utf-8")
virtio_gpu = Path("src/GPU/VirtIOGPU.swift").read_text(encoding="utf-8")
metal_gpu = Path("src/GPU/MetalGPUBackend.swift").read_text(encoding="utf-8")
display_controller = Path("src/Display/VMDisplayViewController.swift").read_text(encoding="utf-8")
for token in ("onFrame: ((UInt64, Data, Int, Int, GPUFrameRegion?) -> Void)?",
              "onSessionGenerationChanged: ((UInt64) -> Void)?",
              "onSessionGenerationChanged?(generation)",
              "onFrame?(generation, frame.0, frame.1, frame.2, dirtyRegion)"):
    if token not in vnc_client:
        print(f"VNC generation propagation missing {token!r}", file=sys.stderr)
        failed = True
for token in ("setSessionGeneration(_ generation: UInt64)",
              "sessionGeneration: UInt64"):
    if token not in gpu_contract:
        print(f"GPU backend generation contract missing {token!r}", file=sys.stderr)
        failed = True
for token in ("let isCurrent = generation == sessionGeneration",
              "guard isCurrent else { return }",
              "backend.setSessionGeneration(generation)",
              "sessionGeneration: generation"):
    if token not in virtio_gpu:
        print(f"VirtIOGPU generation guard missing {token!r}", file=sys.stderr)
        failed = True
for token in ("guard frameSessionGeneration == sessionGeneration",
              "pending.sessionGeneration == sessionGeneration",
              "drawSessionGeneration == sessionGeneration",
              "drawFramebufferGeneration == framebufferGeneration",
              "framebuffer === source",
              "if !isCurrent"):
    if token not in metal_gpu:
        print(f"Metal final-consumer generation guard missing {token!r}", file=sys.stderr)
        failed = True
for token in ("vncClient.onSessionGenerationChanged",
              "self.virtioGPU.setSessionGeneration(generation)",
              "vncClient.onFrame = { [weak self] generation, data, width, height, dirtyRegion in",
              "sessionGeneration: generation"):
    if token not in display_controller:
        print(f"Display controller generation wiring missing {token!r}", file=sys.stderr)
        failed = True
vnc_generation_tests = Path("scripts/tests/test_vnc_frame_session_generation.py").read_text(encoding="utf-8")
if "VNCFrameSessionGenerationTests" not in vnc_generation_tests:
    print("VNC frame generation regression tests are missing", file=sys.stderr)
    failed = True


# QEMU remains a single process; guest sessions pause/reset through a private QMP socket.
qmp_bridge = Path("iSteam/QEMUNativeBridge.c").read_text(encoding="utf-8")
qmp_header = Path("iSteam/QEMUNativeBridge.h").read_text(encoding="utf-8")
qmp_builder = Path("src/QEMU/QEMUCommandBuilder.swift").read_text(encoding="utf-8")
qmp_runtime = Path("src/QEMU/QEMUNativeRuntime.swift").read_text(encoding="utf-8")
qmp_backend = Path("src/QEMU/QEMUBackend.swift").read_text(encoding="utf-8")
qmp_engine = Path("src/Core/VMEngine.swift").read_text(encoding="utf-8")
for token in ("bool isteam_qemu_qmp_command", "AF_UNIX", "qmp_capabilities",
              "SO_RCVTIMEO", "SO_NOSIGPIPE", "MSG_NOSIGNAL", '"system_reset"', '"cont"', '"stop"',
              "g_has_started = true", "attempt < 20", "nanosleep(&delay, NULL)"):
    if token not in qmp_bridge:
        print(f"QEMU QMP bridge missing {token!r}", file=sys.stderr)
        failed = True
if qmp_bridge.count("g_has_started = false;") != 1:
    print("QEMU one-shot process guard must be initialized once and never reset", file=sys.stderr)
    failed = True
if "isteam_qemu_qmp_command" not in qmp_header:
    print("QEMU native bridge header is missing the QMP command contract", file=sys.stderr)
    failed = True
for token in ("-no-shutdown", "-qmp", "unix:\\(Self.qmpSocketPath),server=on,wait=off",
              "static let qmpSocketPath"):
    if token not in qmp_builder:
        print(f"QEMU command builder missing persistent-session option {token!r}", file=sys.stderr)
        failed = True
for token in ("static let shared = QEMUNativeRuntime()", "private init()",
              "private let stateLock = NSLock()", "sessionKey == requestedSessionKey",
              'Self.sendQMP("system_reset")', 'Self.sendQMP("cont")', 'Self.sendQMP("stop")',
              "private(set) var isPaused = false", "the process and disk scopes remain available",
              "already stopped", "already running"):
    if token not in qmp_runtime:
        print(f"Persistent QEMU runtime missing {token!r}", file=sys.stderr)
        failed = True
if "QEMUNativeRuntime.shared" not in qmp_backend:
    print("QEMUBackend does not share the process-lifetime runtime", file=sys.stderr)
    failed = True
for token in ("private var sessionGeneration: UInt64?", "sessionGeneration = try runtime.start",
              "runtime.stop(sessionGeneration: sessionGeneration)",
              "runtime.reset(sessionGeneration: sessionGeneration)",
              "runtime.isRunning(sessionGeneration: sessionGeneration)",
              "runtime.isActive(sessionGeneration: sessionGeneration)",
              "runtime.lastError(sessionGeneration: sessionGeneration)"):
    if token not in qmp_backend:
        print(f"QEMUBackend session lease missing {token!r}", file=sys.stderr)
        failed = True
for token in ("guard candidate.stop() else", "if backend?.stop() ?? true", "QEMU process retained for repeat launches"):
    if token not in qmp_engine:
        print(f"VMEngine does not pause and retain QEMU for repeat launches: {token!r}", file=sys.stderr)
        failed = True
qmp_command_tests = Path("scripts/tests/test_qemu_command_builder.swift").read_text(encoding="utf-8")
if "QEMUCommandBuilder.qmpSocketPath" not in qmp_command_tests or "-no-shutdown" not in qmp_command_tests:
    print("QEMU command-line persistence regression is missing", file=sys.stderr)
    failed = True
qmp_tests = Path("scripts/tests/test_qemu_persistent_lifecycle.py").read_text(encoding="utf-8")
qmp_native_tests = Path("scripts/tests/test_qemu_native_bridge.c").read_text(encoding="utf-8")
if "QEMUPersistentLifecycleTests" not in qmp_tests:
    print("QEMU persistent lifecycle regression tests are missing", file=sys.stderr)
    failed = True
if "isteam_qemu_qmp_command" not in qmp_native_tests or "unsupported command" not in qmp_native_tests:
    print("Native QMP command whitelist regression is missing", file=sys.stderr)
    failed = True

for token in ("QMPServer", "qmp_test_server", "tooLongSocketPath",
              '"query-status"', '"system_reset"', "event_and_reply"):
    if token not in qmp_native_tests:
        print(f"Native QMP socket protocol regression missing {token!r}", file=sys.stderr)
        failed = True
if 'FileManager.default.temporaryDirectory.appendingPathComponent("q.sock").path' not in qmp_builder:
    print("QEMU QMP socket must remain inside the app-container temporary directory", file=sys.stderr)
    failed = True
if "guard QEMUCommandBuilder.qmpSocketPath.utf8.count < 104 else" not in qmp_runtime:
    print("QEMU runtime is missing the Darwin AF_UNIX socket-path length guard", file=sys.stderr)
    failed = True
qmp_docs = Path("docs/HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
if "q.sock" not in qmp_docs or "/tmp/akatsubaki-qmp.sock" in qmp_docs:
    print("Hybrid runtime documentation contains a stale or missing QMP socket path", file=sys.stderr)
    failed = True
xcode_guard_tests = Path("scripts/tests/test_xcode_version_guard.py").read_text(encoding="utf-8")
for token in ("XCODE_VERSION_GUARDS", "27.10", "28.0", "27.0", "26.4"):
    if token not in xcode_guard_tests:
        print(f"Xcode version semantic regression missing {token!r}", file=sys.stderr)
        failed = True

if failed:
    raise SystemExit(1)
print("QEMU bridge, guest input, runtime packaging, storage safety, and display source checks passed.")
