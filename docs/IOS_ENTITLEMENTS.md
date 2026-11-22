# iOS memory entitlements

Akatsubaki Emu declares `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing` in `iSteam/iSteam.entitlements`. A declaration in that file is only a request: the final code signature and provisioning profile must also authorize the entitlement.

## Enabling Increased Memory Limit

The iOS Settings screen includes an **Entitlements** page based on the Apple Developer Services flow used by [GetMoreRam](https://github.com/hugeBlack/GetMoreRam):

1. Open Settings → Entitlements.
2. Sign in with the Apple account that owns the app's App ID and complete two-factor verification if requested.
3. Select the developer team that contains the exact bundle ID shown by this installation (`com.xthrx.isteam` or `com.xthrx.isteam.nightly`).
4. Choose **Enable Increased Memory Limit for Akatsubaki Emu**.
5. Reinstall/re-sign the app through SideStore or AltStore using the same account so the installer obtains a refreshed provisioning profile.

The integration looks up only the current build's exact bundle identifier and requests the `INCREASED_MEMORY_LIMIT` capability, matching GetMoreRam's upstream implementation. It does not modify other App IDs.

## Authentication and data handling

- Apple authentication and App ID capability updates use the pinned StosSign package, following GetMoreRam's API flow.
- Anisette data is obtained through the SideStore Anisette V3 service. The service URL defaults to `https://ani.sidestore.io`.
- The Apple ID password is held only while the sign-in request runs; this integration does not persist it in UserDefaults or Keychain.
- Only the Anisette device identifier and provisioning blob are stored in the iOS Keychain.
- Sensitive Anisette headers, machine identifiers and one-time passwords are not written to application logs.
- Apple controls authentication, team permissions, App ID eligibility and capability availability. Errors are displayed as failures; they are not treated as successful updates.

## Important limits

- The app cannot grant itself a privileged entitlement at runtime, rewrite its own code signature, or replace its installed provisioning profile from inside its sandbox.
- Apple invalidates provisioning profiles when an App ID's capabilities change. Reinstallation/re-provisioning is therefore required; see [Apple's capability guidance](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).
- The account must have permission to modify the App ID, and the App ID must already exist in the selected team. This does not bypass Apple's eligibility rules for free or paid developer accounts.
- `get-task-allow` is a development-signing entitlement and is not granted by the Increased Memory Limit capability request.
- Extended Virtual Addressing remains declared in the entitlements file, but this GetMoreRam-compatible flow does not request it. Do not assume it is active until the signed app's effective entitlements and provisioning profile are inspected.
- A successful API response means Apple accepted the App ID update; it does not prove that the currently installed binary carries the entitlement. Verify the effective entitlements after re-signing and test memory headroom on a supported physical device.

## Validation

The source-contract test is `scripts/tests/test_entitlement_management.py`. Hosted Apple-platform compilation and physical-device provisioning still need to be verified.
