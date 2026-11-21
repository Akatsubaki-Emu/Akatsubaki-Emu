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
        "keyState.setKey(keysym, source: source + \":\" + name, isDown: down)",
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
        "performSynchronouslyOnQueue",
        "details.prefix(500_000)",
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
    ],    "src/Performance/TranslationCache.swift": [
        "SHA256.hash(data: Data(key.utf8))",
    ],
    "src/Runtime/RuntimeComponentManifest.swift": [
        "resolvingSymlinksInPath()",
        "rootPrefix",
    ],
    "src/Runtime/ELF64Loader.swift": [
        "($0.flags & 0x1) != 0",
        "loadable executable segment",
        "case unsupportedFileType(UInt16), unsupportedDynamicImage, fileTooLarge",
        "version == 1",
        "type == 2 || type == 3 || type == 7",
        "alignment & (alignment - 1) == 0",
        "orderedSegments",
        "entry - $0.guestAddress < $0.fileSize",
    ],
    "src/Runtime/X86_64Interpreter.swift": [
        "case 0xB8...0xBF: // MOV r32, imm32 or MOV r64, imm64",
        "registers[index] = UInt64(immediate)",
        "let is64Bit = rex & 0x08 != 0",
        "32-bit GPR writes zero-extend",
        "PUSH RSP stores the pre-decrement value.",
        "POP RSP loads the popped value directly",
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
    ],
    "src/Core/VMConfigurationValidation.swift": [
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
    "src/Runtime/GuestMemory.swift": [
        "private let native: OpaquePointer?",
        "var isAvailable: Bool",
    ],
    "src/Runtime/GuestMachine.swift": [
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
        "seen.insert($0.folding(options: .caseInsensitive, locale: .current)).inserted",
        "games.flatMap(\\.tags)",
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
    ".github/workflows/validate-ios-build.yml": [
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
    "utm-ios-arm64-deps-v10-",
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
release_concurrency_start = release_workflow.find("\nconcurrency:\n")
release_concurrency_end = release_workflow.find("\njobs:", release_concurrency_start)
if release_concurrency_start < 0 or release_concurrency_end < 0:
    print("release workflow: concurrency policy is missing", file=sys.stderr)
    failed = True
else:
    release_concurrency = release_workflow[release_concurrency_start:release_concurrency_end]
    for token in [
        "group: isteam-release${{ github.event_name == 'workflow_dispatch' && inputs.channel == 'Main' && '-main' || '' }}",
        "cancel-in-progress: true",
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
