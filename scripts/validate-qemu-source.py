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
        "private func enqueueSend(_ data: Data, to connection: NWConnection,",
        "guard dx.isFinite, dy.isFinite",
        "let boundedX = max(-Float(framebufferWidth)",
        "let boundedY = max(-Float(framebufferHeight)",
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
        "fileOffset(forRVA: UInt32(descriptorRVA), length: 20)",
        "end <= UInt64(sizeOfHeaders)",
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
    ],
    "iSteam/JITCoordinator.swift": [
        "if #available(iOS 26.0, *)",
        "return iSteamJITIsSupported()",
        "scheme = \"stikdebug\"",
        "host = \"enable-jit\"",
        "script-name",
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
        "guard fileType == 2",
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
        "func startAccessingSecurityScopedResource() -> Bool { false }",
    ],
    "src/Runtime/RuntimeComponentManifest.swift": [
        "resolvingSymlinksInPath()",
        "rootPrefix",
    ],
    "src/Runtime/LinuxSyscallDispatcher.swift": [
        "func configure(programBreak: UInt64, stackBase: UInt64) throws",
        "private func findFreeAddress(startingAt start: UInt64, size: UInt64, limit: UInt64) -> UInt64?",
        "private func insertMappedRange(_ newRange: Range<UInt64>)",
        "private func validateRange(address: UInt64, length: UInt64) -> UInt64",
        "for scalar in text.unicodeScalars",
        "chunkBytes + scalarByteCount > 4096",
        "if !chunk.isEmpty { log.write(\"[guest stdout] \" + chunk) }",
        "guard a[4] == UInt64.max, a[5] == 0",
        "case 9:",
        "case 12:",
        "case 228:",
        "case 318:",
        "getRandom(at: a[0], length: a[1], flags: a[2])",
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
        "group: qemu-runtime-ios-arm64-",
        "cancel-in-progress: false",
    ],
    "scripts/tests/test_qemu_build_patches.py": [
        "test_qemu_runtime_does_not_cancel_in_progress_release_build",
        "cancel-in-progress: false",
        "def test_windows_and_steamos_profiles_select_uefi_firmware",
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
        "mappedRanges.first?.lowerBound ?? mmapCursor",
        "insertMappedRange(address..<end)",
    ],
    "scripts/tests/test_native_guest_memory.cpp": [
        "1ULL << 30",
        "isteam_guest_memory_allocated_pages",
        "constexpr uint64_t partialSize = pageSize + 17;",
        "isteam_guest_memory_zero(partial, pageSize, partialSize - pageSize)",
        "isteam_guest_memory_allocated_pages(partial) == 0",
    ],
    "scripts/tests/test_linux_syscall_dispatcher.swift": [
        "Linux x86-64 brk/mmap/munmap/mprotect/time/random/identity and reset tests passed",
        "dispatcher.dispatch(number: 9999",
        "precondition(hintedAddress == 0x48000)",
        "precondition(fixedAddress == mapped)",
        "precondition(noReplaceValue == UInt64(bitPattern: Int64(-17)))",
        "precondition(protectionAfterUnmapValue == UInt64(bitPattern: Int64(-12)))",
        "precondition(badTimezoneValue == UInt64(bitPattern: Int64(-14)))",
        "precondition(invalidMmapFDValue == UInt64(bitPattern: Int64(-22)))",
        "precondition(written == 12_000)",
        "let unicodeOutput = String(repeating: \"🙂\", count: 3_000)",
        "precondition(unicodeWritten == UInt64(unicodeOutput.utf8.count))",
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
        "type == 2 || type == 3 || type == 7",
        "alignment & (alignment - 1) == 0",
        "orderedSegments",
        "entry - $0.guestAddress < $0.fileSize",
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
        "default: return false",
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
        "case 0xC2:",
        "case 0x09, 0x0B:",
        "case 0x29, 0x2B, 0x39, 0x3B:",
        "case 0x68, 0x6A:",
        "private func fetchUInt16() -> UInt16?",
        "private func decodeRM(_ modrm: UInt8, rex: UInt8, trailingImmediateBytes: UInt8 = 0)",
        "let addressBase = usesRIPRelative ? rip &+ UInt64(trailingImmediateBytes) : base",
        "private func readByteOperand(_ operand: Operand, modrm: UInt8, rex: UInt8) -> UInt8?",
        "private func readWordOperand(_ operand: Operand) -> UInt16?",
        "usesRIPRelative",
        "let scale = UInt64(1) << ((sib >> 6) & 3)",
        "registers[index] = width64 ? value : UInt64(UInt32(truncatingIfNeeded: value))",
        "PUSH RSP stores the pre-decrement value.",
        "POP RSP loads the popped value directly",
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
    ],
    "scripts/tests/test_static_elf_execution.swift": [
        "Static ELF load → initial stack → x86-64 execution → Linux write/exit passed",
        "hello from static ELF",
        "func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool",
        "interpreter.run(maxInstructions: 64)",
        "func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool",
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
        "0x0F, 0xBE, 0x0D, 0x0C, 0x00, 0x00, 0x00",
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
    ],
    "src/Core/VMEngine.swift": [
        "var onStateChange: ((State) -> Void)?",
        "private func setState(_ newState: State)",
        "startupDeadline = .now() + 60",
        "within 60 seconds",
        "backend = candidate",
    ],
    "src/QEMU/QEMUNativeRuntime.swift": [
        "QEMURuntimeStatus.locate()",
        "isteam_qemu_start",
        "isteam_qemu_request_stop",
        "findUEFIFirmware(in directory: URL)",
        "findUEFIVariables(in directory: URL)",
        "makeWritableUEFIVariables(from template: URL, for configurationID: UUID)",
        "firmwareVariables: selectedFirmwareVariables",
        "startAccessingSecurityScopedResource()",
        "releaseScopesWhenStopped()",
        "configuration.requiresUEFI",
    ],
    "iSteam/QEMUNativeBridge.c": [
        "bool isteam_qemu_validate_library(",
        "dlopen(library_path, RTLD_NOW | RTLD_LOCAL)",
        "malloc(argument_length + 1)",
        "memcpy(copied_argv[i], argument, argument_length + 1)",
        'dlsym(library, "qemu_init")',
        'dlsym(library, "qemu_main_loop")',
        'dlsym(library, "qemu_cleanup")',
        'dlsym(library, "qemu_system_shutdown_request")',
        "static bool g_starting = false;",
        "static _Thread_local char error_copy",
        "ISTEAM_QEMU_MAX_ARGUMENTS 4096",
        "ISTEAM_QEMU_MAX_ARGUMENT_BYTES",
        "ISTEAM_QEMU_MAX_TOTAL_ARGUMENT_BYTES",
        "strnlen(argv[i], ISTEAM_QEMU_MAX_ARGUMENT_BYTES + 1u)",
        "error_buffer && error_capacity > 0",
    ],
    "src/QEMU/QEMURuntimeStatus.swift": [
        "bundleRoot = bundle.bundleURL.resolvingSymlinksInPath()",
        "bundlePrefix",
        "resolvingSymlinksInPath()",
        "isteam_qemu_validate_library(",
        "validateLoadableLibrary(libraryURL, dataDirectory: dataDirectory)",
        "The bundled QEMU library failed its load/export validation.",
    ],
    "src/Runtime/RuntimeCapabilityRegistry.swift": [
        "enum RuntimeCapabilityLevel: String, CaseIterable",
        "case notProbed",
        "static let current = inspect(probeQEMU: false)",
        "level: .loadable",
        "level == .operational",
        "if probeQEMU",
        "QEMURuntimeStatus.inspect(bundle: bundle)",
    ],
    "src/Steam/GameLauncher.swift": [
        "RuntimeCapabilityRegistry.current",
        "capabilities.backendAvailability",
        '"[runtime-capability] "',
        "WindowsPELoader().load(executable)",
        "directoryValues?.isDirectory == true",
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
    ],
    "src/Core/RuntimeSettings.swift": [
        "?? .windowsVM",
    ],
    "src/Core/VMConfiguration.swift": [
        "static var defaultAccelerator: Accelerator",
        "case .automatic, .qemuJIT: return .jit",
        "case .qemuInterpreter, .hypervisor: return .tcg",
        "var bootUEFI: Bool? = nil",
        "var requiresUEFI: Bool",
        "bootWindows: true, bootUEFI: true",
        "bootWindows: false, bootUEFI: false",
        "bootWindows: false, bootUEFI: true",    ],
        "src/Core/VMConfigurationValidation.swift": [,
        "guard architecture == .x86_64",
        "case .unsupportedArchitecture(let architecture)",
        "if gpu != .virtioGPU",
        "case .unsupportedGPU(let gpu)",
        "framebufferBytes <= 64 * 1024 * 1024",
        "fit the 64 MiB framebuffer limit",
    ],
    "scripts/tests/test_qemu_native_bridge.c": [
        "tooManyArguments[4097]",
        "oversizedArgument",
        "QEMU arguments exceed the configured size limits",
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
        "backendNotInstalled(configuration.architecture).localizedDescription",
        "withExecutionLock",
        "hasLoadedImage",
        "activeCPULock",
        "requestActiveStop",
        "state == .configured",
        "executionLock.lock()",
    ],
    "src/Steam/GameArtworkStore.swift": [
        "CGImageSourceGetCount(image) <= 200",
        "width <= 8192, height <= 8192",
        "width <= (16 * 1024 * 1024) / height",
        "CGImageSourceCreateImageAtIndex(image, 0, nil) != nil",
        "org.webmproject.webp",
    ],
    "src/Runtime/ExternalDriveStore.swift": [
        "maximumBytes: Int? = 64 * 1024 * 1024",
        "values.isRegularFile == true",
        "CocoaError(.fileReadTooLarge)",
        "replaceItemAt(destination, withItemAt: temporary)",
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
        "engine.start(diskImage: diskImage)",
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
        "view.drawableSize = CGSize(width: frameWidth, height: frameHeight)",
        "source.texture.width == drawable.texture.width",
        "source.texture.height == drawable.texture.height",
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
        "private func mappedAction(for name: String, source: String, pressed: Bool) -> String",
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
    ],
    "src/Display/TouchGamepadView.swift": [
        "iSteam.touchGamepad.layout.v3",
        "control.center.x / bounds.width",
        "saveLayout()",
        "releaseButtons()",
        "func releaseAllButtons()",
    ],
    "iSteam/NativeGuestMemory.cpp": [
        "const uint64_t pageLength = std::min(pageSize, memory->size - pageStart);",
        "static_cast<uint64_t>(amount) == pageLength",
    ],
    ".gitlab-ci.yml": [
        "test_static_elf_execution.swift",
        "test_native_guest_memory.cpp",
        "g++ -std=c++17 -Wall -Wextra -Werror",
        "test_vnc_key_state.swift",
        "test_windows_pe_image.swift",
        "python -m unittest discover -s scripts/tests -p 'test_*.py'",
    ],
    ".github/workflows/validate-ios-build.yml": [
        "src/Runtime/LinuxSyscallDispatcher.swift",
        "Test VNC key-state source arbitration",
        "scripts/tests/test_vnc_key_state.swift",
    ],
    "scripts/patch_utm_qemu_ios.py": [
        "has_function_posix_memalign = true",
        "--target-list=x86_64-softmmu",
        'python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"',
        'python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"',
    ],
    "scripts/patch_qemu_meson_ios.py": [
        "CONFIG_POSIX_MEMALIGN', true)",
        "emulator_link_args += ['-Wl,-force_load,",
        "A valid IOS_COMPILER_RT path is required",
    ],
    "scripts/verify_qemu_meson_link.py": [
        "build libqemu-x86_64-softmmu.dylib:",
        "LINK_ARGS",
        "emulator-specific link arguments",
        "-Wl,-force_load,",
    ],
    "scripts/tests/test_x86_condition_dispatch.py": [
        "self.assertIn(\"static func condition(_ code: UInt8, flags: UInt64) -> Bool\", alu)",
        "self.assertNotIn(\"guard let takeBranch = X86_64ALU.condition\", interpreter)",
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
for token in [
    "scripts/patch_utm_qemu_ios.py",
    "scripts/patch_qemu_meson_ios.py",
    "scripts/verify_qemu_meson_link.py",
    "utm-ios-arm64-deps-v11-",
    "spirv-tools",
    "spirv-llvm-translator",
    "steps.xcode.outputs.version",
]:
    if token not in qemu_workflow:
        print(f"QEMU workflow: missing build-integrity step {token!r}", file=sys.stderr)
        failed = True
if "--extra-ldflags=-Wl,-force_load" in qemu_workflow:
    print("QEMU workflow: obsolete configure-level compiler-rt workaround remains", file=sys.stderr)
    failed = True


# A release IPA must never be published without its native QEMU runtime.
release_workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
if "- scripts/validate-qemu-source.py" not in release_workflow:
    print("release workflow: source-contract validator changes should not trigger full release builds", file=sys.stderr)
    failed = True
for token in [
    "- .github/workflows/validate-ios-build.yml",
    "- .github/workflows/validate-repository.yml",
    "- .gitlab-ci.yml",
    "- scripts/tests/**",
]:
    if token not in release_workflow:
        print(f"release workflow: validation-only path should not trigger QEMU release builds: {token}", file=sys.stderr)
        failed = True
release_concurrency_start = release_workflow.find("\nconcurrency:\n")
release_concurrency_end = release_workflow.find("\njobs:", release_concurrency_start)
if release_concurrency_start < 0 or release_concurrency_end < 0:
    print("release workflow: concurrency policy is missing", file=sys.stderr)
    failed = True
else:
    release_concurrency = release_workflow[release_concurrency_start:release_concurrency_end]
    for token in [
        "group: isteam-release${{ github.event_name == 'workflow_dispatch' && inputs.channel == 'Main' && '-main' || '' }}",
        "cancel-in-progress: false",
    ]:
        if token not in release_concurrency:
            print(f"release workflow: concurrency policy missing {token!r}", file=sys.stderr)
            failed = True
runtime_download_start = release_workflow.find("- name: Download required iOS QEMU runtime artifact")
runtime_download_end = release_workflow.find("\n      - uses: actions/cache@v4", runtime_download_start)
if runtime_download_start < 0 or runtime_download_end < 0:
    print("release workflow: required QEMU runtime download step is missing", file=sys.stderr)
    failed = True
else:
    runtime_download = release_workflow[runtime_download_start:runtime_download_end]
    for token in ["uses: actions/download-artifact@v4", "name: iSteam-qemu-runtime-ios-arm64", "path: build/qemu-runtime"]:
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
        'test -s "$RUNTIME_DIR/QEMU/runtime-library-path.txt"',
        'test -s "$RUNTIME_DIR/exports.txt"',
        'grep -Eq \' _?qemu_init$\' "$RUNTIME_DIR/exports.txt"',
        'grep -Eq \' _?qemu_main_loop$\' "$RUNTIME_DIR/exports.txt"',
        'grep -Eq \' _?qemu_cleanup$\' "$RUNTIME_DIR/exports.txt"',
    ]:
        if token not in ios_package:
            print(f"release workflow: runtime packaging guard missing: {token}", file=sys.stderr)
            failed = True
    if "No verified QEMU runtime artifact is available" in ios_package:
        print("release workflow: must not silently publish IPA without QEMU", file=sys.stderr)
        failed = True

if failed:
    raise SystemExit(1)
print("QEMU bridge, guest input, runtime packaging, storage safety, and display source checks passed.")
