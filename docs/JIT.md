# JIT activation and limitations

## Current VM launch flow

On supported physical iOS devices, the VM display requests JIT before starting QEMU. The app checks the installed process signature for get-task-allow=true, opens LocalDevVPN with the bundle-specific callback URL, then opens StikDebug for the app's bundle identifier and PID. On iOS 26+, the request includes universal.js for QEMU's breakpoint protocol. QEMU starts only after the coordinator confirms readiness; helper failure or timeout leaves the VM stopped.

LocalDevVPN and StikDebug remain separately installed applications. Akatsubaki Emu does not embed or redistribute their apps or VPN extensions.

## Readiness semantics

- iOS 17.4 through iOS 25: require CS_DEBUGGED. StikDebug can detach after enabling JIT on these releases, so a live ptrace attachment is not required.
- iOS 26 and later: require CS_DEBUGGED and a live P_TRACED debugger attachment. QEMU's split-W^X allocator uses the universal breakpoint protocol while StikDebug is attached and waiting. CS_DEBUGGED can remain set after detach and is not sufficient by itself.

The iOS 26 check uses sysctl(KERN_PROC_PID) and P_TRACED, and fails closed if the query fails. Clang supports __builtin_available in C and C++, so the version-specific behavior does not require changing the protocol file to Objective-C.

## Requirements

- Physical iPhone or iPad; simulator and Mac Catalyst are unsupported.
- iOS 17.4 or later for the StikDebug activation flow.
- A signing method that preserves get-task-allow=true in the installed app signature.
- Developer Mode enabled and a valid device pairing record imported into StikDebug.
- LocalDevVPN installed and its VPN configuration approved.
- If running inside LiveContainer, enable LiveContainer's Use LiveContainer's Bundle ID option.
- Entitlement inspection uses SecTaskCreateFromSelf and SecTaskCopyValueForEntitlement Security framework SPI. This sideload/developer workflow is not App Store-safe.

## QEMU executable-memory integration

On iOS 26+, scripts/patch_qemu_stikjit_ios.py patches QEMU's Darwin split-W^X TCG allocator. It requests one executable region through the StikDebug breakpoint protocol, maps a writable alias, and detaches after the one-time allocation. Every executable-memory path must use the supported allocator and preserve W^X.

## Built-in StikJIT status

The current implementation automates JIT activation through the separate StikDebug and LocalDevVPN applications. It does not yet embed the StikJIT XCFramework or provide a self-contained helper extension. StikJIT's documented architecture requires a second process because the host application cannot safely debug itself; the framework belongs in a separate iOS helper extension and does not create or launch that helper. StikJIT 2.x recommends Xcode 27.1 or newer, while the current Akatsubaki workflows use Xcode 26.2. The helper launch mechanism, framework packaging, and toolchain transition remain unverified.

References:
- StikDebug: https://github.com/StikDebug/StikDebug
- StikJIT (MPL-2.0): https://github.com/StikDebug/StikJIT
- StikJIT integration guide: https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- LocalDevVPN: https://github.com/jkcoxson/LocalDevVPN

## Validation status

The Python source-contract test covers CS_DEBUGGED, the iOS 26 P_TRACED requirement, and the older-iOS fallback. Physical-device testing is still required for signing, pairing, VPN connection, StikDebug attachment, QEMU executable-region preparation, and guest execution.
