# On-device Remote Pairing for Built-in StikJIT

Akatsubaki Emu can create the Apple Remote Pairing property-list file required by its embedded StikJIT helper. The pairing operation runs on the iPhone or iPad; it does not require the StikPair app, a Mac, USB, Finder, or a previously exported pairing file.

## Requirements

- A physical iPhone or iPad running iOS/iPadOS 27 or later.
- Developer Mode enabled.
- Local Network permission granted to Akatsubaki Emu.
- Akatsubaki Emu installed directly, not running inside LiveContainer.
- A local Wi-Fi network that allows Bonjour/mDNS discovery.

## Pairing

1. Open Akatsubaki Emu → Settings → JIT.
2. Tap **Generate device pairing file**.
3. Allow Local Network access when iOS asks.
4. Open Settings → Privacy & Security → Developer Mode → **Pair with Akatsubaki Emu**.
5. Enter the six-digit PIN shown in the pairing Live Activity.
6. Return to Akatsubaki. The generated plist is validated and saved automatically.
7. Select **Built-in StikJIT** and request JIT.

A continued-processing task keeps the pairing listener alive while Settings is foregrounded. The temporary Bonjour service is stopped when pairing completes, fails, or is cancelled. Regenerating an existing pairing file first clears the previous file and host identity, then creates a fresh pairing identity.

## Implementation and storage

- The Rust FFI uses the pinned MIT-licensed idevice crate and its remote_pairing API. It runs PairableHost, provides the PIN callback, and writes the temporary pairing file.
- The iOS StikPairingCoordinator publishes the JSON TXT records through Apple's NetService/mDNSResponder APIs and uses a continued-processing task while the user enters the PIN in Settings.
- StikJITPairingFileStore validates the generated plist and saves it at Application Support/StikJIT/pairingFile.plist. It persists the host identifier and altIRK in Application Support/StikJIT/host-identity.plist. Both files use complete file protection and are excluded from backups.
- JITCoordinator reads the same pairingFileURL through StikJITPairingFileStore and passes the pairing data to the embedded StikJIT helper. The helper uses a temporary extension-local copy and removes it after the request.
- The FFI returns the host altIRK as a short string and error text; pairing keys remain in the protected file and are not logged.

## Build

The pairing FFI is a static XCFramework with device-arm64 and simulator-arm64 slices. The release and iOS validation workflows run scripts/build_stikpair_ffi.sh before XcodeGen. That script installs rustfmt, runs Rust formatting and unit tests, builds both Apple targets, and assembles AkatsubakiPairingFFI.xcframework. The XcodeGen project links the XCFramework into stable and nightly iOS app targets.

## Licensing

The integration calls the MIT-licensed idevice crate pinned to revision 7bd551c16c6dd2e058740d85a2d9399a51a776e9. Its MIT notice is included in THIRD_PARTY_LICENSES/MIT-idevice.txt. Akatsubaki does not copy or bundle StikPair's MIT Non-Commercial app or wrapper source.

## Validation status

Static source tests cover the protocol integration, callback, protected storage, Bonjour service, task configuration, and build wiring. Rust compilation and the Xcode device build are performed by the hosted build workflow. A successful source build is not proof of pairing: the feature remains unverified until a physical iOS 27 device completes the Developer Mode PIN exchange, StikJIT accepts the saved file, and a QEMU guest completes the JIT handshake.
