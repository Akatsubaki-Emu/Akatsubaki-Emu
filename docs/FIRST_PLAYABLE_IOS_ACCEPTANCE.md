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

At this audit, GitLab `main` is `fae7c262dcb5bc9238790f6317f360d125d23a7a` and GitHub `main` is `c25947b03e48fd1157d21f20e895ca726c831599`. GitLab is a direct descendant of GitHub and is four commits ahead: `4192b5e8` (metrics contract test), `9025ccaf` (first-playable status documentation), `3026c1bf` (interpreter stop-state synchronization), and `fae7c262` (register-only XCHG interpreter fallback, dispatcher test mapping, and Node 24 artifact action versions). The histories are not divergent. The configured automatic sync only pushes GitHub to GitLab, so it cannot publish these GitLab-only commits back to GitHub. No force-push, reset, rebase, merge, or branch creation has been performed. A non-forced fast-forward of GitHub main to GitLab main requires explicit owner authorization.

### Hosted validation evidence

- **Core-only iOS workflow #8** (run `45575957355`) checked out `c25947b0`. Xcode 27.1 selection, XcodeGen generation, QEMU-free checks and executable-arena tests passed. The Python suite passed 414/415 tests; the only failure was the obsolete metrics-workflow assertion that expected the removed GitHub mirror dispatch. Commit `4192b5e8` updates that test to the artifact-only contract. Commit `fae7c262` also upgrades both metrics artifact uploads from `actions/upload-artifact@v4` to `@v7`, matching the repository's Node.js 24 action-version validator. No Swift runtime tests, device build, IPA packaging, or artifact upload ran in that workflow.
- **Kenran Butō AOT workflow** (run `45575131823`) checked out older commit `55996e0c`. Decoder, cache, executable-memory, iOS TXM source compile and source-contract steps passed; the page-crossing interpreter harness failed at line 1769. The correction `e97b25e1` is in current main's ancestry, but no successful exact-head AOT rerun is recorded.
- GitLab pipeline IID 1224 / ID `3112464887` on `4192b5e8` and IID 1225 / ID `3112471173` on `3026c1bf` both failed before runner assignment with `ci_quota_exceeded`. Retry job `18350225415` also failed before runner assignment. No hosted tests ran in those pipelines.
- Commit `3026c1bf` fixes an interpreter stop-state data race by routing stop-flag reads through a lock-protected helper and adds a source-contract regression. Commit `fae7c262` adds the register-only `XCHG 0x87` interpreter fallback required when AOT is unavailable; existing interpreter regressions compare baseline and hybrid execution for extended registers and 32-bit zero-extension. The commits have not yet been validated by hosted CI.
- The same `fae7c262` change maps the Linux syscall test's output buffer before its mprotect assertions. This is test setup, not a runtime behavior change.
- Earlier iOS device ARM64 compilation and tvOS/visionOS simulator builds passed on an older common ancestor, not on current main. No current-main IPA, SideStore installation, or physical iPad guest execution is verified.

### Required next actions

1. Obtain explicit owner authorization for a non-forced fast-forward of GitHub main to the existing GitLab main; do not create a branch or force-push.
2. Run AOT validation, full repository validation and the QEMU-free core-only iOS IPA workflow against the exact current commit. Resolve any newly exposed test or compile failures.
3. Produce and checksum the unsigned physical-device ARM64 IPA; record bundle ID and effective entitlements.
4. Sign/install through SideStore and execute both diagnostic static ELF guests through the app's actual import-to-runtime path on the physical iPad. Record stdout, exit codes, cleanup and repeat-launch evidence.
5. Validate TXM/AOT separately. The no-JIT interpreter smoke path must remain functional without StikDebug; iOS/iPadOS 27+ AOT pairing requires StikDebug 3.2.2 or newer.

A simulator build, host-side ELF run, source-level JIT implementation, or IPA archive alone does not satisfy the physical-device acceptance gates.

## Definition of done

The first playable physical iOS milestone is complete only when a reproducible current-source IPA is installed on a physical iPad, a known-good guest executes through the app's real import-to-runtime path, basic guest display and input work, repeat launches and cleanup are reliable, persistent guest state survives restarts, and the build/test/device evidence is recorded. A simulator run, host-side ELF execution, or successful IPA packaging alone is insufficient.


## Latest JIT source status (2026-11-24)

The Kenran Butō iOS AOT allocator now has a separate preallocated-arena detach path: one 32 MiB TXM/SPTM executable region, one writable alias, then `iSteamJITDetachPreparedArena`; its arena-ready state is independent of QEMU’s attached-session callback. Hardware detection recognizes both TXM and SPTM. QEMU retains its no-op detach for lazy regions. This remains **UNTESTED on a physical iPad**; interpreter execution is the first-playable fallback and does not require JIT.
