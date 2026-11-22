# Akatsubaki Emu QEMU runtime contract

This document describes the two QEMU runtime variants built from the pinned UTM/QEMU source by `.github/workflows/build-qemu-runtime.yml`. It does not implement or bundle QEMU itself.

## Build and packaging

The workflow builds two physical iOS arm64 variants from the same UTM checkout:

- **JIT:** dependency target `ios`, UTM scheme `iOS`; uses native TCG code generation and the app's StikDebug executable-memory callbacks.
- **TCI:** dependency target `ios-tci`, UTM scheme `iOS-TCI`; uses the threaded TCG interpreter and does not require executable-memory JIT.

`scripts/package-utm-qemu-runtime.sh <archive> build/<output-name> [jit|tci]` packages one mode. The combined workflow artifact contains:

- `Frameworks/QEMU.framework/` — JIT runtime.
- `Frameworks/QEMU-TCI.framework/` — no-JIT TCI runtime.
- `QEMU/JIT/runtime-library-path.txt`, `QEMU/JIT/exports.txt`, and JIT firmware/data.
- `QEMU/TCI/runtime-library-path.txt`, `QEMU/TCI/exports.txt`, and TCI firmware/data.
- `QEMU/runtime-library-path.txt` and root `exports.txt` remain as JIT compatibility manifests for existing packaging checks.

The TCI packager renames the framework to keep the two QEMU libraries distinct while retaining their relative dependency trees. The release workflow embeds the complete `Frameworks/` and `QEMU/` directories into the iOS app and verifies both manifests and runtime libraries before producing the IPA.

The runtime library must be built for **physical iOS arm64** and runs an **x86_64 system guest**. An arm64 slice alone is insufficient: macOS, Mac Catalyst, and iOS Simulator builds are rejected.

## Native bridge contract

Both modes require these exports:

- `qemu_init`
- `qemu_main_loop`
- `qemu_cleanup`
- `qemu_system_shutdown_request`

Only JIT mode additionally requires `isteam_qemu_set_jit_callbacks`. The native bridge receives `requiresJIT` from the selected accelerator and does not register or invoke the JIT callback for TCI mode.

## Startup and validation

`src/QEMU/QEMURuntimeStatus.swift` resolves the mode-specific manifest:

- JIT mode: `QEMU/JIT/runtime-library-path.txt`
- TCI mode: `QEMU/TCI/runtime-library-path.txt`

The manifest is authoritative; do not assume a fixed library filename or internal UTM layout. `QEMURuntimeStatus.inspect(requiresJIT:)` asks the native bridge to load the selected library with `RTLD_NOW`, which also checks transitive dependencies, and verifies the required mode-specific exports before guest startup.

The standalone validator accepts the mode explicitly:

```sh
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library jit
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library tci
```

The validator requires Apple tooling (`file`, `lipo`, `nm`, `vtool`, and `codesign`). It is a post-signing check; unsigned build artifacts are not expected to pass its code-signature check. TCI validation checks lifecycle/shutdown exports and deliberately does not require the StikDebug JIT callback.

## Acceleration profiles

- **QEMU TCG + JIT:** `-accel tcg,tb-size=128,split-wx=on`. On supported physical iOS devices this requires a valid `get-task-allow` entitlement, a recognised JIT protocol, and confirmed executable-memory readiness. On iOS 26+ TXM devices the patched allocator obtains the executable RX region through the StikDebug protocol and creates a writable alias.
- **QEMU TCI (no JIT):** `-accel tcg`. The UTM `iOS-TCI` build uses the threaded TCG interpreter. It does not request StikDebug, does not need the JIT callback export, and can run where executable-memory JIT is unavailable. It is expected to be slower than native TCG code generation.

Both variants are full-system QEMU runtimes for x86_64 guests. TCI is a genuine no-JIT interpreter build, not merely a smaller JIT translation cache.

## Firmware and writable disks

Windows and SteamOS UEFI profiles require matching firmware pairs:

- `OVMF_CODE.fd` with `OVMF_VARS.fd`
- `OVMF_CODE_4M.fd` with `OVMF_VARS_4M.fd`
- `edk2-x86_64-code.fd` with `edk2-x86_64-vars.fd`

The app copies the variable-store template into per-configuration Application Support storage and passes it as the second pflash device. It never writes UEFI variables into the signed app bundle. Existing symlinks and non-regular destination objects are not reused.

Launch Setup accepts a boot disk or installer/live ISO and an optional writable destination disk. ISO installation attaches the destination as a hard disk and keeps the ISO on a separate optical AHCI port. A blank sparse raw disk can be created in app storage; existing one-disk sessions remain supported.

## Verification status and limitations

- **Source integration:** JIT and TCI build/package steps, mode-specific manifests, no-JIT native startup and release embedding checks are now present.
- **Build verification:** a successful hosted JIT+TCI UTM build and combined artifact have not yet been recorded.
- **Device verification:** physical-device runtime startup, guest boot, display, input, graceful shutdown, and disk persistence have **not** been verified on hardware.
- The native bridge is one-shot per app process because QEMU global-state reinitialization is not proven safe; relaunch Akatsubaki Emu before starting another QEMU session.
- The current runtime targets x86_64 guests. It is not an ARM64 guest runtime.
- tvOS and visionOS require separately built and validated platform runtimes.

A successful source check or artifact inspection is not evidence that a physical-device guest boots.
