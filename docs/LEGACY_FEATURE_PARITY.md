# Legacy feature parity and remaining Akatsubaki Emu requirements

**Last audited:** 2026-11-25  
**Scope:** consolidate long-running requests from older project conversations against the current GitLab main source. Unless marked otherwise, these are source-level findings, not physical-device verification.

This document complements the [first-playable acceptance checklist](FIRST_PLAYABLE_IOS_ACCEPTANCE.md) and [FEXCore/Box64 iOS integration audit](FEXCORE_IOS_PORT_AUDIT.md). It deliberately separates UI that exists from a guest runtime that has actually been proven.

## Verified core progress since the previous audit

- The x86-64 interpreter implements Linux syscall 158 operations `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS` and `ARCH_GET_GS`, with FS/GS-based memory operands and regression coverage. This is segment-base support, not a complete PT_TLS/dynamic-linker implementation.
- Native C-backed guest-memory tests cover 256 MiB and the 384 MiB `brk`/mmap-hint regression. Existing tests cover page permissions, execute reads, mapping boundaries and cleanup.
- AOT availability is a pure readiness query; first TXM arena preparation is explicit. The 32 MiB TXM executable arena tracks exact allocations and supports coalescing and concurrency tests.
- The interpreter has register-form x86 `XCHG 0x86/0x87` support and, in commit `30a05994`, atomic memory-form 1/4/8-byte XCHG through a mutex-serialized native guest-memory API. Cross-page exchange, read-only rejection without mutation, LOCK-prefix handling and concurrent serialization have regression coverage. General atomic read-modify-write instructions remain unsupported.
- Commit `763b38ab` aligns the static-ELF Swift test double with the atomic exchange API; the mock is single-threaded and does not replace native atomicity tests.
- Commit `af00bceb` adds conservative CPUID reporting and a monotonic 1 GHz virtual RDTSC counter. Unsupported SIMD is not advertised; these instructions currently use interpreter fallback rather than AOT translation.
- The host smoke kit has two static ELF guests and passing host builder/execution tests. This proves payload validity on Linux x86-64, not that Akatsubaki Emu has executed them on an iPad.
- GitHub AOT run `45577650906` passed the restricted AOT suite on older source `e2dcb994`, including two translated static-ELF blocks. It is not validation of the current atomic-XCHG or CPUID/RDTSC changes.
- GitLab pipeline IID 1237 on `30a05994` and IID 1240 on `af00bceb` failed before runner assignment with `ci_quota_exceeded`; no tests ran. The docs-only `2876b49d` head also has no exact-head hosted result.

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
| Linux ELF console input/display | ConsoleViewController captures stdout/stderr; Linux syscall `read(0, ...)` currently returns EOF | No guest stdin queue or keyboard adapter; touch/controller/hardware-keyboard controls target QEMU/VNC, not GuestMachine; the static ELF runtime has no framebuffer contract feeding Metal | P0 after physical smoke |
| Touch gamepad with movable/resizable controls | TouchGamepadView has edit-mode movement and pinch-based sizing; ControllerInputManager maps controller events | Complete guest-side input delivery, focus/lifecycle handling and real game tests remain; existing controls are not wired to the static ELF runtime | P1 |
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
| Main/nightly iOS, tvOS and visionOS channels | Main/nightly release tags, iOS/tvOS/visionOS targets and a release workflow are declared | GitLab main `2876b49d` is four commits ahead of GitHub main `30a05994` (`3ca7cd9c` architecture docs, `763b38ab` test-double update, `af00bceb` CPUID/RDTSC, `2876b49d` acceptance/parity audit). The configured sync is GitHub-to-GitLab; reverse reconciliation remains owner-gated. No current-main IPA artifact is verified | P1 |
| AltStore source and xthrx's repo feeds | Separate website/AltStore-source repository and generation workflow | This is release/distribution infrastructure, not part of the guest execution core; keep its source catalogue and Docusaurus docs separate from runtime code | P2 |

## Correct implementation order

1. **First playable iOS:** retry exact-current-main validation when GitLab runner quota recovers; produce the unsigned physical-device ARM64 IPA; install through SideStore; run both static ELF diagnostic guests on the physical iPad; record output, exit status, cleanup and repeat launches.
2. **Stabilise the guest lifecycle:** verify memory reset, failed-load cleanup, process stop, relaunch, persistent guest files, and the TXM/SPTM first-prepare/live-session/detach sequence with the correct StikDebug version.
3. **Complete basic interaction:** add bounded guest stdin with stop/reset wakeup, route keyboard/F1–F12/touch/controller events into GuestMachine, and add a guest framebuffer contract feeding the existing Metal backend. Test backpressure, event ordering, key-up cleanup, stop-while-blocked and repeat launches.
4. **Finish the user-mode engine:** complete AOT correctness and interpreter fallbacks, Linux syscall/loader/thread/signal support, then integrate FEXCore as primary and Box64 as a measured fallback.
5. **Full-system support:** clear the QEMU licence gate, build JIT and TCI, boot a known-good Linux image, then test Windows 10 and SteamOS separately.
6. **Windows compatibility:** only after the x86 engine and Linux/Windows ABI layers work, integrate PE loading, Wine/Proton, DirectX/Vulkan/Metal and anti-cheat publisher-supported paths.
7. **Additional platforms and polish:** finish F-key/hardware-keyboard UI, pointer lock, 60/120 Hz pacing, Android, true VR, tvOS and visionOS after the physical iOS guest path is stable.

## Current hard blockers

- GitLab main is `af00bceb1cb96433f87976a2ceec1828f0e7e601`; GitHub main is `30a05994eeac607a4a57716f2d384cea6ee57047`. GitLab is three commits ahead after the shared `30a05994` base: `3ca7cd9c` (architecture documentation), `763b38ab` (static-ELF test-double update), and `af00bceb` (CPUID/RDTSC). No force-push, reset, rebase, branch creation, PR merge or branch deletion is permitted without the separate required authorization.
- GitLab pipeline IID 1237 / ID `3112567653` on `30a05994` failed before runner assignment with `ci_quota_exceeded`; no tests ran. The later `763b38ab` and `af00bceb` changes have not been hosted-validated.
- GitHub AOT run `45577650906` passed on older source `e2dcb994` with two translated static-ELF blocks and its tested AOT/interpreter/JIT-revocation checks. It is not exact-current-main evidence.
- Earlier platform run `45576869713` on `4192b5e8` passed tvOS/visionOS simulator builds and unsigned physical iOS ARM64 compilation. It did not produce a current IPA or prove signing, installation or physical guest execution.
- Commit `30a05994` implements atomic memory-form XCHG and adds native cross-page, permission-failure and concurrent-exchange tests. Pipeline 1237 did not execute them because no runner was assigned.
- Commit `af00bceb` adds conservative CPUID and monotonic virtual RDTSC support, but these additions have no exact-head hosted test result.
- The static ELF runtime is still console-only: stdin returns EOF, input events are not connected to GuestMachine, and Metal frames are sourced from QEMU/VNC rather than the ELF runtime.
- FEXCore/Box64 are not operational iOS backends; dynamic ELF, broad Linux ABI, Windows/PE execution, Wine/Proton, full-system boot, persistent block storage, and game-ready graphics/audio remain incomplete.
- No current-head IPA artifact, SideStore installation, or physical iPad guest execution is verified. The no-JIT interpreter smoke path does not require JIT; iOS/iPadOS 27+ TXM/AOT pairing requires StikDebug 3.2.2 or newer.

**Status rule:** an option in a menu, a parser, a build workflow or a host smoke test is not equivalent to a running guest feature. Mark each item operational only after its complete path is tested on the target device.
