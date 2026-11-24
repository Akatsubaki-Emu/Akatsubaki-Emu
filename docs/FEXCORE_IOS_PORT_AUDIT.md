# FEXCore and Box64 — iOS integration audit

**Checked:** 2026-11-24  
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

## Other runtime gaps discovered

| Area | Current repository state | Required next work |
|---|---|---|
| Linux x86-64 | Static ELF loader, process stack, bounded interpreter and small AOT subset; native GuestMachine smoke test has been added but CI/device execution is pending | Finish the physical iPad first-playable path; then expand syscall, dynamic-loader, TLS, thread, signal and filesystem semantics |
| Full-system Linux/Windows | QEMU JIT and TCI packaging workflow exists; manually triggered and artifact upload is gated by QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED; no hosted artifact or physical guest boot is verified | Resolve QEMU GPLv2 compatibility with the GPLv3 app and preserve UTM's Apache-2.0 notices before distributing artifacts. The latest visible QEMU workflow run (#34, commit 4e1a210) failed at YAML parsing on line 301; current main has the corrected upload step, but no later build has verified it. Build JIT and TCI, boot a known-good Linux image, then test Windows/SteamOS separately |
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

## First-playable order

1. Run the manual Build Core-Only iOS IPA workflow on GitHub main. Install the unsigned IPA through SideStore, import hybrid_xchg_smoke.elf and hybrid_runtime_smoke.elf, and verify both markers and exit code 0 on the physical iPad.
2. Verify repeat launch, CPU reset, guest-page cleanup after stop, failed-load cleanup, app relaunch and persistent guest files. The new native GuestMachine test covers reset and page cleanup in CI, but is not a substitute for the physical device.
3. Update StikDebug to 3.2.2 or newer and import a fresh RPPairing file before testing AOT. Confirm the TXM 32 MiB arena on the iPad and test JIT revocation/fallback.
4. Complete basic guest display, audio and input against the actual runtime. Keep this ahead of broad OS compatibility or UI polish.
5. Build and validate FEXCore as the primary dynamic user-mode engine; use Box64 only as a measured fallback.
6. Build QEMU TCI/JIT only after the licence gate is approved; boot a known-good Linux image before attempting Windows 10 or SteamOS.
7. Add Wine/Proton, DirectX/Vulkan/Metal and Windows PE execution only after the underlying user-mode engine and syscall/loader layers are operational.

**Verification rule:** source code, a build workflow, a loadable dylib, a host smoke test and a simulator run are separate evidence levels. The backend registry must remain fail-closed until a concrete iOS artifact executes a known guest correctly on a physical iPad.

## Repository synchronization blocker

The current repository configuration and the active engineering write-target instruction disagree:

- GitLab project metadata identifies this project as imported from GitHub, with `import_type=github` and GitHub's repository URL as `import_url`.
- The repository's `docs/GIT_SYNC.md` says GitHub is canonical and GitLab is a downstream mirror. The existing `blank.yml` and `reconcile-gitlab-main.yml` workflows sync GitHub to GitLab; they do not sync GitLab to GitHub. The Git sync documentation says GitLab CI is retired.
- The active project instructions for this engineering work designate GitLab main as the write target. I have therefore committed to GitLab main and have not pushed to GitHub or changed mirror direction.
- At this audit, GitHub main is `42a0687b76a9f9a125b581ffa829d6766f7a42f8` and GitLab main is `0e3995a3a749e137e34820203e13488727869a00`. GitLab's compare API confirms the latter is a direct child of the former, so the current delta is a fast-forward candidate and requires no force push.
- GitHub Actions run on GitHub, not on the GitLab-only commits. The AOT workflow still shows only the old run #213, the core-only IPA workflow has zero runs, and the QEMU workflow's latest visible run #34 is from an older commit. The GitLab pipeline also failed before runner assignment with `ci_quota_exceeded`.

**Required owner decision:** explicitly authorize a one-time fast-forward synchronization of GitLab main to GitHub main for this repository, or change the active write-target policy to match the repository's GitHub-canonical workflow. Until that decision is made, do not push, force-push, reverse the mirror, or alter the existing sync workflows. This is the current blocker preventing the new iOS SDK compile and IPA workflows from seeing the latest fixes.
