# Akatsubaki Emu — First Playable iOS Audit

**Audit date:** 22 November 2026  
**Scope:** Kenran Butō hybrid execution, the existing QEMU full-system route, and requirements carried forward from earlier i-Steam/Akatsubaki discussions.

## Executive status

The repository now has an integrated, bounded x86-64-to-ARM64 AOT fast path inside the x86-64 interpreter, a validated guest-state ABI, W^X executable-memory management, persistent translation-cache validation, and interpreter side exits. The AOT path is deliberately conservative: unsupported instructions return to the interpreter rather than being executed speculatively.

The full-system QEMU path has JIT and no-JIT TCI build/package workflows, and this PR changes Automatic to choose TCI when QEMU JIT is not ready. However, the current canonical release workflow still expects the old flat runtime manifest while the dual-mode merger emits separate `QEMU/JIT` and `QEMU/TCI` manifests; the current packager also runs strict code-signature verification against UTM archives built with code signing disabled. Therefore the TCI/IPA pipeline is not yet verified end-to-end and must not be described as a working installable build.

**This is not yet a verified playable iPad build.** The ARM64 CI and static-ELF guest tests are pending. No physical iPad boot, guest interaction, repeat VM launch, or persistent-state test has been recorded.

## Implemented in PR #228 — pending CI

- Versioned C/Swift AOT guest-state and memory-callback ABI.
- W^X executable-memory provider with standard and StikDebug/TXM mapping paths.
- Bounded x86-64 AOT translation, with translator version and input/instruction/output budgets in cache identity.
- Persistent-cache revalidation against a fresh canonical translation; cache schema version advanced.
- AOT execution connected to `X86_64Interpreter` and installed by `GuestMachine`.
- Register snapshots and strict side-exit validation before committing native results; invalid or declining AOT backends fall back to the interpreter without corrupting guest state.
- ARM64 native AOT tests, including a synthetic static ELF that writes a known output through the Linux syscall shim.
- Automatic QEMU accelerator selection now uses TCI when QEMU JIT is unavailable.
- QEMU JIT error guidance now points to Automatic/TCI rather than incorrectly implying that the no-JIT runtime cannot be used.

## Existing runtime paths and limits

| Subsystem | Current repository state | Consequence |
|---|---|---|
| Kenran Butō AOT | Executable NOP/MOV subset; unsupported operations side-exit | Safe fast path, not a complete x86-64 translator |
| x86-64 interpreter | Diagnostic instruction subset and synthetic guest tests | Not a general-purpose CPU implementation |
| ELF loader | Static ET_EXEC and constrained static PIE/relative relocations | No general PT_INTERP/dynamic-linker path |
| Linux syscall ABI | Small syscall subset; limited standard descriptors and anonymous memory | Cannot yet host ordinary dynamically linked Linux applications |
| Guest memory | Sparse guest pages; mprotect currently validates ranges rather than enforcing full page permissions | Memory-protection semantics need completion |
| Windows PE | PE inspection/validation exists | It is not a Windows process loader |
| Windows process runtime | WindowsRuntime is unavailable/stubbed | Direct EXE launch needs a real Win32/NT compatibility runtime |
| Dynamic backends | FEXCore/Box64 and Wine/Proton are not operationally installed | The process router cannot provide broad Windows/Linux game compatibility |
| QEMU full-system | JIT and TCI build/package workflows and VM launch integration exist | This is the intended full-OS path, but guest boot is not yet proven on iPad |
| Graphics | QEMU build disables virglrenderer; current display path is 2D/VNC-oriented | No verified guest 3D acceleration or DirectX→Vulkan→Metal path |
| Input | QEMU keyboard/tablet path exists | Gamepad mapping/passthrough and full touch controls still need device validation |
| VM lifecycle | Native QEMU bridge deliberately guards against a second initialization in one app process | Repeated VM sessions require a proven QEMU reinitialization test or lifecycle redesign |

## Priority order for a real iOS run

### P0 — prove the no-JIT first boot

1. Get the AOT, repository-validation, and iOS device/simulator CI jobs green.
2. Run the release workflow so it builds the QEMU JIT and TCI runtime artifacts and embeds them in the unsigned device IPA.
3. Install that IPA on the physical ARM64 iPad with SideStore.
4. Leave the VM accelerator on Automatic; on a device without QEMU JIT readiness it should select TCI.
5. Boot a small, known-good x86-64 Linux image with a small RAM allocation first. Verify serial/VNC output independently, basic keyboard input, clean shutdown, and disk persistence.
6. Repeat after relaunching the app. The current QEMU one-shot guard means a second VM in the same process is not yet supported.

### P1 — make the VM usable

- Prove repeated QEMU start/stop cycles before removing the one-shot guard.
- Enforce guest page permissions and implement real `mprotect` semantics.
- Add the Linux file-descriptor and dynamic-loader syscall surface needed for ordinary dynamically linked programs.
- Validate persistent disks, import/export, external storage, and memory-pressure behavior on device.
- Complete touch, pointer, keyboard, and game-controller translation against a real guest.

### P2 — broader game compatibility

- Integrate and benchmark a legally compatible ARM64-hosted dynamic x86-64 backend (evaluate FEXCore and Box64 separately; do not treat them as interchangeable).
- Add a real Windows user-mode path using the required Win32/NT services and a compatible Wine/Proton layer; keep the PE parser separate from execution.
- Build and validate a guest 3D path. The existing QEMU configuration does not establish virgl/3D support; DirectX→Vulkan→Metal remains a separate, substantial subsystem.
- Expand AOT only with differential tests against the interpreter. Do not promote unsupported instruction families to native execution until flags, memory faults, control flow, and state restoration are covered.

## Acceptance evidence required before calling the emulator playable

- Reproducible physical iOS ARM64 IPA build and installation.
- A known-good guest boots end-to-end on the iPad using TCI or a verified JIT path.
- Independently checked guest output, not just a successful app launch.
- Basic guest keyboard/touch interaction.
- Clean stop and resource cleanup.
- A repeat launch and a persistent guest disk/state check.
- Recorded device model, iPadOS version, build commit, runtime mode, guest image hash, logs, and test result.

## Scope carried forward from earlier project discussions

Preserve the full-Windows-guest direction (not a PE-only pretend runtime), Linux guest support, Steam library/launch integration, external drives and persistent VM storage, save/session handling, controller and touchscreen input, keyboard function-key controls, and future graphics/VR experiments. These are product requirements, not evidence that the corresponding execution backends already exist.

## Additional iOS packaging and shared-branch findings

These were confirmed against the current canonical `main` and the live related review branches during the cross-chat audit:

- **Release manifest mismatch:** the runtime merger emits `QEMU/JIT/runtime-library-path.txt`, `QEMU/TCI/runtime-library-path.txt`, and per-mode exports. Current `.github/workflows/release.yml` still reads `QEMU/runtime-library-path.txt` and a root `exports.txt`, and requires the JIT callback unconditionally. The release step therefore cannot correctly embed/validate the merged dual-mode artifact yet.
- **Unsigned runtime validation:** UTM archives are created with `CODE_SIGNING_ALLOWED=NO`, but `scripts/validate-qemu-runtime.sh` unconditionally calls `codesign --verify --strict`. Structural Mach-O/platform/export validation must be separate from optional final signature validation; the intermediate unsigned runtime must be accepted.
- **Toolchain mismatch:** the QEMU runtime workflow requires Xcode 27.x on `xcode-27`, while the current release app-archive job selects Xcode 26.2 on `macos-26`. Align the toolchain before claiming a reproducible combined IPA.
- **Runtime-build CI gap:** `.github/workflows/build-qemu-runtime.yml` is reusable/manual; a normal PR does not build the UTM JIT/TCI runtime. A fresh hosted build and artifact inspection are still required. PR #234 is actively reconciling the TCI packaging and release contract; its latest branch uses separate clean UTM checkouts for JIT and TCI, which should be preserved.
- **Guest-memory permissions:** current `main` has no active page-permission map in `NativeGuestMemory`; the syscall `mprotect` path validates bounds rather than enforcing R/W/X permissions. PR #235 is exploring a native permission model, but its current branch has unresolved source-integrity, lifecycle, and loader/syscall integration findings. Do not rely on that branch until its native harness passes and ELF PT_LOAD, stack, heap, mmap, mprotect and munmap call sites are wired.
- **Shared JIT protocol branch:** the duplicate `iSteamJITDetach` definition reported in PR #218 is branch-specific; current `main` has one physical-iOS implementation and one non-iOS fallback. Do not treat the stale PR branch finding as a current-main compile failure.

The packaging and memory findings are not duplicated in PR #228 code because other shared PRs (#234 and #235) are actively addressing those subsystems. They remain release/first-playable blockers until merged and validated.
