# Legacy feature parity and remaining Akatsubaki Emu requirements

**Last audited:** 2026-11-25  
**Scope:** consolidate long-running requests from older project conversations against the current GitLab main source. Unless marked otherwise, these are source-level findings, not physical-device verification.

This document complements the [first-playable acceptance checklist](FIRST_PLAYABLE_IOS_ACCEPTANCE.md) and [FEXCore/Box64 iOS integration audit](FEXCORE_IOS_PORT_AUDIT.md). It deliberately separates UI that exists from a guest runtime that has actually been proven.

## Verified core progress since the previous audit

- The x86-64 interpreter implements Linux syscall 158 operations `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS` and `ARCH_GET_GS`. The existing interpreter regression covers FS set/get and segment access; this update adds GS set/get, GS segment access, non-canonical-base rejection and invalid output-pointer handling. This is not a complete TLS runtime: `PT_TLS`, dynamic linking and broad process ABI support remain.
- Native C-backed guest-memory tests cover 256 MiB, and commit `69e798ee` adds a 384 MiB regression that grows `brk` across the 256 MiB mmap hint, maps above the expanded heap, shrinks, rewinds the mmap cursor and checks live-mapping collision protection.
- Commit `8f25d4c4` makes AOT availability checks side-effect-free; first TXM arena preparation is explicit in `refreshAvailability()`.
- Commits `6332440d` and `15cf98a6` correct the earlier AOT XCHG and Python packaging-test failures. Commits `cb62b0d6`, `8cce0419`, `bc3eab67`, `55996e0c` and `e97b25e1` correct the Linux `exit(0)`, mprotect-after-unmap, uname exit-status, relocated-mmap-hint and cross-page instruction-window regression expectations.
- Commit `7a06b230` changes the repository-metrics workflow to scheduled/manual artifact-only output, removes `contents:write` and automatic GitHub-only commits, and prevents future generated-SVG commits from extending the existing mirror divergence.
- The host smoke kit has two static ELF guests and passing host builder/execution tests. This proves the payloads are valid on Linux x86-64, not that Akatsubaki Emu has executed them on an iPad.

## Feature parity

| Earlier request | Current source state | Remaining work / limitation | Priority |
|---|---|---|---|
| Launch into VM, Hypervisor, VR or OS modes | Launch setup and VM configuration expose OS profiles, Full VM and executable-library paths, and a Cardboard/VR display option | Most selections are configuration/UI paths. The first playable guest still uses the bounded ELF runtime; full OS boot is not verified | P0 |
| Default Ubuntu and import a custom OS | Ubuntu profile and custom image/file import route exist | Importing an image is not booting it. UEFI, block devices, full-system QEMU and a physical boot test remain | P0/P1 |
| Full Windows 10, not just PE inspection | Windows 10 profile and QEMU full-system build workflow exist | No QEMU runtime artifact or physical Windows boot is verified. The current PE loader is read-only and WindowsRuntime refuses launch | P1 |
| Install and launch EXE files | Library can import PE files and inspect their headers/sections | No complete PE mapping, imports/DLL loader, Win32/NT services, Wine/Proton or runnable Windows process path | P1 |
| SteamOS support | SteamOS Gaming Mode profile exists | This is a configuration profile, not proof that Valve's SteamOS image boots or that the Steam desktop client works | P1 |
| Steam Store inside the app | iOS library has an embedded WKWebView Store route | This is the web Store, not the desktop Steam client, game installer, compatibility layer or verified purchase/download integration. tvOS Store remains a placeholder | P2 |
| Remove Dream Store | No Dream Store source reference was found in the current main tree | Already absent; no removal change is needed | Done |
| Continue last session | Session metadata and configuration restoration exist | It restores metadata/configuration, not a suspended guest CPU/RAM snapshot | P1 |
| VM/config save slots | VMSaveSlotStore persists named configuration and session metadata | It does not snapshot guest RAM, device state or arbitrary game-save contents. Add a real disk/snapshot contract and crash-safe restore | P1 |
| External drives and storage access | ExternalDriveStore uses security-scoped file URLs/bookmarks and file-level access | This is not raw USB/block-device passthrough. Validate bookmark renewal, app relaunch, disk image access and guest filesystem persistence | P1 |
| Custom resolution and FPS, including 60/120 Hz | Settings and VMConfiguration expose resolution/frame-rate preferences | End-to-end application to the active renderer/display backend and frame pacing on the physical iPad are not verified | P2 |
| Touch gamepad with movable/resizable controls | TouchGamepadView has edit-mode movement and pinch-based sizing; ControllerInputManager maps controller events | Complete guest-side input delivery, focus/lifecycle handling and real game tests remain | P1 |
| Physical controllers | GameController input mapping and controller profiles exist | A complete HID/gamepad device presented to every guest backend is not verified | P1 |
| Touch keyboard | KeyboardOverlayView provides an on-screen keyboard | There is no dedicated F1–F12 touch bar in the current overlay. The VNC client has F-key keysyms, but the UI path is missing | P2 |
| Hardware keyboard and F-key bar | No UIKeyCommand implementation or dedicated function-key bar was found in the current source search | Add hardware-key event routing and F1–F12 controls, then test keyboard focus and guest key-up handling | P2 |
| Pointer lock | Pointer-lock preference exists | Guest pointer capture, unlock gestures and backend-specific pointer semantics are not physically verified | P2 |
| Motion controls and VR | Cardboard-style display mode and motion/VR settings exist | This is a prototype layout, not a complete stereo renderer, motion-to-guest device, OpenXR or SteamVR implementation | P3 |
| Android experiment | Android experiment toggle/settings exist; a DroidDeck port-status document is present | No Android guest loader/runtime or working Android app execution path is established | P3 |
| tvOS and Siri Remote | tvOS target and early Siri Remote interface prototype exist | VM launch and guest runtime actions remain placeholders; no tvOS guest execution is verified | P3 |
| visionOS | visionOS target is declared in project configuration | No reproducible visionOS build or guest runtime test is recorded | P3 |
| ARM64e support | Legacy Xcode project settings mention arm64 and arm64e, but current project.yml build generation targets arm64 | The active generated build path has no verified arm64e slice. Keep arm64 as the supported iOS ABI unless a specific arm64e-only requirement is demonstrated | P2 |
| GetMoreRam / extended memory | StosSign entitlement workflow and memory-budget logic exist; VMConfiguration reads available process memory and caps guest RAM conservatively | Entitlements are Apple-signing/team dependent. Free-team SideStore signing may not preserve increased-memory capability. This cannot be bypassed by the emulator | P0 |
| UTM backend | QEMU/UTM full-system packaging workflow exists | The QEMU JIT/TCI artifact has not been produced and booted; its GPLv2/UTM Apache-2.0 notices require the existing compatibility review gate | P1 |
| FEXCore primary, Box64 fallback | RuntimeBackendRouter now tests FEXCore-first selection and Box64-only fallback; no concurrent translator is selected for one process | Neither dynamic translator is integrated as an operational iOS backend. FEXCore needs a Darwin core port; the BoxiOS snapshot is no-JIT and game-specific | P1 after first playable |
| MeloNX and SharpEmu references | Names appear in project documentation/reference material, not as integrated x86 runtime dependencies | They are separate console-emulation codebases; do not add them to Kenran Butō's x86 path without a distinct supported guest architecture and licence/architecture audit | P3/separate scope |
| Vapor and StikStore | No current source integration was found by repository search | Do not add speculative dependencies. StosSign and StikDebug are the current relevant signing/JIT integrations | P3/separate scope |
| Main/nightly iOS, tvOS and visionOS channels | Main/nightly release tags, iOS/tvOS/visionOS targets and a release workflow are declared | GitLab main `345b1bba` is a direct descendant of GitHub main `4192b5e8`, five commits ahead; the configured sync is GitHub-to-GitLab only. A non-forced fast-forward back to GitHub requires explicit owner approval. No current-main IPA artifact is verified | P1 |
| AltStore source and xthrx's repo feeds | Separate website/AltStore-source repository and generation workflow | This is release/distribution infrastructure, not part of the guest execution core; keep its source catalogue and Docusaurus docs separate from runtime code | P2 |

## Correct implementation order

1. **First playable iOS:** obtain explicit owner approval for a non-forced fast-forward of GitHub main to the existing GitLab main, then rerun the core-only workflow against that exact source, produce an unsigned IPA, install it through SideStore, run both static ELF guests on the physical iPad, and record output, exit codes, cleanup and repeat launches.
2. **Stabilise the guest lifecycle:** verify memory reset, failed-load cleanup, process stop, relaunch, persistent guest files, and the TXM/SPTM first-prepare/live-session/detach sequence with the correct StikDebug version.
3. **Complete basic interaction:** console/framebuffer output, touch and controller input, keyboard events, audio and persistent disk access. Do this before UI polish or broad compatibility claims.
4. **Finish the user-mode engine:** complete AOT correctness and interpreter fallbacks, Linux syscall/loader/thread/signal support, then integrate FEXCore as primary and Box64 as a measured fallback.
5. **Full-system support:** clear the QEMU licence gate, build JIT and TCI, boot a known-good Linux image, then test Windows 10 and SteamOS separately.
6. **Windows compatibility:** only after the x86 engine and Linux/Windows ABI layers work, integrate PE loading, Wine/Proton, DirectX/Vulkan/Metal and anti-cheat publisher-supported paths.
7. **Additional platforms and polish:** finish F-key/hardware-keyboard UI, pointer lock, 60/120 Hz pacing, Android, true VR, tvOS and visionOS after the physical iOS guest path is stable.

## Current hard blockers

- GitLab main is `345b1bba`; GitHub main is `4192b5e8`. GitLab is a direct descendant through `9025ccaf`, `3026c1bf`, `fae7c262`, `e2dcb994` and `345b1bba`. The configured sync only pushes GitHub → GitLab and refuses to push when GitLab is ahead. Do not force-push, reset, rebase, create branches or reverse-sync without explicit owner authorization. The existing safe reconciliation is owner-gated.
- GitLab pipeline IID 1226 (ID `3112479648`) on `fae7c262` and IID 1229 (ID `3112488468`) on `345b1bba` both failed before runner assignment with `ci_quota_exceeded`; their jobs had no runner or duration. No tests ran.
- GitHub core-only IPA run `45576869550` on `4192b5e8` passed Python validation but stopped at the unmapped syscall-test output buffer on line 391. GitHub validation run `45576869650` also found the old metrics action major `@v4`; both issues are corrected on GitLab main by `fae7c262`, but the fix has not reached GitHub Actions.
- GitHub platform run `45576869713` on `4192b5e8` passed tvOS and visionOS simulator builds and the unsigned iOS ARM64 device compile. Its iOS simulator test stopped at the same syscall fixture. This is not an IPA or physical-device execution.
- AOT run `45575957157` on `c25947b0` failed on register-form XCHG because the interpreter lacked opcode `0x87`. Commit `fae7c262` adds the interpreter fallback; commit `345b1bba` adds a memory-form fail-closed regression. Neither has passed exact-head hosted AOT validation.
- Commit `3026c1bf` fixes the interpreter stop-state data race. Commit `fae7c262` adds register-only XCHG, maps the syscall test buffers and updates metrics actions to `@v7`. Commit `345b1bba` adds the memory-form XCHG negative test.
- No current-head IPA artifact, SideStore installation, or physical iPad guest execution is verified. The initial interpreter smoke path does not require JIT; the user's previously reported StikDebug 3.1.14 is below the 3.2.2+ baseline for TXM/AOT validation. On iOS/iPadOS 27+, use the on-device pairing flow.

**Status rule:** an option in a menu, a parser, a build workflow or a host smoke test is not equivalent to a running guest feature. Mark each item operational only after its complete path is tested on the target device.
