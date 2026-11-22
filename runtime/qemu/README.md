# Akatsubaki Emu QEMU runtime contract

This document describes the QEMU runtime artifact used by Akatsubaki Emu. It does not implement or bundle the QEMU engine; the runtime is built from the UTM/QEMU source by the dedicated workflow.

## Build and embedding

`scripts/package-utm-qemu-runtime.sh` selects a loadable UTM/QEMU Mach-O library by its exported lifecycle, shutdown, and JIT symbols. It writes the selected relative path to `QEMU/runtime-library-path.txt`.

The iOS release workflow downloads the runtime artifact and embeds its complete `Frameworks/` and `QEMU/` directories into the app. The manifest is authoritative; do not assume a fixed QEMU library filename or internal UTM layout.

The runtime library must be built for **physical iOS arm64** and runs an **x86_64 system guest**. An arm64 slice alone is insufficient: macOS, Mac Catalyst, and iOS Simulator builds are rejected.

## Native bridge contract

`iSteam/QEMUNativeBridge.c` requires all five exports below and registers the JIT callbacks before calling `qemu_init`:

- `qemu_init`
- `qemu_main_loop`
- `qemu_cleanup`
- `qemu_system_shutdown_request`
- `isteam_qemu_set_jit_callbacks`

Graceful shutdown is mandatory for both modes. The StikDebug JIT callback is required only for the JIT runtime; the TCI runtime must be usable without it. A JIT library missing the callback or either mode missing a lifecycle export is rejected by the packager, preflight loader, and native bridge.

The bridge matches the pinned UTM QEMU 10.0.12 lifecycle ABI exactly:

- `void qemu_init(int argc, char **argv)`
- `int qemu_main_loop(void)` — its exit status is retained.
- `void qemu_cleanup(int status)` — receives the exact main-loop exit status.
- `void qemu_system_shutdown_request(int cause)` — the host-UI shutdown cause is value **5**.

Do not declare the main loop or cleanup as `void(void)`: doing so discards the return value and calls cleanup with the wrong ABI. The native fake-runtime regression returns status 37 and verifies that cleanup receives 37 and host-UI shutdown receives 5.

## Startup and validation

`src/QEMU/QEMURuntimeStatus.swift` resolves the library path from the generated manifest. `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI framework and then asks the native bridge to load the library with `RTLD_NOW` and resolve the required exports. `QEMUNativeRuntime` performs this preflight before starting QEMU, so missing dependent libraries and missing exports are reported before guest startup.

The package script validates the artifact's Mach-O type, physical iOS platform, arm64 architecture, and required exports. For a signed library, the standalone validator can additionally verify the code signature:

```sh
bash scripts/validate-qemu-runtime.sh /path/to/the/manifest-selected-QEMU-library
```

The standalone validator requires Apple tooling (`file`, `lipo`, `nm`, `vtool`, and `codesign`). It is a post-signing check; unsigned build artifacts are not expected to pass its code-signature check.

## JIT requirements

On physical iOS 17.4 and later, QEMU TCG startup requires an active StikDebug debugger/JIT session and the app's `get-task-allow` entitlement. On supported iOS 26+ TXM devices, the patched TCG allocator uses the StikDebug executable-region protocol. Simulator, tvOS, and visionOS builds do not use this physical-iOS JIT path.

## No-JIT fallback status

The currently packaged Akatsubaki QEMU runtime is JIT-dependent. A smaller TCG translation-block cache is still JIT and is **not** a no-JIT fallback. UTM upstream provides a separate `ios-tci` dependency target using `--enable-tcg-threaded-interpreter`, with an `iOS-SE` application scheme and an arm64 `ios-tci-arm64` dependency target. This is the preferred candidate for a stock-iOS fallback, but Akatsubaki has not yet built, packaged, mode-selected, or device-tested that runtime. Do not claim no-JIT guest execution until the TCI library and its complete transitive dependencies are embedded and a physical iPad boots a guest without requesting JIT.

Reference: [UTM iOS development and iOS SE build instructions](https://github.com/utmapp/UTM/blob/main/Documentation/iOSDevelopment.md).

## Firmware and writable disks

Windows and SteamOS UEFI profiles require matching firmware pairs:

- `OVMF_CODE.fd` with `OVMF_VARS.fd`
- `OVMF_CODE_4M.fd` with `OVMF_VARS_4M.fd`
- `edk2-x86_64-code.fd` with `edk2-x86_64-vars.fd`

The app copies the variable-store template into per-configuration Application Support storage and passes it as the second pflash device. It never writes UEFI variables into the signed app bundle. Existing symlinks and non-regular destination objects are not reused.

Launch Setup accepts a boot disk or installer/live ISO and an optional writable destination disk. ISO installation attaches the destination as a hard disk and keeps the ISO on a separate optical AHCI port. A blank sparse raw disk can be created in app storage; existing one-disk sessions remain supported.

## Verification status and limitations

- Runtime build and IPA embedding are defined in the workflows and packaging scripts.
- Physical-device runtime startup, guest boot, display, input, graceful shutdown, and disk persistence have **not** been verified on hardware.
- The native bridge is one-shot per app process because QEMU global-state reinitialization is not proven safe; relaunch Akatsubaki Emu before starting another QEMU session.
- The current runtime targets x86_64 guests. It is not an ARM64 guest runtime.
- tvOS and visionOS require separately built and validated platform runtimes.

A successful source check or artifact inspection is not evidence that a physical-device guest boots.

## JIT protocol detection

Physical iOS 26+ devices are classified through the same IOKit memory-map TXM query used by StikJIT. The host exposes UNKNOWN, STANDARD, and STIKDEBUG modes. UNKNOWN fails closed in the launch coordinator and QEMU patcher. STANDARD uses QEMU's normal split-WX allocator; STIKDEBUG uses the exported callback setter and the StikDebug executable-region protocol.
