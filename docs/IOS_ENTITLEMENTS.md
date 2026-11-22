# iOS memory entitlements

Akatsubaki Emu declares com.apple.developer.kernel.increased-memory-limit and com.apple.developer.kernel.extended-virtual-addressing in iSteam/iSteam.entitlements. A declaration in that file is only a request: the final code signature and provisioning profile must also authorize the entitlement.

## Enabling Increased Memory Limit

The iOS Settings screen includes an Entitlements page using the Apple Developer Services flow from [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) and its StosSign integration.

1. Set a compatible HTTPS Anisette server. The default is https://ani.sidestore.io.
2. Sign in with the Apple account and developer team that own the installed app's App ID.
3. Complete Apple's two-factor verification if requested.
4. Select the team containing the exact bundle ID shown by the current build (com.xthrx.isteam or com.xthrx.isteam.nightly).
5. Choose Enable Increased Memory Limit for Akatsubaki Emu.
6. After Apple accepts the capability change, reinstall or re-provision the app through SideStore or AltStore using the same Apple account so the installed profile contains the capability.

The integration only updates the current build's exact bundle identifier. It does not create App IDs or modify unrelated identifiers. It requests INCREASED_MEMORY_LIMIT, matching GetMoreRam's upstream implementation.

## Security and platform limits

- Apple must authorize the capability for the selected App ID and team. This does not bypass Apple's account eligibility or entitlement approval.
- The app cannot grant itself a privileged entitlement at runtime, rewrite its own code signature, or replace its installed provisioning profile from inside its sandbox.
- Apple account passwords are used only for the authentication request and cleared from the view model afterward. The Anisette identifier and adi.pb provisioning value are stored in the device Keychain; the password is not persisted by this integration.
- The Anisette server must be trusted by the user. The default is SideStore's public server; a compatible HTTPS endpoint can be configured in Settings.
- get-task-allow is a development-signing entitlement and is not granted by the Increased Memory Limit capability request.
- Extended Virtual Addressing remains declared in the entitlements file, but this GetMoreRam-compatible flow does not request it. Do not assume it is active until the signed app's effective entitlements and provisioning profile are inspected.
- A successful API response means Apple accepted the App ID capability update; it does not prove that the installed app's current signature has changed. The app must be re-provisioned and its effective entitlements inspected.

## Validation

The source-contract test is scripts/tests/test_entitlement_management.py. A complete iOS build, Apple-account authentication, successful capability activation, signed IPA inspection, and physical-device memory test are still required before this feature can be declared fully verified.
