# FEXCore and Box64 — iOS integration audit

**Checked:** 2026-11-25 10:53 UTC  
**Status:** FEXCore is the accepted primary dynamic translator, but is not integrated or built for iOS. Box64 is the secondary fallback candidate, not a concurrent engine. No runtime is promoted to operational by this audit.

## FEXCore primary

- Upstream: https://github.com/FEX-Emu/FEX
- License: MIT; retain the upstream copyright and licence with any imported source or binary.
- The upstream top-level CMake platform check supports only 64-bit Linux and Windows and rejects Apple platforms. Therefore, the complete FEX frontend cannot be built for iOS unchanged.
- FEXCore has its own CMake entry point and a C++ embedding API. Its public context interface exposes syscall, signal-delegator and thunk-handler hooks, thread creation/execution and context lifecycle. This is a plausible route to reuse the translator core without importing the Linux-only frontend, but a standalone iOS build has not been demonstrated.
- The core uses C++20 and has its own dependency graph. Pin an exact upstream commit and all transitive dependencies; do not track main for a reproducible device build.

### Darwin/iOS work required

1. **Core-only build:** add a reproducible CMake wrapper that configures only FEXCore, bypassing the top-level Linux/Windows frontend check without silently patching away required platform checks. Cross-compile for arm64-apple-ios with the Xcode iOS SDK and produce a static library/framework. Record every patch and dependency licence.
2. **Executable memory:** replace upstream assumptions about executable mappings with Kenran Butō's W^X/StikDebug allocator. Reuse the 32 MiB TXM arena where its semantics fit; test 16 KiB host pages, writable aliases, instruction-cache invalidation, allocation failure and JIT revocation. Never mark the backend available merely because the library links.
3. **Host feature interface:** report the real A16 ARM64 features and expose only x86 features the translator can implement correctly. Validate CPUID and instruction feature masks against the guest workload.
4. **Syscalls:** implement FEXCore's syscall-handler interface as an adapter to the Linux guest ABI. The existing Swift dispatcher is a small diagnostic subset, not enough for FEXCore or general Linux applications.
5. **Signals and threads:** implement the signal-delegator boundary, guest signal frames, clone/thread lifecycle, futexes, TLS, robust mutexes and process/thread identity. Darwin signals and thread primitives are not identical to Linux semantics.
6. **Memory and loader:** adapt guest mappings, mmap/mprotect/munmap, page permissions, ELF PT_INTERP, DT_NEEDED, symbol resolution, relocations and PT_TLS. A translator alone does not provide a Linux dynamic linker or filesystem.
7. **Thunks and libraries:** implement the thunk-handler contract and a versioned guest rootfs/library profile. Do not pass arbitrary Linux library calls directly into Darwin frameworks.
8. **Integration:** add a C++/Objective-C++ bridge with a pinned ABI. Keep one FEXCore context per guest process, route cache misses to FEXCore, and side-exit unsupported or unavailable work to the existing interpreter. The router must never run FEXCore and Box64 concurrently for one process.
9. **Validation:** run upstream FEXCore tests, translator differential tests, the two static ELF smoke guests through the FEXCore path, dynamic-loader/syscall/thread tests, and finally a physical iPad test. Record correctness before benchmarking.

## Box64 secondary fallback

- Upstream: https://github.com/ptitSeb/box64, MIT licensed and designed for Linux userlands on ARM64/RISC-V/LoongArch Linux hosts. Upstream Box64 is not a drop-in Darwin/iOS runtime.
- iOS snapshot: https://github.com/cloverfield11/box64-ios-library, also MIT. It provides a static-library entry point (box64_library_main when built with BUILD_LIB) that matches the symbol expected by Akatsubaki's existing Box64Bridge.
- The inspected snapshot reports JIT/dynarec disabled and a Powder Toy x86-64 path at roughly 4.5–5 FPS through a custom MetalGL bridge. Its touch bridge is targeted to the tested Powder Toy binary layout. This is a valuable no-JIT proof of concept, not evidence of broad Linux game compatibility.
- The snapshot is based on an older Box64 commit and contains game-specific workarounds. Do not transplant those hard-coded guest addresses into Kenran Butō. Audit the complete fork diff, build scripts, transitive libraries and symbols before packaging.
- **Integration decision:** retain Box64 as a secondary fallback. Build and package it only after the same smoke corpus passes through the static library, its guest ABI/syscall contract is explicit, and the iOS display/input adapters are separated from game-specific hacks. FEXCore wins whenever both are operational; Box64 is selected only if FEXCore is unavailable or rejected for that workload.

## 2026-11-25 20:50 UTC update — diagnostic stdin

The static ELF diagnostic path no longer treats every `read(0, ...)` as immediate EOF:

- `LinuxSyscallDispatcher` now has a bounded, interruptible stdin queue. Empty reads wait for input, stop interrupts a blocked read, and a failed guest-memory write does not consume queued bytes.
- `GuestMachine` exposes enqueue/close operations; `LinuxELFRuntime` buffers input received before the guest is ready and flushes it before the ready transition while holding the runtime lock; `ConsoleViewController` provides a text input field.
- `scripts/tests/test_linux_syscall_dispatcher.swift` covers syscall read semantics. `scripts/tests/test_guest_console_input.py` checks queue ordering and lock scope. The latter's source-contract change is commit `35257824`.
- These changes provide text stdin only for the bounded static-ELF diagnostic runtime. They do not add a guest framebuffer or connect the QEMU/VNC gamepad and touch controls to `GuestMachine`. No physical-device interactive guest test is verified.
- GitHub main was last synchronized at `74ebb78a`; repository validation #1207 and AOT validation #272 were pending at the last check. GitLab main had a style-only follow-up at `56df7ab0`. No successful hosted result is claimed here.

## Other runtime gaps discovered

| Area | Current repository state | Required next work |
|---|---|---|
| Linux x86-64 | Static ELF loader, process stack, bounded interpreter and small AOT subset; native GuestMachine smoke test has been added but CI/device execution is pending | Finish the physical iPad first-playable path; then expand syscall, dynamic-loader, TLS, thread, signal and filesystem semantics |
| Full-system Linux/Windows | QEMU JIT and TCI packaging workflow exists; manually triggered and artifact upload is gated by QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED; no hosted artifact or physical guest boot is verified | The app's project-authored source files listed in `.reuse/dep5` are GPL-3.0-or-later; the UTM-derived bridge material is Apache-2.0 and generally compatible. Audit the exact QEMU file-level source/object closure because GPL-2.0-only QEMU components remain incompatible with GPLv3 in a combined work. The latest visible QEMU workflow run (#34, commit 4e1a210) failed at YAML parsing on line 301; current main has the corrected upload step, but no later build has verified it. Build JIT and TCI, boot a known-good Linux image, then test Windows/SteamOS separately |
| Windows PE | PE metadata parser and read-only loader inspection exist; WindowsRuntime still refuses launch | Map PE sections and relocations, resolve imports/DLLs, implement Win32/NT services, and pair Wine/Proton with exactly one x86-64 engine |
| Anti-cheat | Router correctly refuses to claim kernel-driver compatibility | Require publisher support and a supported Windows kernel; user-mode translation cannot provide kernel-mode EAC/anti-cheat drivers or bypass their checks |
| Graphics | Metal framebuffer presentation exists for current host/QEMU paths; DirectX-to-Vulkan-to-Metal is not integrated | Port and validate the required Vulkan subset, then a compatible Direct3D translation layer. DXVK is designed for Linux/Wine and Vulkan; it is not a direct iOS drop-in |
| Audio/input | Host/prototype services exist, but complete guest-device adapters are not proven | Add guest audio device/codec path, SDL-like input abstraction, controller/touch/keyboard mapping, pointer lock and lifecycle tests |
| Storage/persistence | External-drive and block-device abstractions exist; complete guest filesystem, snapshots and restore are not proven | Validate security-scoped external drives, disk persistence, save slots, reset/restore, app relaunch and cleanup |
| Steam | The current core-only path imports ELF files and launches a text-console guest; no complete Steam client/store/game-install path is verified | Start with library metadata and supported game import; do not imply that the Steam desktop client runs on iOS |
| Android/VR/tvOS/visionOS | Prior experiments/requests exist, but they are not part of the first playable acceptance gate | Keep behind platform-specific capability checks after iOS guest execution, graphics and input are stable |

## Graphics compatibility boundary

- MoltenVK maps a Vulkan subset onto Metal and supports iOS/tvOS, but its upstream project is now community-maintained on a best-effort basis. It is a plausible Vulkan portability layer, not proof that a Linux Vulkan driver stack can run on iOS.
- DXVK translates Direct3D 8/9/10/11 to Vulkan for Linux/Wine. It expects Wine and a compatible Vulkan driver/feature set. It cannot be dropped into the iOS app without the Linux user-mode, Wine and Vulkan host layers.
- Direct3D 12 needs a separate vkd3d-proton path; it is not covered by DXVK's D3D8–11 scope. Validate API coverage, shader features, memory sharing and Metal synchronization on the actual iPad before claiming support.

## Guest input/display integration gap

- The static Linux ELF diagnostic runtime captures stdout/stderr and now accepts bounded, interruptible text stdin through the console field; it still has no guest framebuffer, full HID/controller event sink, dynamic linker or general Linux ABI.
- Touch controls, hardware keyboard/function keys, GameController and Metal display updates are wired to the QEMU/VNC path, not directly to GuestMachine.
- Do not claim that QEMU/VNC input or graphics work for the static ELF interpreter. The two execution/display paths still need a shared guest-device boundary.
- After the first full-system boot, unify keyboard/controller/touch input, key-up cleanup, Metal frames, audio, disk I/O and lifecycle handling behind guest-device interfaces.

## First-playable order

1. Keep the current core-only IPA as diagnostic coverage only. It is unsigned, ARM64/iPhoneOS and QEMU-free, built from d2d13b3d; it predates the newer sign-extension/operand-size changes on GitLab main. It does not satisfy the full-system first-playable requirement.
2. Keep QEMU TCI/no-JIT as the P0 full-system route. Complete qualified file-level and combined-work QEMU/UTM licensing review first; keep QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED unset until approval. Do not bypass the release gate.
3. After licensing approval, manually build the pinned TCI runtime, verify architecture, manifest, exported symbols and checksums, package the QEMU-enabled iOS IPA, sign/install it, and boot a known-good x86-64 Linux image on a physical iPad with JIT disabled.
4. Verify repeat boot, clean shutdown, stop/relaunch cleanup, persistent writable disk, VNC-to-Metal display, keyboard, controller and touch input. No physical iPad boot or interactive guest test is currently verified.
5. If QEMU distribution cannot be approved, prototype Bochs 3.1 as a separate LGPL full-system alternative. It is not integrated or tested on iOS; its headless/no-GUI mode does not provide the required Metal display/input path.
6. Once the no-JIT full-system baseline is stable, validate optional TXM/AOT acceleration on the physical iPad. StikDebug 3.2.2+ is the documented iOS/iPadOS 27+ pairing path; simulator/host AOT results are not physical-device evidence.
7. Build and validate FEXCore as the primary dynamic x86-64 user-mode translator, with the existing interpreter as a fail-closed fallback. Keep Box64 as a measured secondary option and do not run both engines concurrently for one guest process.
8. Expand the Linux dynamic loader, PT_INTERP/DT_NEEDED/PT_TLS, symbols/relocations, syscall, signal, thread, futex, filesystem and block-device semantics. Then proceed to Windows PE/DLL, Win32/NT, Wine/Proton, DirectX/Vulkan/Metal and broader Steam/Windows compatibility.
9. Keep Android, VR, tvOS and visionOS behind platform capability gates until iOS guest execution, display, input, storage and lifecycle are reliable.

**Verification rule:** source code, a build workflow, a loadable dylib, a host smoke test and a simulator run are separate evidence levels. The backend registry must remain fail-closed until a concrete iOS artifact executes a known guest correctly on a physical iPad.

## Repository synchronization status

- Current write target is the existing GitLab main branch. At this audit GitLab main is c0d333f83237a1a81b6b1ce2ab2a806ebd153230; GitHub main was last observed at f93008dfb5c6143c4e9dc256fca07a363020eccd and remains behind. No force-push, branch creation, merge or manual sync was attempted.
- GitLab main includes CWDE/CDQE/CDQ/CQO AOT/interpreter support (translator v10), CBW/CWD interpreter support, portable ELF smoke tests, the REX.W-over-0x66 correctness fix, AOT block-entry coverage and dynamic AOT-version source validation.
- GitLab pipelines #1254, #1257, #1258, #1259, #1261 and #1263 failed before runner assignment with ci_quota_exceeded; no current-head hosted tests ran. The latest source-validator changes have not yet had a successful pipeline.
- The available unsigned ARM64 diagnostic IPA and its ZIP are built from d2d13b3d, not c0d333f8. They contain no QEMU runtime and must not be described as a current-head build.
- QEMU TCI runtime/release jobs remain gated by QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED. No TCI runtime artifact, QEMU-enabled IPA, physical SideStore installation or physical iPad guest boot is verified.
- Keep runtime capability reporting fail-closed until a known guest boots and passes interaction, storage and repeat-launch checks on a physical iPad.

No FEXCore/Box64 iOS backend, full-system guest boot, physical-device graphics/input, or QEMU distribution approval is claimed.