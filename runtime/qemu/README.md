# Akatsubaki Emu QEMU runtime contract

This document describes the QEMU runtime artifacts used by Akatsubaki Emu. The engine is built from the UTM/QEMU source by the dedicated workflow; source presence alone does not prove that either runtime builds or boots.

## Build and embedding

`.github/workflows/build-qemu-runtime.yml` builds two physical-iOS arm64 UTM archives:

- `iOS`: native TCG/JIT runtime. It requires the StikDebug callback ABI.
- `iOS-TCI`: threaded TCG interpreter runtime. It does not require executable-memory JIT.

The packaging steps are mode-specific:

- `scripts/package-utm-qemu-runtime.sh` packages the JIT library and its dependencies under `QEMU/JIT`.
- `scripts/package-utm-qemu-tci-runtime.sh` packages the TCI library under `QEMU/TCI`, renaming the framework to `QEMU-TCI.framework` when needed.
- `scripts/merge-qemu-runtime-variants.sh` combines both mode directories and their shared UTM frameworks into one artifact.

The iOS release workflow downloads the combined artifact and embeds its complete `Frameworks/` and `QEMU/` directories into the app. Each mode has its own runtime-library manifest; do not assume a fixed QEMU library filename or internal UTM layout.

Build verification: a successful hosted JIT+TCI UTM build and combined artifact have not yet been recorded.

The runtime library must be built for **physical iOS arm64** and runs an **x86_64 system guest**. An arm64 slice alone is insufficient: macOS, Mac Catalyst, and iOS Simulator builds are rejected.

## Native bridge contract

Both runtime modes require these lifecycle and shutdown exports:

- `qemu_init`
- `qemu_main_loop`
- `qemu_cleanup`
- `qemu_system_shutdown_request`

Only JIT mode additionally requires `isteam_qemu_set_jit_callbacks`. TCI validation checks lifecycle/shutdown exports and deliberately does not require the StikDebug JIT callback. The packager and preflight validator enforce the selected mode's export contract.

## Startup and validation

`src/QEMU/QEMURuntimeStatus.swift` resolves the library path from the generated manifest. `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI directory and asks the native bridge to load the library with `RTLD_NOW` and resolve the mode-specific exports. `QEMUNativeRuntime` performs this preflight before starting QEMU, so missing dependent libraries and missing exports are reported before guest startup.

Validate a signed library with the matching mode:

```sh
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library jit
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library tci
```

The standalone validator requires Apple tooling (`file`, `lipo`, `nm`, `vtool`, and `codesign`). It is a post-signing check; unsigned build artifacts are not expected to pass its code-signature check.

## JIT requirements

On physical iOS 17.4 and later, JIT mode requires an active StikDebug debugger/JIT session and the app's `get-task-allow` entitlement. On supported iOS 26+ TXM devices, the patched TCG allocator uses the StikDebug executable-region protocol. TCI uses the threaded TCG interpreter and bypasses the physical-iOS JIT readiness path.

## Firmware and writable disks

Windows and SteamOS UEFI profiles require matching firmware pairs:

- `OVMF_CODE.fd` with `OVMF_VARS.fd`
- `OVMF_CODE_4M.fd` with `OVMF_VARS_4M.fd`
- `edk2-x86_64-code.fd` with `edk2-x86_64-vars.fd`

The app copies the variable-store template into per-configuration Application Support storage and passes it as the second pflash device. It never writes UEFI variables into the signed app bundle. Existing symlinks and non-regular destination objects are not reused.

Launch Setup accepts a boot disk or installer/live ISO and an optional writable destination disk. ISO installation attaches the destination as a hard disk and keeps the ISO on a separate optical AHCI port. A blank sparse raw disk can be created in app storage; existing one-disk sessions remain supported.

## Physical-device runtime startup

The JIT and TCI build/package workflows are defined, but neither artifact has yet been verified by a successful hosted dual-runtime build followed by a physical-iPad guest boot. Guest startup, display, input, graceful shutdown, and disk persistence remain unverified on hardware.

The native bridge is one-shot per app process because QEMU global-state reinitialization is not proven safe; relaunch Akatsubaki Emu before starting another QEMU session. The current runtime targets x86_64 guests. It is not an ARM64 guest runtime. tvOS and visionOS require separately built and validated platform runtimes.

A successful source check or artifact inspection is not evidence that a physical-device guest boots.

## JIT protocol detection

Physical iOS 26+ devices are classified through the same IOKit memory-map TXM query used by StikJIT. The host exposes UNKNOWN, STANDARD, and STIKDEBUG modes. UNKNOWN fails closed in the launch coordinator and QEMU patcher. STANDARD uses QEMU's normal split-WX allocator; STIKDEBUG uses the exported callback setter and the StikDebug executable-region protocol.
