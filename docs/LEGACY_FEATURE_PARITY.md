# Legacy feature parity and remaining Akatsubaki Emu requirements

**Last audited:** 2026-11-26  
**Scope:** consolidate long-running requests from older project conversations against the current GitLab main source. Unless marked otherwise, these are source-level findings, not physical-device verification.

This document complements the [first-playable acceptance checklist](FIRST_PLAYABLE_IOS_ACCEPTANCE.md) and [FEXCore/Box64 iOS integration audit](FEXCORE_IOS_PORT_AUDIT.md). It deliberately separates UI that exists from a guest runtime that has actually been proven.

## Verified core progress since the previous audit

- The x86-64 interpreter implements Linux syscall 158 operations `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS` and `ARCH_GET_GS`, with FS/GS-based memory operands. This is segment-base support, not a complete PT_TLS/dynamic-linker implementation.
- Native C-backed guest memory covers 256 MiB and the 384 MiB `brk`/mmap-hint regression. `brk` growth is bounded by the stack guard, not by the mmap allocation hint. `MAP_FIXED` uses replacement semantics; `MAP_FIXED_NOREPLACE` relies on the native transactional mapper to reject any already-mapped pages.
- AOT availability is a pure readiness query; first TXM arena preparation is explicit. The 32 MiB TXM executable arena tracks exact allocations and supports coalescing and concurrency tests.
- The interpreter has register-form x86 `XCHG 0x86/0x87` and, in `30a05994`, atomic memory-form 1/4/8-byte XCHG through mutex-serialized native guest memory, including cross-page operations and permission checks.
- `af00bceb` adds conservative CPUID and monotonic virtual RDTSC; `adf6a271` handles PAUSE as a no-op.
- `afda2d49` and `1678a2d5` harden and test the core-only IPA validator for iOS device platform values and reject simulator bundles/platforms.
- `8c5d6f94` fixes the static ELF program-header mapping and the native GuestMachine smoke build's C bridge; `1678a2d5` adds simulator bundle validation.
- Both static ELF diagnostic guests execute successfully on Linux x86-64 and produce their expected markers. This validates payload construction, not execution in Akatsubaki Emu on iOS.
- Kenran Butō AOT translator cache version 12 includes MOV r8,imm8 (including legacy high-byte semantics) and BSWAP 0F C8–CF. The MOV-byte decoder's malformed fallback calls were corrected in `b75c84f3`, with 15-byte/16-byte instruction-boundary regression cases; `a612ace5` updates source contracts to derive the documented version from the translator. Hosted AOT execution remains unverified.
- The QEMU acceleration settings and source contracts now distinguish experimental TCTI (threaded-dispatch TCG bytecode) from standard TCI while retaining legacy `QEMU TCI` identifiers.
- The static ELF diagnostic console now has a bounded, interruptible 64 KiB stdin queue and text input field. It remains text-only and does not provide a guest framebuffer.
- `6803ae1b` repairs the malformed TCI target-list patcher; `1c9e6cfe` and `37011be3` restore the regression assertions. The isolated helper harness passed 5/5 and the patch-script integration harness passed locally; GitLab exact-main pipeline 1273 remains blocked before runner allocation by `ci_quota_exceeded`.
- GitLab exact-head pipeline IID 1245 on `1678a2d5` failed before runner assignment with `ci_quota_exceeded`; no tests ran. GitHub run `45582606913` on older `ad65030d` failed at the now-fixed ELF program-header mapping.
- GitLab `main` currently points to `37011be3e6b610317f9c2b14ab15a91ce98dc806`; GitHub `main` remains at `f93008dfb5c6143c4e9dc256fca07a363020eccd` and is behind. No source mirror reconciliation or force-push has been attempted.

## Feature parity

| Earlier request | Current source state | Remaining work / limitation | Priority |
|---|---|---|---|
| Launch into VM, Hypervisor, VR or OS modes | Launch setup and VM configuration expose OS profiles, a QEMU full-system backend, TCI/JIT acceleration selection and a Cardboard/VR display option | QEMU TCI is the selected no-JIT first-playable route, but its distributable runtime, physical Linux boot, display/input and persistent-disk behavior are not yet verified | P0 |
| Default Ubuntu and import a custom OS | Ubuntu profile, custom image import, QEMU disk-image path and full-system runtime selection exist | The QEMU TCI runtime still needs its licensing approval/package and a physical Linux boot; importing an image is not booting it | P0 |
| Full Windows 10, not just PE inspection | Windows 10 profile and QEMU full-system build workflow exist | No QEMU runtime artifact or physical Windows boot is verified. The current PE loader is read-only and WindowsRuntime refuses launch | P1 |
| Install and launch EXE files | Library can import PE files and inspect their headers/sections | No complete PE mapping, imports/DLL loader, Win32/NT services, Wine/Proton or runnable Windows process path | P1 |
| SteamOS support | SteamOS Gaming Mode profile exists | This is a configuration profile, not proof that Valve's SteamOS image boots or that the Steam desktop client works | P1 |
| Steam Store inside the app | iOS library has an embedded WKWebView Store route | This is the web Store, not the desktop Steam client, game installer, compatibility layer or verified purchase/download integration. tvOS Store remains a placeholder | P2 |
| Remove Dream Store | No Dream Store source reference was found in the current main tree | Already absent; no removal change is needed | Done |
| Continue last session | Session metadata and configuration restoration exist | It restores metadata/configuration, not a suspended guest CPU/RAM snapshot | P1 |
| VM/config save slots | VMSaveSlotStore persists named configuration and session metadata | It does not snapshot guest RAM, device state or arbitrary game-save contents. Add a real disk/snapshot contract and crash-safe restore | P1 |
| External drives and storage access | ExternalDriveStore uses security-scoped file URLs/bookmarks and file-level access | This is not raw USB/block-device passthrough. Validate bookmark renewal, app relaunch, disk image access and guest filesystem persistence | P1 |
| Custom resolution and FPS, including 60/120 Hz | Settings and VMConfiguration expose resolution/frame-rate preferences | End-to-end application to the active renderer/display backend and frame pacing on the physical iPad are not verified | P2 |
| Static ELF diagnostic input/display | ConsoleViewController captures stdout/stderr and accepts text input; Linux syscall `read(0, ...)` uses a bounded, interruptible 64 KiB queue | The path remains text-only with no independent framebuffer. QEMU's separate VNC-to-Metal and keyboard/controller path is the first-playable route and still needs physical validation | P1 diagnostic |
| Touch gamepad with movable/resizable controls | TouchGamepadView has edit-mode movement and pinch-based sizing; ControllerInputManager maps controller events | Complete guest-side input delivery, focus/lifecycle handling and real game tests remain; existing controls are not wired to the static ELF runtime | P1 |
| Physical controllers | GameController input mapping and controller profiles exist | A complete HID/gamepad device presented to every guest backend is not verified | P1 |
| Touch keyboard | KeyboardOverlayView provides an on-screen keyboard; VMDisplayViewController has a separate F1–F12 touch bar | Hardware-keyboard event routing through UIKeyCommand/pressesBegan is not implemented in the inspected display path; validate focus, key-up and guest delivery | P2 |
| Hardware keyboard and F-key bar | A touch F1–F12 bar exists in VMDisplayViewController; no UIKeyCommand/pressesBegan hardware-key path was found | Add physical keyboard event routing, then test focus, key-up handling and guest delivery; the touch F-key bar still needs device validation | P2 |
| Pointer lock | Pointer-lock preference exists | Guest pointer capture, unlock gestures and backend-specific pointer semantics are not physically verified | P2 |
| Motion controls and VR | Cardboard-style display mode and motion/VR settings exist | This is a prototype layout, not a complete stereo renderer, motion-to-guest device, OpenXR or SteamVR implementation | P3 |
| Android experiment | Android experiment toggle/settings exist; a DroidDeck port-status document is present | No Android guest loader/runtime or working Android app execution path is established | P3 |
| tvOS and Siri Remote | tvOS target and early Siri Remote interface prototype exist | VM launch and guest runtime actions remain placeholders; no tvOS guest execution is verified | P3 |
| visionOS | visionOS target is declared in project configuration | No reproducible visionOS build or guest runtime test is recorded | P3 |
| ARM64e support | Legacy Xcode project settings mention arm64 and arm64e, but current project.yml build generation targets arm64 | The active generated build path has no verified arm64e slice. Keep arm64 as the supported iOS ABI unless a specific arm64e-only requirement is demonstrated | P2 |
| GetMoreRam / extended memory | StosSign entitlement workflow and memory-budget logic exist; VMConfiguration reads available process memory and caps guest RAM conservatively | Entitlements are Apple-signing/team dependent. Free-team SideStore signing may not preserve increased-memory capability. This cannot be bypassed by the emulator | P0 |
| UTM/QEMU TCTI backend | QEMU runtime build/release workflows define JIT and no-JIT variants; automatic acceleration can fall back to the experimental TCTI interpreter when JIT is unavailable | TCTI is the selected no-JIT first-playable route (legacy TCI identifiers remain). The prior merge failed on different `phodav` bytes; GitHub `06d21b6b` isolates dependency trees and adds TCI runpaths, but its build is not yet verified. No runtime artifact, QEMU-enabled IPA or physical Linux boot is verified; the UTM Apache-2.0 bridge still needs qualified combined-work review | P0 |
| FEXCore primary, Box64 fallback | RuntimeBackendRouter now tests FEXCore-first selection and Box64-only fallback; no concurrent translator is selected for one process | Neither dynamic translator is integrated as an operational iOS backend. FEXCore needs a Darwin core port; the BoxiOS snapshot is no-JIT and game-specific | P1 after first playable |
| MeloNX and SharpEmu references | Names appear in project documentation/reference material, not as integrated x86 runtime dependencies | They are separate console-emulation codebases; do not add them to Kenran Butō's x86 path without a distinct supported guest architecture and licence/architecture audit | P3/separate scope |
| Vapor and StikStore | No current source integration was found by repository search | Do not add speculative dependencies. StosSign and StikDebug are the current relevant signing/JIT integrations | P3/separate scope |
| Main/nightly iOS, tvOS and visionOS channels | Main/nightly release tags, iOS/tvOS/visionOS targets and a release workflow are declared | GitLab `main` is `ab20a239`; GitHub `main` is `06d21b6b`. Histories diverge; no reconciliation has been authorized or performed. No current-head QEMU TCTI IPA or physical boot is verified | P1 |
| AltStore source and xthrx's repo feeds | Separate website/AltStore-source repository and generation workflow | This is release/distribution infrastructure, not part of the guest execution core; keep its source catalogue and Docusaurus docs separate from runtime code | P2 |

## Correct implementation order

1. **QEMU TCI runtime:** run the manual dual-mode QEMU build workflow and validate the no-JIT TCI variant. Complete qualified file-level and combined-work licensing review before enabling distribution.
2. **First playable iOS:** after approval, package the TCI runtime into the current iOS IPA, sign/install through SideStore, and boot a known-good x86-64 Linux image on the physical iPad with JIT disabled.
3. **Physical interaction and state:** verify VNC-to-Metal display, keyboard/controller input, virtual-disk persistence, clean stop, repeat boots and recovery after app restart.
4. **Kenran Butō user-mode path:** keep the static ELF diagnostic guests as interpreter/GuestMemory/syscall tests; complete AOT correctness and fallback coverage independently of the QEMU TCI path.
5. **Dynamic user-mode engines:** integrate FEXCore as primary and Box64 as a measured fallback only after a reproducible physical guest path exists.
6. **Windows compatibility:** add PE loading, Win32/NT services, Wine/Proton and DirectX/Vulkan/Metal only after the x86 engine and ABI layers work.
7. **Additional platforms and polish:** finish F-key/hardware-keyboard UI, pointer lock, 60/120 Hz pacing, Android, true VR, tvOS and visionOS after iOS guest execution is stable.

## Current hard blockers

- QEMU TCI is the selected first-playable no-JIT route, but the QEMU/UTM distribution gate remains closed. The release workflow requires `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED=true` only after qualified file-level and combined-work licensing review. Do not set it before that review.
- The manual QEMU runtime build workflow can compile/validate JIT and TCI variants, but no TCI runtime artifact, QEMU-enabled iOS IPA, or physical Linux boot is verified.
- GitLab pipelines IID 1288–1290 failed before runner assignment with `ci_quota_exceeded`; the latest attempt (IID 1290) targeted parent commit `4a232427`, before the current source-contract and AOT-window commits `a612ace5` and `ab20a239`. No tests ran on the latest source head.
- GitLab `main` is `ab20a239`; GitHub `main` is `06d21b6b`. The histories diverge. GitHub contains the candidate QEMU dependency-isolation fix; GitLab contains the latest AOT source-contract and instruction-window repairs. Do not run the existing history-reconciliation workflow without explicit owner authorization. The core-only iOS workflow is QEMU-free diagnostic coverage, not the first playable VM release.
- GitHub core-only IPA run `45582606913` on older `ad65030d` failed because the diagnostic ELF did not map its program-header table; `8c5d6f94` fixes that issue. No current-head hosted result or IPA artifact is verified.
- The static ELF runtime is a bounded user-mode diagnostic. It is not a full-system Linux/Windows emulator. Its stdin queue is interruptible and bounded, but it has no independent framebuffer; QEMU's separate VNC-to-Metal path is intended for the first playable guest.
- FEXCore/Box64 are not operational iOS dynamic backends; dynamic ELF, broad Linux ABI, Windows/PE, Wine/Proton, full-system graphics/audio beyond the QEMU display path, snapshots, USB passthrough, and Android/VR/tvOS/visionOS guest execution remain incomplete.
- No current QEMU TCI IPA, SideStore installation, or physical iPad Linux boot is verified. TCI does not require JIT/StikDebug; StikDebug 3.2.2+ is only required for optional TXM/AOT/JIT validation.

**Status rule:** an option in a menu, a parser, a build workflow or a host smoke test is not equivalent to a running guest feature. Mark each item operational only after its complete path is tested on the target device.


## Separate companion scope

Butō Box is a standalone companion project/documentation surface, not a Kenran Butō runtime subsystem. Keep its site, documentation and build/release artifacts separate from the emulator's guest-execution core; do not treat a Butō Box page as evidence of emulator functionality.
