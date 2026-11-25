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

At this audit, GitLab `main` and GitHub `main` both point to `c25947b03e48fd1157d21f20e895ca726c831599`. The previous 08:25 handoff recorded temporary divergence; subsequent synchronization has brought both refs to the same commit. No force-push, reset, rebase, merge, or branch creation was performed in this session.

The repository documentation still describes GitHub as canonical and GitLab as a downstream mirror, while the active project engineering instructions designate GitLab `main` as the write target. That policy mismatch remains unresolved. Do not change mirror direction or run history reconciliation without explicit owner approval.

### Hosted validation evidence

- **Core-only iOS workflow #8** (run `45572464006`) checked out the older commit `440f288b5b42728b4c16283f50c4eabf84e9d507`, not current `main`. Xcode 27.1 selection, XcodeGen installation/project generation, QEMU-free source checks, and the executable-arena tests passed (5 suites, 20,000 stress operations). The Python suite ran 415 tests and had two harness failures: `test_smoke_artifact_packaging.py` raised `NameError: workflow is not defined`, and `test_elf_sparse_memory_reset.py` asserted an obsolete source pattern. Both test files have subsequent corrections on current `main` (verified by comparing `440f288` to `c25947b`). The job stopped before the Swift runtime tests, native GuestMachine test, device build, IPA packaging, or artifact upload.
- **Kenran Butō AOT workflow #222** (run `45572463949`) also checked out `440f288`. Workflow YAML, iOS arm64 JIT source compilation, fixed-buffer allocation checks, guest-RAM budget checks, executable-arena tests, backend-routing checks, and repository source-contract tests passed. The decoder test then failed in the old XCHG high-register test: it treated word indices as byte offsets (0, 4, 8). Current `main` corrects the test to assert a 12-byte result and inspect word indices 0, 1, and 2. No AOT execution or static-ELF guest test ran in that workflow.
- **GitLab pipeline #1222** on `c25947b` is marked failed, with `core-source-and-elf-validation` as its job. Its trace was not available during this audit because of GitLab API rate limiting; its failure cause is therefore unclassified. The preceding pipeline #1221 was separately recorded as failing before runner assignment due to shared CI quota exhaustion.

These are stale-run results, not current-head validation. The current `c25947b` source has not yet been validated by a completed AOT run or core-only IPA run. No current IPA artifact, signing/install evidence, or physical-iPad guest execution is verified.

### Required next actions

1. Run the AOT validation workflow and core-only iOS IPA workflow against current `main` (`c25947b`); resolve any remaining failures on that exact commit.
2. Build and checksum the unsigned physical-device ARM64 IPA; record its bundle identifier and effective entitlements.
3. Sign and install through SideStore on a physical iPad.
4. Import and run both diagnostic ELF guests, verify their success markers and exit status 0, then repeat launches and verify cleanup.
5. Validate TXM/AOT separately. The no-JIT interpreter smoke path must remain functional without StikDebug. For iPadOS 27+ AOT pairing, use StikDebug 3.2.2 or newer.

A simulator build, host-side ELF run, source-level JIT implementation, or IPA archive alone does not satisfy the physical-device acceptance gates.

## Definition of done

The first playable physical iOS milestone is complete only when a reproducible current-source IPA is installed on a physical iPad, a known-good guest executes through the app's real import-to-runtime path, basic guest display and input work, repeat launches and cleanup are reliable, persistent guest state survives restarts, and the build/test/device evidence is recorded. A simulator run, host-side ELF execution, or successful IPA packaging alone is insufficient.


## Latest JIT source status (2026-11-24)

The Kenran Butō iOS AOT allocator now has a separate preallocated-arena detach path: one 32 MiB TXM/SPTM executable region, one writable alias, then `iSteamJITDetachPreparedArena`; its arena-ready state is independent of QEMU’s attached-session callback. Hardware detection recognizes both TXM and SPTM. QEMU retains its no-op detach for lazy regions. This remains **UNTESTED on a physical iPad**; interpreter execution is the first-playable fallback and does not require JIT.
