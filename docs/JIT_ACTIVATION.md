# Automatic QEMU JIT activation

- **Status:** Implemented at source level; not yet verified on a physical device.
- **Scope:** General StikDebug JIT acquisition supports physical iOS 17.4+ devices. QEMU TCG specifically requires iOS 26+ and a recognised protocol (standard split-WX or TXM); simulator and Mac Catalyst are excluded from the device activation path.
- **Owner:** `JITCoordinator` coordinates helper apps and readiness; `VMDisplayViewController` gates QEMU startup; the existing QEMU native bridge and allocator own executable-region preparation.

## Startup lifecycle

1. When the user launches a VM, `LaunchSetupViewController` requests JIT through `JITCoordinator` before presenting the VM screen. It passes success/failure callbacks; `VMDisplayViewController` repeats the readiness check defensively before starting QEMU.
2. `JITCoordinator` checks the running process's actual `get-task-allow` entitlement using `SecTaskCreateFromSelf` and `SecTaskCopyValueForEntitlement` resolved from Security at runtime. If the entitlement is missing, the VM is not started.
3. The coordinator opens LocalDevVPN with `localdevvpn://enable?scheme=<bundle-id>`. The bundle ID is also registered as Akatsubaki's callback URL scheme, so stable and nightly builds can return to their own app instance.
4. LocalDevVPN submits its tunnel-start request and calls back to Akatsubaki after its own one-second delay. Akatsubaki waits a further two seconds, then opens StikDebug with the current bundle identifier and process ID using `stikdebug://enable-jit`.
5. On iOS 26+ devices, the app uses StikDebug's published hardware-identifier rules: iOS 26 applies the iPhone 14,2 and iPad 14,5 thresholds; iOS 27+ selects TXM except for iPad8,11 and iPad8,12. The StikDebug request includes the current PID and, only on TXM, `script-name=universal.js`.
6. On TXM, Akatsubaki records script readiness only after its own PID-targeted StikDebug request returns and both `CS_DEBUGGED` and `P_TRACED` are present. Generic debugger attachment is insufficient. The QEMU host readiness callback and guarded prepare callback fail closed until that handoff is recorded. Standard devices retain the normal split-W^X allocator.
7. Before `qemu_init`, the native bridge resolves QEMU's exported `isteam_qemu_set_jit_callbacks` and registers three host callbacks: `iSteamJITIsReady`, `iSteamJITPrepareRegionIfReady`, and `iSteamJITDetach`. QEMU separately resolves `iSteamJITIsSupported` and the tri-state protocol mode. The guarded prepare callback returns `NULL` rather than issuing an unhandled breakpoint when the TXM handoff is incomplete.

## First-time setup

- Install [StikDebug](https://github.com/StikDebug/StikDebug) and [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) separately.
- Open LocalDevVPN once and approve its VPN configuration.
- Import the device pairing file into StikDebug.
- When StikDebug shows its external JIT request confirmation, approve it; cancelling the request leaves QEMU stopped.
- Enable iOS Developer Mode.
- Sign Akatsubaki with a profile that preserves `get-task-allow`.
- When running inside LiveContainer, enable StikDebug's **Use LiveContainer's Bundle ID** option.

The helper apps are not embedded in Akatsubaki. They remain external dependencies and must be installed/configured by the user. The app uses LocalDevVPN's URL activation interface and StikDebug's documented JIT request interface; it does not redistribute either helper. TXM classification follows [StikDebug's ProcessInfo+TXM implementation](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/ProcessInfo+TXM.swift); the C helper preserves its model thresholds and iOS 27 exceptions while returning UNKNOWN for unrecognised iOS 26 hardware.
The **Increased Memory Limit** capability is separate from `get-task-allow`. Requesting that memory capability does not grant `get-task-allow` or make the process debuggable; the development provisioning profile must still provide `get-task-allow=true`.

## Failure handling and security

- Missing LocalDevVPN, missing StikDebug, an unavailable callback, or a missing `get-task-allow` entitlement prevents QEMU startup. The LocalDevVPN activation callback has a five-minute timeout; only one JIT acquisition may be active per process, and delayed callbacks from an expired request are ignored.
- On TXM, **Wait for Debugger is unavailable** because a generic debugger does not prove that `universal.js` is active. Settings selects StikDebug instead. If another debugger is already attached before Akatsubaki's handoff, detach it and request JIT again from Akatsubaki.
- LocalDevVPN's callback confirms that the tunnel-start request was submitted; it does **not** confirm that the VPN is connected. The readiness check is separate. If acquisition fails, verify the VPN is connected, StikDebug pairing is valid, Developer Mode is enabled, and the signing entitlement is present.
- The entitlement query uses Security task SPI. This is a sideload/developer workflow and is not suitable for App Store submission.
- The coordinator owns one foreground readiness poll and reports completion through callbacks; Launch Setup does not run a second polling loop. Every supported JIT path requires `CS_DEBUGGED`. On iOS 26+ TXM/SPTM devices, readiness additionally requires a live `P_TRACED` debugger and the process-local universal.js handoff flag. The flag is set only after Akatsubaki returns from its PID-targeted StikDebug request; generic debugger attachment cannot satisfy the gate. The QEMU prepare callback independently checks the same readiness state and returns `NULL` rather than issuing an unhandled breakpoint. Non-TXM devices use the normal split-W^X allocator and do not require a live debugger after JIT is enabled.

## Build integration

- `iSteam/JITCoordinator.swift` — helper orchestration, entitlement gate, callback handling and readiness polling.
- `iSteam/JIT26Protocol.c` / `.h` and `iSteam/JITHardwareModel.h` — runtime signing-entitlement inspection, StikDebug hardware-identifier detection, tri-state protocol selection, process-local universal.js handoff state, and fail-closed breakpoint preparation.
- `iSteam/Info.plist` — LocalDevVPN query permission and per-bundle callback URL scheme.
- `iSteam/AppDelegate.swift` — callback dispatch and app-activation readiness polling.
- `iSteam/LaunchSetupViewController.swift` — waits for the coordinator's success/failure callback before presenting the VM.
- `src/Display/VMDisplayViewController.swift` — repeats the readiness gate and starts QEMU only once.
- `iSteam/SettingsViewController.swift` — describes the automatic helper sequence.
- `project.yml` — links Security for the stable and nightly iOS targets.
- `scripts/patch_qemu_stikjit_ios.py` — selects the breakpoint allocator only on TXM devices; non-TXM iOS 26 devices retain the upstream split-W^X allocator.
- `scripts/tests/test_jit_protocol.py` and `scripts/tests/test_jit_hardware_model.py` — source-contract and compiled C matrix coverage for model thresholds, exceptions, unknown hardware and TXM handoff gating.
- `scripts/tests/test_jit_coordinator.py` — source-contract regression coverage.

## Validation status

- **Source readback:** completed for all changed implementation, project, settings and test files.
- **Static contract checks:** passed for the physical-device guards, entitlement lookup, LocalDevVPN and StikDebug URL construction, iOS 26 script gate, callback registration, Security linker flags, VM launch gate and source-validator contract.
- **Hosted validation:** the latest main source validator exposed a stale GuestMachine initialization-error assertion; this branch updates it and adds compiled C hardware-model matrix coverage plus TXM handoff regression tests. Hosted results must be checked after commit.
- **Not tested:** Xcode compilation, IPA packaging, installation, JIT activation on hardware, QEMU guest boot or persistent guest state.

Do not treat source-level integration as proof of a working JIT session until a physical-device build and VM launch have been tested.


## Fail-closed TXM detection

On physical iOS 26+ devices, Akatsubaki follows StikDebug's `ProcessInfo.hasTXM` hardware-identifier rules. iOS 26 uses the iPhone 14,2 and iPad 14,5 thresholds; iOS 27+ selects TXM except for iPad8,11 and iPad8,12. An unreadable or unrecognised iOS 26 hardware identifier is UNKNOWN and blocks launch. The QEMU patcher uses the tri-state protocol export and refuses unknown devices.
