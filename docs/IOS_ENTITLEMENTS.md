# iOS memory entitlements

Akatsubaki Emu declares `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing` in `iSteam/iSteam.entitlements`. A declaration in that file is only a request: the final code signature and provisioning profile must also authorize the entitlement.

## Enabling Increased Memory Limit

The iOS Settings screen includes an **Entitlements** page based on the Apple Developer Services flow used by [GetMoreRam](https://github.com/hugeBlack/GetMoreRam):

1. Set a compatible HTTPS Anisette server. The default is `https://ani.sidestore.io`.
2. Sign in with the Apple account and developer team that own the installed app's App ID.
3. Complete Apple's two-factor verification if requested.
4. Select the team containing the exact bundle ID shown by the current build (`com.xthrx.isteam` or `com.xthrx.isteam.nightly`).
5. Choose **Enable Increased Memory Limit for Akatsubaki Emu**.

The integration requests the `INCREASED_MEMORY_LIMIT` capability only for the exact bundle identifier of the running build. It does not create, enumerate for modification, or change unrelated App IDs. The Anisette device identifier and provisioning data are stored in the iOS Keychain. The Apple account password is held only in memory for authentication and cleared when the sign-in operation finishes.

## Important limits

- The app cannot grant itself a privileged entitlement at runtime, rewrite its own code signature, or replace its installed provisioning profile from inside its sandbox.
- After Apple accepts the App ID capability change, reinstall/re-provision through SideStore or AltStore using the same Apple account. The installer must obtain a refreshed provisioning profile for the entitlement to become effective.
- The account must have permission to modify the App ID, and the App ID must already exist in the selected team. This does not bypass Apple's eligibility rules for free or paid developer accounts.
- `get-task-allow` is a development-signing entitlement and is not granted by the Increased Memory Limit capability request.
- Extended Virtual Addressing remains declared in the entitlements file, but this GetMoreRam-compatible flow does not request it. Do not assume it is active until the signed app's effective entitlements and provisioning profile are inspected.
- Apple Developer Services authentication is handled by StosSign. Authentication failures (including Apple's `-80045` response) are surfaced rather than treated as a successful capability update.

## Validation

The source-contract test is `scripts/tests/test_entitlement_management.py`. A successful API response means Apple accepted the App ID update; it is not proof that a later installed build carries the entitlement. Verify the effective entitlements in the reinstalled app's code signature and test memory headroom on a supported physical device.
