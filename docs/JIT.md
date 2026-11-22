# JIT activation and limitations

## Current VM launch flow

On supported physical iOS devices, the VM display now requests JIT before starting QEMU:

1. The app checks for iOS 17.4 or later and excludes simulator and Mac Catalyst.
2. It checks the installed process signature for get-task-allow=true. The entitlements file in the repository is not treated as proof that the installed signature preserved the entitlement.
3. It opens LocalDevVPN using the enable URL and supplies the app's bundle identifier as the callback URL scheme.
4. LocalDevVPN returns to Akatsubaki Emu. The coordinator waits briefly, then opens StikDebug for this process using its bundle identifier and PID.
5. On iOS 26+, the request includes universal.js so StikDebug can service the QEMU breakpoint protocol.
6. The coordinator waits for a verified readiness result. QEMU is started only through the readiness callback; timeout or helper failure leaves the VM stopped.

LocalDevVPN and StikDebug remain separately installed applications. Akatsubaki Emu does not embed or redistribute their apps or VPN extensions.

## Readiness semantics

The readiness test is version-aware:

- iOS 17.4 through iOS 25: require the CS_DEBUGGED code-signing status. StikDebug can detach after enabling JIT on these releases, so requiring a live ptrace attachment would incorrectly reject a successful enablement.
- iOS 26 and later: require both CS_DEBUGGED and a live P_TRACED debugger attachment. QEMU's split-W^X allocator calls the universal breakpoint protocol while StikDebug is attached and waiting. CS_DEBUGGED alone can remain set after a debugger detaches and is not sufficient to prove the breakpoint handler is available.

The iOS 26 check uses sysctl(KERN_PROC_PID) and P_TRACED. If that query fails, readiness fails closed. The C implementation uses Clang's __builtin_available spelling so the OS-version split can be expressed in C.

## Requirements

- Physical iPhone or iPad; simulator and Mac Catalyst are unsupported.
- iOS 17.4 or later for the StikDebug activation flow.
- A signing method that preserves get-task-allow=true in the installed app signature.
- Developer Mode enabled and a valid device pairing record imported into StikDebug.
- LocalDevVPN installed and its VPN configuration approved.
- If running inside LiveContainer, enable LiveContainer's Use LiveContainer's Bundle ID option before requesting JIT.
- The entitlement check uses SecTaskCreateFromSelf and SecTaskCopyValueForEntitlement Security framework SPI. This sideload/developer workflow is not App Store-safe.

## QEMU executable-memory integration

On iOS 26+, scripts/patch_qemu_stikjit_ios.py patches QEMU's Darwin split-W^X TCG allocator. It requests one executable region through the StikDebug breakpoint protocol, maps a writable alias, and detaches after the one-time allocation. Every executable-memory path must use the supported allocator and preserve W^X; the universal script does not make arbitrary allocators JIT-capable.

The live-debugger check is deliberately limited to iOS 26+. Older supported iOS releases use the existing JIT enablement path and may no longer have a live ptrace attachment after StikDebug returns.

## Built-in StikJIT status

The current implementation automates JIT activation through the separate StikDebug and LocalDevVPN applications. It does not yet embed the StikJIT XCFramework or provide a self-contained helper extension.

StikJIT's documented architecture requires a second process because the host application cannot safely debug itself. The framework belongs in a separate iOS helper extension, with the host PID and pairing-file bytes passed over IPC. The framework does not create or launch that helper. StikJIT 2.x recommends Xcode 27.1 or newer; the current Akatsubaki workflows are pinned to Xcode 26.2. The helper launch mechanism, framework packaging, and toolchain transition must be resolved and tested before claiming built-in JIT.

References:

- StikDebug: https://github.com/StikDebug/StikDebug
- StikJIT (MPL-2.0): https://github.com/StikDebug/StikJIT
- StikJIT integration guide: https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- LocalDevVPN: https://github.com/jkcoxson/LocalDevVPN

## Validation status

The Python source-contract test covers the CS_DEBUGGED check, the iOS 26 P_TRACED requirement, and the older-iOS fallback. A physical-device test is still required for signing, pairing, VPN connection, StikDebug attachment, QEMU executable-region preparation, and guest execution. GitLab's latest validation pipeline was blocked before runner startup by ci_quota_exceeded.
