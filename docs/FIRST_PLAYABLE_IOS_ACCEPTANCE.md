# First playable iOS acceptance and remaining feature backlog

**Last audited:** 2026-11-25  
**Scope:** Kenran Butō's first reproducible iOS guest-execution milestone. This is a checklist, not a claim that the milestone has shipped. See [Legacy feature parity and remaining requirements](LEGACY_FEATURE_PARITY.md) for the older cross-chat feature requests and their current implementation status.

## Validation automation

Changes to this acceptance checklist trigger both the QEMU-free core-only iOS build and the Kenran Butō AOT validation workflow. The AOT workflow uses matching `push` and `pull_request` path filters; a regression test checks that those lists stay identical and that the allocation hot-path test is included in both.

These hosted checks validate source contracts, native/Swift execution harnesses, and the unsigned physical-device ARM64 build. They do **not** prove signing, installation, JIT activation, or guest execution on a physical iPad; those remain explicit device acceptance gates below.

## Current implementation boundary

The repository now contains:

- A bounded static x86-64 Linux ELF loader and Linux initial-stack builder.
- A Linux syscall subset including \`uname\`, \`write\`, and \`exit\`.
- \`GuestMachine\` orchestration with the x86-64 interpreter and native C-backed guest memory.
- A partial x86-64-to-ARM64 AOT translator, translated-code cache, backend routing, and interpreter fallback.
- Atomic memory-form XCHG for 1-, 4-, and 8-byte operands through a mutex-serialized native guest-memory API, including cross-page accesses and permission checks.
- Conservative CPUID feature reporting and a monotonic 1 GHz virtual RDTSC counter; unsupported instructions still fall back to the interpreter.
- A 32 MiB TXM executable arena for StikDebug-backed AOT memory, with exact-allocation tracking, coalescing, and concurrency regression tests.
- An application import-to-launch route through \`LibraryViewController\`, \`ConsoleViewController\`, \`GameLauncher\`, \`LinuxELFRuntime\`, and \`GuestMachine\`.

This is a real, bounded execution path, not a complete PC emulator. It does not yet provide dynamic ELF linking, arbitrary Linux userland, a bootable Linux/Windows OS, a production graphics pipeline, or complete guest input.

## Acceptance gates

### Gate 1 — Reproducible core-only iOS build

- [ ] Run the core-only iOS workflow against the current GitLab \`main\` source.
- [ ] Confirm the workflow compiles the physical-device ARM64 target and produces the expected unsigned IPA.
- [ ] Record the source commit, workflow run, IPA checksum, bundle identifier, and effective entitlements.
- [ ] Sign and install the IPA on a physical iPad using a supported signing path.
- [ ] Confirm the app launches repeatedly without a simulator-only dependency.

The core-only workflow intentionally excludes QEMU so the first interpreter milestone is not blocked by the separate full-system licensing gate.

### Gate 2 — Physical static-ELF execution

Use the two diagnostic guests produced by \`scripts/build_hybrid_xchg_smoke_elf.py\` and \`scripts/build_hybrid_runtime_smoke_elf.py\`.

- [ ] Import \`hybrid_xchg_smoke.elf\` through Files and launch it through the application UI.
- [ ] Confirm \`KENRAN_BUTO_XCHG_OK\` and exit status 0.
- [ ] Import \`hybrid_runtime_smoke.elf\` through Files and launch it through the application UI.
- [ ] Confirm \`Linux\`, \`x86_64\`, and \`KENRAN_BUTO_RUNTIME_OK\`, followed by exit status 0.
- [ ] Repeat both launches after returning to the library and after restarting the app.
- [ ] Confirm stopping a guest releases guest-memory pages and does not leave stale runtime state.
- [ ] Record device model, iPadOS version, app build, guest checksums, logs, and a short screen recording.

Host-side ELF execution, Swift regression tests, and IPA packaging are not substitutes for this physical-device gate.

### Gate 3 — AOT/JIT correctness on device

- [ ] Use StikDebug 3.2.2 or newer for TXM/AOT validation. On iOS/iPadOS 27+, pair on-device through Settings → Pair a Device → Pair iPhone or iPad and complete the Developer Mode prompt; no computer or manual `RPPairing` import is required. On older supported versions, generate/import a fresh `RPPairing` file.
- [ ] Verify the installed app has the required effective \`get-task-allow\` entitlement.
- [ ] Verify the JIT protocol mode and TXM arena are available on a supported physical device.
- [ ] Execute representative AOT blocks and compare register, memory, flag, and exit results against the interpreter.
- [ ] Revoke JIT readiness during execution and confirm AOT fails closed and interpreter fallback continues safely.
- [ ] Verify repeated arena allocation, eviction, and reuse without stale executable mappings.

The AOT path is optional for the first no-JIT interpreter smoke guest. StikDebug pairing and JIT are required to validate acceleration, not to prove that the diagnostic interpreter can execute.

### Gate 4 — First playable interaction

- [ ] Connect the guest execution path to a guest framebuffer and a Metal-backed display.
- [ ] Route touch, hardware keyboard, and controller input into guest input events.
- [ ] Verify pause/resume, focus changes, orientation, and clean shutdown.
- [ ] Apply guest resolution and frame-rate settings to the actual renderer rather than only storing UI preferences.

The current console is text-oriented. Existing VNC, display, Metal, controller, and frame-pacing experiments do not yet constitute a complete Kenran Butō graphics/input pipeline.

### Gate 5 — Persistent guest state

- [ ] Implement a guest disk/block-device path with documented image formats.
- [ ] Persist guest writes across app restarts.
- [ ] Add save slots/snapshots with corruption-safe writes and recovery.
- [ ] Verify cleanup and repeat launches do not erase persistent guest data.

The current shared-file/host-device bridge is not equivalent to a complete virtual disk, USB, or external-drive controller.

### Gate 6 — Full-system operating-system boot

- [ ] Complete the selected full-system backend and its iOS ARM64 build.
- [ ] Complete the licensing review and required notices before packaging third-party code.
- [ ] Boot a known-good Linux image on a physical iPad.
- [ ] Verify basic display, keyboard/touch input, storage, and repeat boots.
- [ ] Only then expand to Windows and broader compatibility targets.

QEMU/UTM is the existing full-system direction but is subject to its separate licensing/build gate. Bochs is a possible GPL-compatible research candidate, not an integrated or verified iOS backend. Do not claim full-system support from a successful build alone.

## iOS signing and JIT prerequisites

- The interpreter smoke path must work without JIT and must size guest memory using available host memory.
- SideStore free-team signing may omit optional increased-memory entitlements from the effective installed signature; enabling an App ID capability is not proof that the installed app received it. Inspect effective entitlements after reinstall.
- \`get-task-allow\` is a separate requirement for StikDebug JIT. Missing JIT must disable AOT execution safely and preserve interpreter fallback.
- See [iOS memory entitlements](IOS_ENTITLEMENTS.md), [JIT activation](JIT_ACTIVATION.md), and [core-only iOS test build](CORE_ONLY_IOS_TEST_BUILD.md).

## Remaining features from older project requests

These items remain outside the first static-ELF milestone and should be implemented only after the physical guest path is stable.

| Area | Requested capability | Current boundary / missing work |
|---|---|---|
| Windows | Windows 10 guest, EXE installation and execution | PE metadata inspection is not a Windows kernel, Win32 API, dynamic translator, Wine, or Proton runtime |
| Linux | General Linux applications and dynamic ELF files | Dynamic loader, shared libraries, broader syscall/ABI coverage, and full-system boot are missing |
| Steam | In-app Steam Store and library/game launch integration | The tvOS Store action is an explanatory prototype; a functional Steam client/session is not integrated |
| Storage | Persistent VM disks, save slots, external drives and USB | Needs a real block-device layer, image management, snapshots, and device passthrough |
| Graphics | Guest framebuffer, Metal rendering, 3D translation | Current display experiments are not a complete guest graphics backend |
| Input | Touch gamepad, movable/resizable controls, pointer lock, motion, hardware keyboard and F-key bar | Needs end-to-end event routing into the guest, focus handling, and per-game profiles |
| Display | Custom resolution, FPS limits, 60/120 Hz selection | Must be connected to the real renderer and guest timing, not only UI settings |
| Controllers | Physical gamepads, sticks, buttons and controller mapping | Needs a tested host-to-guest input translation layer |
| Android | Android guest experiment | UI selection only; no Android execution backend |
| VR / visionOS | VR mode, motion input, visionOS support | Prototype/build-target work; no verified guest VR rendering or interaction |
| tvOS | Apple TV guest launch and controller support | Interface prototype; no verified OS boot or game launch |
| Dynamic translation | FEXCore/Box64 or another general x86-64 dynamic backend | No integrated, benchmarked iOS backend; interpreter remains correctness fallback |
| UTM/QEMU | Full-system emulation backend | Requires license gate, reproducible iOS ARM64 build, and physical-device boot evidence |
| Vapour Emu | Evaluate after its expected release | Date and availability are unverified; development must not wait for it |

## Repository/CI coordination and latest validation status

GitLab `main` is `2876b49d1c332fb3febe235976abef54890d69e9`. GitHub `main` is `30a05994eeac607a4a57716f2d384cea6ee57047`; direct comparison confirms GitHub is an ancestor of GitLab. GitLab has four commits after the shared `30a05994` base:

- `3ca7cd9c` updates the hybrid-runtime architecture documentation for atomic memory-form XCHG.
- `763b38ab` updates the static-ELF Swift test double with exchange methods so interpreter tests conform to the native GuestMemory API. The mock is single-threaded; native C++ tests prove atomicity.
- `af00bceb` adds conservative CPUID reporting and a monotonic 1 GHz virtual RDTSC counter, with interpreter regressions and architecture documentation.
- `2876b49d` refreshes the first-playable acceptance and legacy feature-parity audit against the current implementation.

The configured synchronization direction is GitHub-to-GitLab. Publishing these newer GitLab commits back to GitHub requires the existing owner-gated reconciliation. No force-push, reset, rebase, branch creation, PR merge, or branch deletion has been performed.

### Current source changes

- `3026c1bf` adds a lock-protected interpreter stop-state read helper, removing the unsynchronized AOT-side stop-flag read.
- `fae7c262` adds register-only x86 `XCHG 0x87`, maps syscall-test output buffers, and updates metrics artifact actions to `actions/upload-artifact@v7`.
- `345b1bba` adds the memory-form XCHG fail-closed regression that was appropriate before guest-memory atomic operations existed.
- `8f2dd2f5` adds register-only byte `XCHG 0x86`, including REX.B/REX.R register selection.
- `30a05994` adds mutex-serialized native guest-memory exchange for 1-, 4-, and 8-byte operands, cross-page handling, permission validation, Swift wrappers, and interpreter memory-form `0x86`/`0x87` support. Native tests cover cross-page exchange, read-only rejection without mutation, and concurrent serialization.
- `763b38ab` aligns the static-ELF Swift test double with the atomic exchange API.
- `af00bceb` adds conservative CPUID leaves and a monotonic virtual RDTSC counter. SIMD features are deliberately not advertised; these additions do not make the interpreter a general x86-64 implementation.
- `2876b49d` refreshes this acceptance checklist and the legacy feature-parity audit.

### Hosted validation evidence

- GitLab pipeline IID 1237 / ID `3112567653` on source SHA `30a05994` and IID 1240 / ID `3112583329` on `af00bceb` both failed before runner assignment with `ci_quota_exceeded`; no tests ran. Current docs-only head `2876b49d` has not passed an exact-head hosted validation run.
- GitHub AOT workflow run `45577650906` passed on older source `e2dcb994`, including its tested restricted AOT path, interpreter differential checks, JIT revocation checks, and a static-ELF run reporting `blocks=2`. It predates atomic memory XCHG and CPUID/RDTSC; it is not exact-current-main evidence.
- Earlier platform workflow run `45576869713` on `4192b5e8` passed tvOS/visionOS simulator builds and an unsigned physical-device iOS ARM64 compile. It is compile-only evidence from an older commit, not a current IPA, signed installation, or guest execution.
- No current-head IPA artifact, SideStore installation, or physical iPad guest execution is verified.

### Runtime and older-feature boundary

The static ELF path remains a bounded diagnostic user-mode runtime, not a complete PC emulator. Linux `read(0, ...)` returns EOF; the console has no guest stdin adapter. Existing keyboard, F1–F12, touch, controller, and motion controls route to QEMU/VNC rather than `GuestMachine`. The Metal framebuffer is fed by VNC; the static ELF runtime has no independent guest-frame submission contract.

FEXCore and Box64 are not operational iOS backends. Dynamic ELF loading, PT_TLS initialization, broad Linux syscall/thread/signal support, Windows PE execution, Wine/Proton, full-system OS boot, persistent block storage, and game-ready graphics/audio remain separate milestones. The existing UI/configuration options do not prove those guest capabilities.

### Required next actions

1. Retry native-memory, interpreter, AOT, and full repository validation against exact GitLab `main` when runner quota recovers.
2. Obtain explicit owner authorization before using the existing GitLab-main-to-GitHub-main reconciliation; do not force-push or merge PR branches.
3. Produce and checksum the current unsigned physical-device ARM64 IPA, sign/install it through SideStore, and run both static ELF diagnostic guests through the app's real import-to-runtime path on the physical iPad.
4. Record output markers, exit status 0, repeat launches, stop/reset behavior, and guest-memory cleanup.
5. After physical guest execution is proven, implement a bounded stdin queue with stop/reset wakeup, a shared keyboard/touch/controller event sink, and a GuestMachine framebuffer contract feeding Metal.
6. Validate TXM/AOT separately. The no-JIT interpreter path must remain usable without StikDebug; iOS/iPadOS 27+ TXM/AOT pairing requires StikDebug 3.2.2 or newer.

A simulator build, host-side ELF execution, source-level JIT implementation, or IPA archive alone does not satisfy the physical-device acceptance gates.

## Definition of done

The first playable physical iOS milestone is complete only when a reproducible current-source IPA is installed on a physical iPad, a known-good guest executes through the app's real import-to-runtime path, basic guest display and input work, repeat launches and cleanup are reliable, persistent guest state survives restarts, and the build/test/device evidence is recorded. A simulator run, host-side ELF execution, or successful IPA packaging alone is insufficient.


## Latest JIT source status (2026-11-24)

The Kenran Butō iOS AOT allocator now has a separate preallocated-arena detach path: one 32 MiB TXM/SPTM executable region, one writable alias, then `iSteamJITDetachPreparedArena`; its arena-ready state is independent of QEMU’s attached-session callback. Hardware detection recognizes both TXM and SPTM. QEMU retains its no-op detach for lazy regions. This remains **UNTESTED on a physical iPad**; interpreter execution is the first-playable fallback and does not require JIT.
