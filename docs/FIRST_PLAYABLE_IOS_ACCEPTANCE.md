# First playable iOS acceptance and remaining feature backlog

**Last audited:** 2026-11-25  
**Scope:** Kenran Butō's first reproducible iOS guest-execution milestone. This is a checklist, not a claim that the milestone has shipped. See [Legacy feature parity and remaining requirements](LEGACY_FEATURE_PARITY.md) for the older cross-chat feature requests and their current implementation status.

## Validation automation

Changes to this acceptance checklist trigger both the QEMU-free core-only iOS build and the Kenran Butō AOT validation workflow. The AOT workflow uses matching `push` and `pull_request` path filters; a regression test checks that those lists stay identical and that the allocation hot-path test is included in both.

These hosted checks validate source contracts, native/Swift execution harnesses, and the unsigned physical-device ARM64 build. They do **not** prove signing, installation, JIT activation, or guest execution on a physical iPad; those remain explicit device acceptance gates below.

## Selected first-playable route: QEMU TCI (no JIT)

The first playable physical-iOS guest is a known-good x86-64 Linux image booted through the full-system QEMU TCI interpreter. TCI is the selected no-JIT route: it does not require StikDebug, TXM, executable-memory entitlements, or a JIT pairing. The app's automatic acceleration mode may use JIT when available and fall back to TCI; the explicit QEMU interpreter mode selects TCI directly.

The custom `LinuxELFRuntime` and its two static ELF guests are diagnostic user-mode tests for Kenran Butō's interpreter/GuestMachine path. They are valuable regression tests, but they are **not** a bootable Linux OS and do not satisfy the first-playable emulator milestone. The separate core-only IPA workflow intentionally excludes QEMU and is diagnostic only.

The repository has a manual QEMU runtime build workflow for JIT and TCI variants and a release workflow that embeds the combined runtime. The release workflow is gated by `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED=true`; do not set this variable until qualified file-level and combined-work licensing review is complete. Without approval, the workflow may compile/validate but does not publish the QEMU runtime artifact or QEMU-enabled IPA.

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

### Gate 1 — Reproducible QEMU-free core-only diagnostic iOS build

- [ ] Run the core-only iOS workflow against the current GitLab \`main\` source.
- [ ] Confirm the workflow compiles the physical-device ARM64 target and produces the expected unsigned IPA.
- [ ] Record the source commit, workflow run, IPA checksum, bundle identifier, and effective entitlements.
- [ ] Sign and install the IPA on a physical iPad using a supported signing path.
- [ ] Confirm the app launches repeatedly without a simulator-only dependency.

This QEMU-free IPA validates the custom ELF/interpreter path only. It is a diagnostic build, not the first playable VM or a full-system guest.

### Gate 2 — Physical static-ELF diagnostic (not first playable)

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

The AOT path is optional for the first QEMU TCI guest. TCI does not require StikDebug or JIT. StikDebug pairing and JIT are required only to validate the optional accelerated user-mode path.

### Gate 4 — QEMU TCI display and input validation

- [ ] Connect the guest execution path to a guest framebuffer and a Metal-backed display.
- [ ] Route touch, hardware keyboard, and controller input into guest input events.
- [ ] Verify pause/resume, focus changes, orientation, and clean shutdown.
- [ ] Apply guest resolution and frame-rate settings to the actual renderer rather than only storing UI preferences.

For QEMU TCI, validate the existing VNC-to-Metal display and keyboard/controller event path on the physical device. The separate static ELF console remains text-only and has no independent framebuffer or guest-stdin contract.

### Gate 5 — Persistent QEMU guest disk state

- [ ] Implement a guest disk/block-device path with documented image formats.
- [ ] Persist guest writes across app restarts.
- [ ] Add save slots/snapshots with corruption-safe writes and recovery.
- [ ] Verify cleanup and repeat launches do not erase persistent guest data.

QEMU has a disk-image path, but write persistence across physical-device restarts, crash-safe snapshots, USB passthrough, and external-drive controller semantics still require device validation.

### Gate 6 — First playable: QEMU TCI full-system Linux boot (P0)

- [ ] Complete the qualified file-level and combined-work QEMU/UTM licensing review.
- [ ] Run the manual QEMU runtime build workflow and verify the `ios-tci` / `iOS-SE` TCI variant and its runtime manifest.
- [ ] Only after the licensing review, set `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED=true` and run the release workflow that embeds the QEMU TCI runtime into the iOS app.
- [ ] Confirm the resulting device IPA contains the TCI runtime, passes the runtime manifest and IPA validators, and has a recorded SHA-256.
- [ ] Sign/install the IPA on a physical iPad through SideStore or another supported path.
- [ ] Boot a known-good x86-64 Linux image through QEMU TCI with JIT disabled.
- [ ] Verify VNC-to-Metal display, keyboard/controller input, virtual-disk writes, clean shutdown, and repeat boots.
- [ ] Record device model, iPadOS version, app/TCI runtime versions, image checksums, logs, and a short screen recording.

QEMU TCI is the selected first playable no-JIT route. The manual build workflow can compile and validate TCI/JIT variants, but the release workflow intentionally withholds QEMU runtime artifacts and QEMU-enabled IPA packaging until the licensing approval variable is set after review. Bochs remains a research alternative, not an integrated or verified replacement.

## iOS signing and JIT prerequisites

- The interpreter smoke path must work without JIT and must size guest memory using available host memory.
- SideStore free-team signing may omit optional increased-memory entitlements from the effective installed signature; enabling an App ID capability is not proof that the installed app received it. Inspect effective entitlements after reinstall.
- \`get-task-allow\` is a separate requirement for StikDebug JIT. Missing JIT must disable AOT execution safely and preserve interpreter fallback.
- See [iOS memory entitlements](IOS_ENTITLEMENTS.md), [JIT activation](JIT_ACTIVATION.md), and [core-only iOS test build](CORE_ONLY_IOS_TEST_BUILD.md).

## Remaining features from older project requests

These items remain outside the first QEMU TCI Linux-boot milestone and should be implemented only after the physical guest path is stable.

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
| UTM/QEMU | Full-system emulation backend | QEMU TCI is the selected no-JIT first-playable route; the build/release workflows exist, but the GPL compatibility gate, TCI artifact, iOS IPA, and physical Linux boot remain unverified |
| Vapour Emu | Evaluate after its expected release | Date and availability are unverified; development must not wait for it |

## Repository/CI coordination and latest validation status

GitLab `main` and GitHub `main` are both at `1678a2d5245bdaa1cad75b4a94c1eaef61e1f27a`; direct commit comparison confirms exact parity. No branch reconciliation, merge, force-push, reset, rebase, branch creation, or deletion is needed for the current source.

### Current source changes

- `30a05994` adds mutex-serialized native guest-memory exchange for 1-, 4-, and 8-byte operands, cross-page handling, permission validation, Swift wrappers, and interpreter memory-form `0x86`/`0x87` support.
- `af00bceb` adds conservative CPUID reporting and a monotonic 1 GHz virtual RDTSC counter without advertising unsupported SIMD.
- `adf6a271` handles F3 90 PAUSE as a no-op.
- `afda2d49` hardens the core-only IPA validator for textual/numeric iOS Mach-O platform values and checks `CFBundleSupportedPlatforms`.
- `8c5d6f94` repairs the static smoke ELF program-header mapping, adds the NativeEmulation C object and bridging header to the native GuestMachine smoke compile, and includes GuestProcess in the PE test compile.
- `1678a2d5` expands IPA-validator regressions to reject simulator Mach-O and iPhoneSimulator bundle platforms.
- The QEMU runtime and release workflows already define JIT and TCI variants, runtime manifests, and the QEMU licensing gate. The TCI path is the intended no-JIT full-system route; it has not yet booted a guest on a physical iPad.

### Hosted and local validation evidence

- GitLab pipeline IID 1245 / ID `3112635187` on exact source SHA `1678a2d5` failed before runner assignment with `ci_quota_exceeded`; job `18351469324` had no runner, start time, or duration. No tests ran. Pipeline IID 1244 / ID `3112630205` on `8c5d6f94` was blocked the same way.
- GitHub core-only IPA run `45582606913` on older source `ad65030d` failed at static ELF loading because the diagnostic ELF did not map its program-header table. Commit `8c5d6f94` fixes that defect; the fix is now on current main.
- Earlier GitHub core-only IPA run `45580260610` on `2f082fae` passed its older runtime tests and packaged a QEMU-free unsigned IPA, but the old Mach-O validator rejected the device platform and skipped artifact upload. The validator fix and its regression tests are now on current main.
- Local validator checks passed: Bash syntax, source-contract checks, 4/4 platform regression cases, numeric/text device platform acceptance, simulator platform rejection, and QEMU payload rejection.
- Both static ELF diagnostic builders/tests passed on Linux x86-64; the guests printed `Linuxx86_64KENRAN_BUTO_RUNTIME_OK` and `KENRAN_BUTO_XCHG_OK`. A separate reconstructed AOT encoding smoke also passed MOV/LEA/XCHG/MOVZX and bounded-fallback checks. These are host tests, not iOS emulator execution.
- No current-head QEMU TCI runtime artifact, QEMU-enabled IPA, SideStore installation, or physical iPad Linux boot is verified.

### Runtime and older-feature boundary

The custom `LinuxELFRuntime` is a bounded diagnostic user-mode path. It is not a full-system OS emulator: `read(0, ...)` returns EOF and it has no independent framebuffer contract. The first playable route is the separate QEMU full-system TCI backend, which uses the VNC-to-Metal display/input path and a QEMU disk image. That route still needs a distributable TCI runtime, physical boot, display/input verification, and disk-persistence evidence.

FEXCore and Box64 are not operational iOS dynamic backends. Dynamic ELF/PT_TLS, broad Linux syscall/thread/signal support, Windows PE/EXE execution, Wine/Proton, full-system graphics/audio beyond the QEMU display path, save snapshots, USB passthrough, and Android/VR/tvOS/visionOS guest execution remain separate milestones.

### Required next actions

1. Run the manual QEMU runtime build workflow and validate the no-JIT TCI variant. It can compile/validate without publishing the runtime artifact.
2. Complete a qualified file-level and combined-work QEMU/UTM licensing review. Do not set `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED=true` before that review.
3. After approval, run the release workflow to embed the TCI runtime and produce a current physical-device iOS IPA.
4. Sign/install on a physical iPad and boot a known-good x86-64 Linux image through QEMU TCI with JIT disabled.
5. Verify VNC-to-Metal display, keyboard/controller input, disk persistence, clean stop, repeat boot, and cleanup; record logs and checksums.
6. Keep the QEMU-free core-only IPA and static ELF guests as separate diagnostic coverage for Kenran Butō's interpreter, guest memory, syscall and AOT paths.
7. After the first physical TCI boot, continue broader dynamic translation, Windows, Steam, snapshots, audio, and additional platform work.

A core-only IPA, static ELF host execution, simulator build, or QEMU compile alone does not satisfy the first-playable physical-device acceptance gate.

## Definition of done

The first playable physical iOS milestone is complete only when a reproducible current-source IPA containing the approved QEMU TCI runtime is installed on a physical iPad, a known-good x86-64 Linux image boots through TCI with JIT disabled, guest display and keyboard/controller input work, guest disk state survives restarts, repeat boots and cleanup are reliable, and build/test/device evidence is recorded. A QEMU-free core-only IPA, static ELF diagnostic, host execution, simulator run, or successful QEMU compilation alone is insufficient.

## Latest JIT source status (2026-11-25)

QEMU TCI is the selected first-playable no-JIT full-system route. It does not require StikDebug or TXM. The custom interpreter/static-ELF path is diagnostic coverage and remains useful as a correctness fallback. The 32 MiB TXM/SPTM arena and JIT path are optional acceleration work after TCI boot is proven; StikDebug 3.2.2+ is required for the iOS/iPadOS 27+ TXM/AOT pairing tests. No physical TCI boot or physical JIT/AOT execution is verified.

