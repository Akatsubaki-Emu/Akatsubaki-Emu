# Akatsubaki Emu QEMU runtime contract

This document describes the QEMU runtime artifact used by Akatsubaki Emu. It does not implement or bundle the QEMU engine; the runtime is built from the UTM/QEMU source by the dedicated workflow.

## Build and embedding

The source tree defines two physical-iOS arm64 UTM runtime variants:

- `iOS`: native TCG/JIT runtime; it requires the StikDebug callback ABI.
- `iOS-TCI`: threaded TCG interpreter runtime; it must not require executable-memory JIT.

The intended workflow builds both archives, packages JIT under `QEMU/JIT` and TCI under `QEMU/TCI`, merges the variants, and embeds the combined `Frameworks/` and `QEMU/` directories in the iOS release IPA.

**This pipeline is not yet verified.** The current workflow requests scheme `iOS-TCI` and assumes product `UTM.app`; the pinned upstream UTM build matrix uses platform `ios-tci`, shared scheme `iOS-SE`, and product `UTM SE.app`. Correct scheme/product discovery before relying on the archive.

The merger is also unsafe in its current form: an output such as `build/../outside` passed the prefix check and was deleted by `rm -rf`; shared-framework collisions can also fail or overwrite content. Restrict output to a validated basename beneath a canonical non-symlink build directory, and compare shared framework contents before merging. Do not run the merger against real artifacts until these defects are fixed.

Build verification: no successful hosted dual-runtime build and combined artifact have been recorded.

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

`src/QEMU/QEMURuntimeStatus.swift` resolves the library path from the generated manifest. `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI directory and asks the native bridge to load the library with `RTLD_NOW` and resolve the mode-specific exports. `QEMUNativeRuntime` performs this preflight before starting QEMU.

The app-side TCI selection path bypasses the JIT callback/readiness check, but automatic accelerator selection is not yet correct: `.automatic` currently maps directly to `.jit` rather than selecting TCI when JIT is unavailable and a validated TCI runtime is present. Do not enable automatic fallback until both packaged runtime variants pass validation.

Validate a signed library with the matching mode:

```sh
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library jit
bash scripts/validate-qemu-runtime.sh /path/to/manifest-selected-QEMU-library tci
```

The standalone validator requires Apple tooling (`file`, `lipo`, `nm`, `vtool`, and `codesign`). It is a post-signing check; unsigned build artifacts are not expected to pass its code-signature check.

## JIT requirements

On physical iOS 17.4 and later, **JIT mode** requires an active StikDebug debugger/JIT session and the app's `get-task-allow` entitlement. On supported iOS 26+ TXM devices, the patched TCG allocator uses the StikDebug executable-region protocol. The StikDebug allocator patch must be gated to the JIT build; the current TCI patch path still needs that correction.

TCI uses the threaded TCG interpreter and bypasses the physical-iOS JIT readiness path. This does not prove that the current TCI artifact builds, loads, or boots.

## No-JIT fallback status

UTM upstream provides a separate `ios-tci` dependency target using `--enable-tcg-threaded-interpreter`, with the shared `iOS-SE` scheme and `UTM SE.app` product. Akatsubaki has source for a TCI build/package path, but the following blockers remain:

1. Correct the workflow's scheme and product discovery to match the pinned UTM revision.
2. Apply the StikDebug executable-memory patch only to the JIT build.
3. Require the four lifecycle/shutdown exports in TCI and reject `isteam_qemu_set_jit_callbacks`.
4. Fix merger path containment and shared-framework collision handling.
5. Make the final IPA validator inspect both manifests and enforce the correct per-mode export policy.
6. Make `.automatic` choose JIT only when JIT is ready, otherwise choose TCI only when the TCI artifact is validated and loadable.

Do not claim no-JIT guest execution until the TCI library and complete transitive dependencies are embedded, the final IPA validates both modes, and a physical iPad boots a guest without requesting JIT.

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
