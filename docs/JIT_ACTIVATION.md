# Automatic QEMU JIT activation

- **Status:** Built-in StikJIT helper source and Xcode targets are integrated; a signed device build and physical-device JIT session are not yet verified.
- **Scope:** Physical iOS devices. External StikDebug remains available from iOS 17.4; embedded StikJIT requires iOS 26+ and is disabled in LiveContainer.
- **Owner:** `JITCoordinator` coordinates the selected helper and readiness; the ExtensionKit helper owns StikJIT/DDI work; `VMDisplayViewController` gates QEMU startup; the QEMU native bridge and allocator own executable-region preparation.

## Built-in StikJIT architecture

The iOS app embeds an ExtensionKit helper, not a second runnable app. The helper contains the pinned StikJIT 2.0.1 XCFramework and runs outside the host process so it can attach a debugger to Akatsubaki without self-attach deadlocking.

1. Import a device pairing file in Settings → JIT. Akatsubaki validates it as a property-list dictionary and stores it at `Application Support/StikJIT/pairingFile.plist`. The file contents are never logged.
2. Start LocalDevVPN through its documented `localdevvpn://enable?scheme=<bundle-id>` URL. Its callback means the start request was submitted, not that the tunnel is connected.
3. Akatsubaki sends the current PID and pairing-file bytes over an ExtensionFoundation XPC session to the embedded helper.
4. The helper writes a temporary extension-local pairing file, then synchronously calls `StikJIT.enableJIT` on one serial queue. StikJIT checks RSD reachability, downloads/mounts/verifies the appropriate Developer Disk Image, and starts the selected universal script.
5. The host keeps the XPC session alive and polls its own debugger state while StikJIT's script waits. QEMU starts only after the host reports `CS_DEBUGGED`; TXM/SPTM devices additionally require `P_TRACED`.
6. QEMU invokes the existing universal breakpoint callbacks to prepare executable regions and then calls `iSteamJITDetach`. That breakpoint ends the script, allowing the helper's synchronous call to return. The helper reports the final result over XPC.
7. If the helper fails before readiness, QEMU remains stopped. If the helper fails during the breakpoint handshake, the failure is surfaced to the launch flow. A VM display already pushed by Launch Setup is popped, and a directly launched VM display stops VNC, QEMU and the GPU backend.

The helper's persistent DDI cache lives under its own Library container. The temporary pairing file is removed when the request completes. The host retains the imported pairing file so future requests do not require re-importing it.

## External helper paths

- **StikDebug mode:** still opens the separately installed StikDebug app using `stikdebug://enable-jit`. It remains the fallback for devices that cannot run the embedded helper.
- **LocalDevVPN:** remains a separately installed and user-approved app for both StikDebug and Built-in StikJIT. Its packet-tunnel provider requires Apple's `packet-tunnel-provider` Network Extension entitlement and matching provisioning profile. Akatsubaki's current signing setup does not include that entitlement; embedding the provider without Apple's approval would produce an extension that cannot be installed/started reliably. Therefore this change does not copy or embed LocalDevVPN's app or tunnel extension.
- **LiveContainer:** Built-in StikJIT is disabled because LiveContainer cannot create the required ExtensionKit helper. Choose StikDebug (and enable its **Use LiveContainer's Bundle ID** option) or Wait for Debugger instead.

## Requirements and first-time setup

- Physical iPhone/iPad on iOS 26 or later for Built-in StikJIT; iOS 17.4 or later for external StikDebug.
- Akatsubaki must be signed with `get-task-allow=true`; Increased Memory Limit is a separate entitlement and does not grant it.
- Enable iOS Developer Mode.
- Install LocalDevVPN separately and approve its VPN configuration.
- Obtain a valid device pairing file through AFC/Finder, `idevice_pair`, or another supported pairing method, then import it in Settings → JIT.
- Use a nearby Wi-Fi network where possible. If no Wi-Fi is available, enable cellular data, connect LocalDevVPN, and follow StikJIT's documented Airplane Mode procedure.
- A successful helper handoff is not proof of a usable VM. QEMU must complete the matching allocator protocol before guest execution.

## Failure handling and security

- Unknown iOS 26 hardware protocol mode blocks helper handoff; the app does not guess between the standard and TXM allocators.
- LocalDevVPN's URL callback does not prove the tunnel is connected. StikJIT's RSD reachability check is authoritative for its next step.
- StikJIT's DDI download, mount, pairing, and debugger errors are returned to Akatsubaki and shown to the user.
- The host's entitlement check uses Security task SPI and is a sideload/developer workflow, not an App Store-safe design.
- Pairing data crosses the XPC boundary only for the active request; the helper's temporary copy is deleted after completion. The imported host copy is kept in the app's protected Application Support container for reuse.
- Built-in StikJIT runs only on a physical iOS 26+ device and is hidden from the usable method path in LiveContainer. The app keeps the external StikDebug and Wait for Debugger choices.

## Build integration

- `iSteam/JITCoordinator.swift` — pairing-file import, method selection, LocalDevVPN handoff, helper launch and host-side readiness polling.
- `iSteam/JITExtensionPoint.swift` — declares the app's ExtensionKit helper point.
- `iSteam/AkatsubakiJITHelperCoordinator.swift` — starts the embedded helper and keeps its XPC session alive during QEMU's breakpoint handshake.
- `iSteamJITHelper/Shared` — XPC request/response contract.
- `iSteamJITHelper/Helper` — serial StikJIT execution, temporary pairing-file handling and stable/nightly extension binding.
- `iSteamJITHelper/Info.plist` and `Info-nightly.plist` — host-specific ExtensionKit point identifiers.
- `scripts/fetch_stikjit.sh` — downloads StikJIT 2.0.1 and verifies SHA-256 before XcodeGen runs.
- `project.yml` — embeds one matching iOS 26 helper extension in stable and nightly app targets.
- `.github/workflows/release.yml` and `.github/workflows/validate-ios-build.yml` — fetch the pinned XCFramework before project generation; iOS validation now compiles the device target so the helper extension is included.
- `iSteam/Info.plist` — grants Bonjour discovery metadata for `_remotepairing._tcp`.

## Third-party licensing

- StikJIT 2.0.1 is distributed under MPL-2.0. Its XCFramework is downloaded from the upstream release at build time and its license is included in `THIRD_PARTY_LICENSES/MPL-2.0.txt`.
- LocalDevVPN and StikDebug app binaries/source are not redistributed by this integration. Their upstream projects retain their own licenses.

## Validation status

- **Source integration:** written on a feature branch based on the current TXM fail-closed JIT branch.
- **Static source checks:** pending execution after commit; the new regression tests cover helper target wiring, pairing-file handling, XPC session lifetime, SHA pinning, workflow ordering, and the LocalDevVPN entitlement boundary.
- **Hosted CI:** not yet run for this branch. The project has recent GitLab runner-quota failures before job startup.
- **Not verified:** XcodeGen project generation, Xcode 27.1 compilation of the StikJIT 2.0.1 module, IPA packaging/signing, extension installation, LocalDevVPN tunnel activation, RSD pairing/DDI mount, TXM breakpoint handshake, QEMU guest boot or persistence.

Do not describe this integration as device-working until the iOS 26 extension is built, installed with a valid signing profile, and a physical QEMU guest completes the JIT breakpoint handshake.
