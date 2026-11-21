#!/usr/bin/env python3
"""Guard against malformed QEMU bridge source and accidental regressions."""
from pathlib import Path
import sys

required = {
    "src/QEMU/QEMUVNCClient.swift": [
        "private func performHandshake(_ connection: NWConnection) async throws",
        "case 0: // FramebufferUpdate",
        "func tapKey(_ key: String)",
        "numberOfColours = Int(Self.u16(header, 3))",
        "private static let maxFramebufferBytes = 64 * 1024 * 1024",
        "private let sendQueue = DispatchQueue(label: \"com.xthrx.isteam.qemu-vnc.send\")",
        "private final class QEMUOneShotCompletion: @unchecked Sendable",
        "private func withStateLock<T>",
        "let completion = QEMUOneShotCompletion()",
        "RFB FramebufferUpdateRequest is exactly 10 bytes:",
        "0, 0, 0, 0,",
    ],
    "src/Runtime/WindowsPELoader.swift": [
        "WindowsPEImage.parse(data)",
        "is64Bit: true",
    ],
    "src/Runtime/WindowsPEImage.swift": [
        "unterminated PE string within its mapped section",
        "Section(name: name,\n                virtualAddress:",
        "virtualSize: try u32(data, offset + 8)",
        "rawOffset: try u32(data, offset + 20)",
    ],
    "iSteam/ELFValidator.swift": [
        "guard fileType == 2",
        "unsupportedFileType",
    ],
    "iSteam/LaunchSetupViewController.swift": [
        "guestControl.selectedSegmentIndex = 2",
        "executable-library route currently accepts Windows PE metadata only",
        "\"SteamOS Gaming Mode\"",
        "VMConfiguration.defaultSteamOS",
    ],
    "src/Performance/TranslationCache.swift": [
        "SHA256.hash(data: Data(key.utf8))",
    ],
    "src/Runtime/RuntimeComponentManifest.swift": [
        "resolvingSymlinksInPath()",
        "rootPrefix",
    ],
    "src/Runtime/ELF64Loader.swift": [
        "($0.flags & 0x1) != 0",
        "loadable executable segment",
    ],
    "src/Runtime/X86_64Interpreter.swift": [
        "let is64Bit = rex & 0x08 != 0",
        "32-bit GPR writes zero-extend",
        "PUSH RSP stores the pre-decrement value.",
        "POP RSP loads the popped value directly",
    ],
    "src/QEMU/QEMUCommandBuilder.swift": [
        '"-vnc", "127.0.0.1:0"',
        '"-device", configuration.gpu.rawValue',
        'let machine = "q35,usb=on"',
        '"-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet"',
        "escapeDriveValue(_ path: String)",
        'replacingOccurrences(of: ",", with: ",,")',
    ],
    "src/Display/VMDisplayViewController.swift": [
        "vncClient.onFrame", "vncClient.start()", "vncClient.tapKey(key)"
    ],
    "src/QEMU/QEMUNativeRuntime.swift": [
        "QEMURuntimeStatus.inspect()", "isteam_qemu_start", "isteam_qemu_request_stop"
    ],
    "iSteam/QEMUNativeBridge.c": [
        "bool isteam_qemu_validate_library(",
        "dlopen(library_path, RTLD_NOW | RTLD_LOCAL)",
        'dlsym(library, "qemu_init")',
        'dlsym(library, "qemu_main_loop")',
        'dlsym(library, "qemu_cleanup")',
        "static bool g_starting = false;",
        "static _Thread_local char error_copy",
    ],
    "src/QEMU/QEMURuntimeStatus.swift": [
        "isteam_qemu_validate_library(",
        "validateLoadableLibrary(library, dataDirectory: dataDirectory)",
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
    ],


    "src/Core/VMSaveSlotStore.swift": [
        "startAccessingSecurityScopedResource()",
    ],
    "src/Runtime/ExecutionBackendRouter.swift": [
        "antiCheatAssessment == .notRequested",
        "return dynamicTranslationBackend != nil",
        "Cached AOT translations require a dynamic engine",
    ],
    "src/Core/VMConfiguration.swift": [
        "static var defaultAccelerator: Accelerator",
        "case .automatic, .qemuJIT: return .jit",
        "case .qemuInterpreter, .hypervisor: return .tcg",
    ],
    "src/Core/VMConfigurationValidation.swift": [
        "framebufferBytes <= 64 * 1024 * 1024",
        "fit the 64 MiB framebuffer limit",
    ],
    "src/Runtime/GuestMemory.swift": [
        "private let native: OpaquePointer?",
        "var isAvailable: Bool",
    ],
    "src/Runtime/GuestMachine.swift": [
        "maximumGuestBytes: UInt64 = 16 * 1024 * 1024 * 1024",
        "guard self.memory.isAvailable",
    ],
    "src/Steam/GameRuntimeProfile.swift": [
        "launchArguments.count <= 256",
        "environment.count <= 128",
        "compatibilityNotes.utf8.count <= 16_384",
        "UInt64(preferredResolutionWidth) * UInt64(preferredResolutionHeight) * 4 <= 64 * 1024 * 1024",
    ],
    "iSteam/LaunchSetupViewController.swift": [
        "RuntimeSettings.shared.vmMode",
        "config.accelerator = VMConfiguration.defaultAccelerator",
        "let selectedMode: VMExecutionMode",
    ],
    "src/Display/VMDisplayViewController.swift": [
        "configuration.displayWidth, height: configuration.displayHeight",
        "configuration.displayFPS",
    ],
    "src/Runtime/HostDeviceBridge.swift": [
        "resolvingSymlinksInPath()",
        "withAccess(to: source)",
    ],
    "src/Steam/DroidDeckFeatureServices.swift": [
        "NSFileCoordinator()",
        "writingItemAt: destination",
    ],
    "src/GPU/MetalGPUBackend.swift": [
        "view.framebufferOnly = false",
    ],
    "src/Display/ControllerInputManager.swift": [
        "GCController.stopWirelessControllerDiscovery()",
        "pad.leftTrigger",
        "pad.dpad.up",
    ],
    "src/Display/TouchGamepadView.swift": [
        'iSteam.touchGamepad.layout.v3',
        "control.center.x / bounds.width",
        "control.center.y / bounds.height",
        "if bounds.size != lastBoundsSize",
        "installEditGesturesIfNeeded()",
    ],
    "scripts/patch_utm_qemu_ios.py": [
        "has_function_posix_memalign = true",
        "--target-list=x86_64-softmmu",
        'python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"',
        'python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"',
    ],
    "scripts/patch_qemu_meson_ios.py": [
        "CONFIG_POSIX_MEMALIGN', true)",
        "add_project_link_arguments('-Wl,-force_load,' + ios_compiler_rt, language: 'c')",
        "IOS_COMPILER_RT is required for the i-Steam iOS build",
    ],
    "scripts/verify_qemu_meson_link.py": [
        "build libqemu-x86_64-softmmu.dylib:",
        "LINK_ARGS",
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
    "utm-ios-arm64-deps-v9-",
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
