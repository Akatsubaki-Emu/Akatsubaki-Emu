# QEMU iOS runtime build workflow

This note documents the iOS device-arm64 QEMU runtime build in `.github/workflows/build-qemu-runtime.yml` and the patch/verification scripts it invokes.

## Upstream UTM target mapping

| Runtime | UTM dependency platform | Xcode scheme | Archive application |
|---|---|---|---|
| JIT | `ios` | `iOS` | `UTM.app` |
| TCI | `ios-tci` | `iOS-SE` | `UTM SE.app` |

`ios-tci` is the dependency/sysroot platform identifier. The corresponding Xcode scheme is `iOS-SE`, not `iOS-TCI`.

TCI means **Tiny Code Interpreter** (not “threaded code interpreter”). QEMU still translates guest instructions into TCG bytecode; the TCI backend interprets that bytecode instead of emitting native host instructions. This avoids native-code JIT/executable-memory requirements, with lower performance than native TCG. See the [upstream QEMU TCI README](https://github.com/qemu/qemu/blob/master/tcg/tci/README).

## Pinned upstream source

The runtime workflow checks out UTM at the immutable source revision [`3d4b8d8cb1ce93a8b1a9610695c12487685f0c15`](https://github.com/utmapp/UTM/commit/3d4b8d8cb1ce93a8b1a9610695c12487685f0c15), which reports UTM version **5.0.9**. It intentionally does not track the moving `main` branch. Recursive submodules are resolved from the pinned UTM tree. The workflow verifies that this UTM revision selects QEMU `v10.0.12-utm`, writes the source URL into both JIT and TCI input packages, and the merge step verifies that both inputs agree and preserves the common URL at the final combined runtime root. The actual checked-out UTM revision is also recorded in the merged artifact.

Update this pin only after reviewing the upstream changes, submodule revisions, iOS/iOS-SE schemes, dependency targets, local QEMU patch compatibility and applicable third-party notices. The JIT and TCI archives must both pass the runtime packagers and export checks before a new pin is accepted.

## QEMU licensing and distribution gate

The pinned UTM source selects the QEMU `v10.0.12-utm` tarball. QEMU's own licensing explanation identifies QEMU as a whole as GPLv2, with per-file exceptions; this is not a blanket GPLv2-or-later grant. The exact QEMU fork and every linked dependency must be audited at the pinned versions.

Akatsubaki Emu's top-level application license is GPLv3. Since the QEMU runtime is loaded as an in-process shared library, do not assume that separate framework packaging or dynamic linking settles GPL compatibility. Before publishing or redistributing a combined IPA, obtain a qualified file-level and combined-work licensing review, preserve source and notices, and secure any required permissions. Do not change the project's top-level license without authorization from all relevant rights holders.

References: [QEMU licensing](https://www.qemu.org/license.html), [UTM third-party licenses](https://getutm.app/licenses/).

## Build flow

1. Check out UTM and its submodules on the GitHub-hosted `xcode-27` arm64 runner with the active Xcode 27.x toolchain and the iOS device SDK (the current runner image supplies Xcode 27.3 beta; the workflow validates the installed major version and compiler probes instead of pinning a minor-version path); install both `spirv-tools` and `spirv-llvm-translator` because Mesa's iOS cross-build checks for the `SPIRV-Tools` pkg-config dependency.
2. Locate Apple's `libclang_rt.ios.a` from the selected Xcode toolchain and expose it as `IOS_COMPILER_RT`.
3. Restore the UTM dependency/sysroot cache only when its key matches the UTM commit, selected Xcode/iOS SDK versions, and the workflow plus all QEMU patch scripts. The cache namespace is bumped when build behavior changes; the current namespace is v15.
4. The workflow input `tci_guest_targets` defaults to `x86_64-softmmu` for the first playable x86-64 Linux guest. The UTM patcher validates a comma-separated list of `*-softmmu` targets before passing it to QEMU. To build the full pinned UTM target set, set the input to `aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu`. The JIT build remains x86-64-only.
5. Run `scripts/patch_utm_qemu_ios.py` against UTM's `scripts/build_dependencies.sh`. It installs the StikDebug TCG allocator patcher only for the JIT dependency target; the TCI target skips it. Both targets receive the shared Meson/link-verifier hooks. The patch is idempotent and fails if upstream changes its expected integration points.
6. During the JIT dependency build, `scripts/patch_qemu_stikjit_ios.py` patches QEMU `tcg/region.c` and `system/qemu.symbols`: it exports `qemu_system_shutdown_request` and `isteam_qemu_set_jit_callbacks` through the explicit Darwin symbol list, while storing the host app's readiness, executable-region preparation, and detach callbacks in QEMU-owned function pointers. Default symbol visibility alone cannot bypass Meson's `-exported_symbols_list`. In JIT mode on iOS 26+, QEMU obtains the RX translation buffer through that callback ABI, remaps a writable alias, and detaches the debugger after the one-time allocation. The app blocks JIT startup below iOS 26 until the split-WX fallback is separately validated. The TCI dependency build skips this executable-memory patch and deliberately omits the JIT callback export. `scripts/patch_qemu_meson_ios.py` is shared by both builds; it updates QEMU's iOS POSIX_MEMALIGN feature and adds Objective-C fast message stubs, `libobjc`, and Apple's compiler runtime to the emulator-specific link arguments.
7. Immediately after QEMU's Meson configure step and before its compilation starts, UTM invokes `scripts/verify_qemu_meson_link.py` against the QEMU source directory's `build/build.ninja` using `$PWD` (UTM's build helper has already changed into that source directory). It requires the `libqemu-x86_64-softmmu.dylib` link edge itself to contain `-Wl,-objc_stubs_fast`, `-lobjc`, and the exact `-Wl,-force_load,<libclang_rt.ios.a>` argument. The build stops before thousands of compile tasks if the argument is absent.
8. Save the pristine `UTM.xcodeproj/project.pbxproj` before mode-specific archive preparation. Run `scripts/prune_utm_missing_qemu_frameworks.py` against `sysroot-iOS-arm64/Frameworks`; it removes only QEMU softmmu framework build-file/file-reference/phase entries whose framework bundles are absent, while requiring the x86-64 runtime. Validate the edited project with `plutil -lint`, then archive scheme `iOS` (product `UTM.app`). Restore the pristine project before applying the same pruner against `sysroot-iOS-TCI-arm64/Frameworks`; this is essential because the JIT and TCI target sets can differ, and pruning one mode must not silently remove frameworks needed by the other. Validate and archive scheme `iOS-SE` (product `UTM SE.app`). Their dependency platforms are `ios` and `ios-tci`, respectively. Package both device-arm64 QEMU libraries, framework dependencies and firmware/data. The packagers verify the `arm64` architecture and Mach-O `IOS` build platform, rejecting macOS or simulator binaries before upload. Validate the combined artifact and upload `AkatsubakiEmu-qemu-runtime-ios-arm64`.
9. The release workflow downloads that artifact from the same workflow run before packaging the iOS IPA; it does not fall back to a stale or optional runtime artifact.

## Patch and test files

- `scripts/patch_utm_qemu_ios.py` — idempotently patches the upstream UTM dependency script, defaults TCI to `x86_64-softmmu`, validates an optional comma-separated `*-softmmu` target list, applies the StikDebug allocator patch only to the JIT target, skips it for TCI, and installs the shared Meson/link-verification hooks.
- `scripts/prune_utm_missing_qemu_frameworks.py` — prunes Xcode references to QEMU softmmu frameworks absent from the selected physical-iOS sysroot, requires `qemu-x86_64-softmmu.framework`, and verifies that no removed Xcode object IDs remain.
- `scripts/tests/test_utm_framework_pruner.py` — verifies missing-object removal, idempotence, the required x86-64 guard, and independent pristine-project restoration between JIT and TCI archive steps.
- `scripts/patch_qemu_stikjit_ios.py` — patches QEMU's Darwin split-W^X TCG allocator, exports the explicit host JIT callback setter, and requests one debugger-prepared RX region on iOS 26+ before creating its RW alias.
- `scripts/patch_qemu_meson_ios.py` — patches QEMU's Meson feature probe, filters unsupported Objective-C warning flags with `checked: 'off'` while requiring the iOS class-selector-stub flag, and adds Objective-C fast message-stub generation, `libobjc`, and the compiler-runtime force-load argument to the emulator-specific link-argument list consumed by the generated shared-library target. Its unique marker lets it replace only its own runtime entry while preserving unrelated upstream linker arguments.
- `scripts/verify_qemu_meson_link.py` — inspects the generated Ninja link edge for `libqemu-x86_64-softmmu.dylib`; verifies the actual link configuration includes Objective-C stub generation, `libobjc`, and compiler-rt rather than checking only environment variables or source text.
- `scripts/tests/test_qemu_build_patches.py` — regression tests idempotence, TCI target-list insertion, StikDebug allocator insertion, split-WX command construction, expected patch insertion and fail-closed linker verification.
- `scripts/tests/test_qemu_tci_target_list.py` — behavioral tests for the x86-64 default, multi-architecture overrides, shell-metacharacter rejection, idempotence and fail-closed handling of incomplete overrides.
- `.github/workflows/build-qemu-runtime.yml` — reusable/manual runtime build, cache fingerprint, non-cancelling concurrency policy and same-run artifact upload.
- `.github/workflows/release.yml` — runtime dependency ordering and required artifact download before the iOS IPA is packaged.
- `.github/workflows/validate-repository.yml` — strict YAML checks, both-direction mirror preservation, workflow contract checks and Python patcher tests.

## Runtime integration constraints

The in-app QEMU command builder uses an explicit q35 device graph rather than relying on implicit devices disabled by `-nodefaults`. The workflow defines both JIT and no-JIT TCI build/package paths. JIT uses UTM's `iOS` scheme and `ios` dependency target; TCI uses `iOS-SE` and `ios-tci`, with `UTM SE.app` as its archive product. The workflow and release publisher have explicit JIT and no-JIT TCI build/package paths. The runtime merger places the variants under `QEMU/JIT` and `QEMU/TCI`, embeds their corresponding frameworks and firmware data, and the release app-build workflow embeds the combined runtime package. A successful hosted dual-runtime build and physical-device startup have not yet been recorded. The Settings UI exposes TCI; the runtime loader validates the selected device-arm64 library and data before native startup. Automatic mode uses JIT when ready and falls back to TCI when JIT readiness or the JIT library is unavailable. Do not treat a smaller TCG translation-block cache or plain `-accel tcg` as a no-JIT fallback; TCI must be built with QEMU's Tiny Code Interpreter backend, which interprets TCG bytecode instead of generating native host code.

- An explicit ICH9 AHCI controller carries the guest disk and CD-ROM. Windows guests use the broadly supported AHCI path rather than requiring VirtIO storage drivers during installation.
- Windows guests use standard VGA and E1000E networking; Linux guests use the configured VirtIO GPU and VirtIO networking.
- USB keyboard/tablet devices are explicit. QEMU's monitor, serial and parallel consoles are disabled because the UI uses the loopback VNC client.
- The QEMU VNC server binds to `127.0.0.1`; the app accepts only the no-authentication RFB method on that loopback connection. Framebuffer allocation is capped at 64 MiB.
- Windows and SteamOS UEFI profiles require both a code image and a writable variable-store template. The app copies the template into per-configuration Application Support storage and passes it as the second pflash device; it never writes variables into the signed app bundle.
- Runtime packaging and preflight require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request` in both modes. Only JIT additionally requires `isteam_qemu_set_jit_callbacks`; TCI must not export that callback. The mode-specific packagers and standalone validator reject libraries that violate their export contract or omit graceful shutdown.
- JIT mode is currently permitted only on physical iOS 26+ devices with a valid `get-task-allow` entitlement, a recognised StikDebug JIT protocol (standard split-WX or TXM), and confirmed executable-memory readiness. General StikDebug JIT acquisition on iOS 17.4+ does not by itself make QEMU JIT available on those older OS versions. On iOS 26+, the patched JIT allocator obtains the executable RX region through `iSteamJITPrepareRegion`, creates the writable alias with `mach_vm_remap`/`mach_vm_protect`, and calls `iSteamJITDetach` once the buffer is ready. The app checks `CS_DEBUGGED` before starting; this protects against calling the breakpoint protocol when no debugger is attached. TCI uses QEMU's Tiny Code Interpreter backend and bypasses the JIT entitlement, protocol and executable-memory readiness checks.

The iOS launch flow accepts one boot disk or installer/live ISO plus an optional writable disk. For ISO installation, QEMU attaches the writable destination as the first AHCI hard disk and the ISO as optical media on a separate port. Launch Setup can create a sparse raw destination disk in app storage or select an existing disk image. Existing one-disk sessions remain supported, and Continue from Last Session preserves the optional second-disk bookmark. The native QEMU bridge is intentionally one-shot per app process because the embedded QEMU global state is not proven safe to reinitialize. After stopping a QEMU guest, relaunch Akatsubaki Emu before starting another one. No physical-device guest boot has been verified.

## Run locally on macOS

```sh
ISTEAM_QEMU_JIT_PATCHER=scripts/patch_qemu_stikjit_ios.py python3 scripts/patch_utm_qemu_ios.py UTM/scripts/build_dependencies.sh
IOS_COMPILER_RT=/path/to/libclang_rt.ios.a python3 scripts/patch_qemu_meson_ios.py UTM/build-iOS-arm64/qemu-*/meson.build
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The normal workflow invokes the Meson patcher only after UTM has downloaded the QEMU source, and invokes the Ninja verifier after QEMU configure has generated `build/build.ninja`.

## Failure diagnosis and limits

- The November 22 GitHub Actions QEMU build on macOS 15 selected Xcode 16.4 and stopped in Mesa's Metal bridge because `Metal/MTL4ArgumentTable.h` was unavailable. The QEMU runtime job uses GitHub's `xcode-27` arm64 runner and selects its active Xcode 27.x toolchain dynamically. The current runner image supplies Xcode 27.3 beta; compiler/linker compatibility probes validate the required flags. This toolchain supports the Objective-C class-selector-stub compiler option rejected by Xcode 26.2. The workflow verifies the compiler flag against a Metal probe, checks that the object has no unresolved `_objc_msgSendClass` reference, and links that probe with the exact `-Wl,-objc_stubs_fast`, `-lobjc`, and Metal framework arguments used by the QEMU target. It captures `nm` output separately so inspection failures stop the job, and invalidates the dependency cache with namespace v15.

- The release app-build matrix and platform-validation workflow now use the `xcode-27` runner and require Xcode 27.1 or later; the separate release publisher runs on `ubuntu-24.04` and verifies downloaded assets with `sha256sum -c`.
- The November 21 dependency-build logs exposed two independent failures: Mesa stopped at `meson.build:2092:18` because `SPIRV-Tools` was not found, and a later run exhausted five retries downloading libiconv from `http://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz` (curl exit 28). The workflow now installs the missing Homebrew `spirv-tools` formula, and the UTM patch switches only that URL to `https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.16.tar.gz`; other source URLs are unchanged. The previously observed link failure was `___isPlatformVersionAtLeast` unresolved in `tcg/region.c.o`; the project-level Meson argument did not propagate into the explicit `emulator_link_args` list used by the generated shared-library target.
- The patch now changes the exact `emulator_link_args` list consumed by QEMU's `build_lib_args`; the pre-build verifier checks that generated target edge. The 19:07 UTC failure in [run 44936563725](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/runs/44936563725) confirms that the older project-level argument did not reach that edge. The patcher now owns one uniquely marked compiler-runtime entry and preserves unrelated upstream `-Wl,-force_load` arguments when updating or rerunning the patch. It is designed to fail early if a future UTM/QEMU update stops propagating the Meson emulator-specific link arguments.
- The November 22 physical iOS arm64 link reached `libqemu-x86_64-softmmu.dylib` but failed on `_objc_msgSendClass$renderPassDescriptor$_OBJC_CLASS_$_MTLRenderPassDescriptor`. The QEMU target contains an Objective-C Metal object but Meson links it through the C linker. The linker-only fix was insufficient, while Xcode 26.2 rejected `-fno-objc-msgsend-class-selector-stubs` as an unknown argument. The workflow now selects the active Xcode 27.x toolchain, probes that flag with the same Metal class-method expression, passes it through `OBJCFLAGS`, and retains the Meson-level `-Wl,-objc_stubs_fast`/`-lobjc` arguments and target-edge verifier. This remains unverified until a fresh physical iOS arm64 QEMU link completes.
- The QEMU build workflow was found with a truncated Objective-C shell conditional and duplicated dependency/build/package steps. Commit `b6e96739` restores the conditional, removes duplicate steps, and adds source checks requiring every workflow stage exactly once.
- Commit `d92984a8` fixes the QEMU/host JIT callback ABI by exporting `isteam_qemu_set_jit_callbacks`; commit `df6d93cf` adds its strict-C prototype. These source changes have not yet been compiled against UTM's pinned QEMU source.
- **GitLab manual validation:** `.gitlab-ci.yml` retains a manual-only `core-source-and-elf-validation` pipeline, restricted to the existing `main` branch and `web`/`api` triggers. The latest run, IID 1273 on `37011be3`, failed before runner allocation with `ci_quota_exceeded`; no tests executed. GitHub Actions remains the automated source-contract/patcher validation path, and the physical iOS QEMU build remains the separate manual macOS/Xcode workflow. GitHub `main` is behind the required GitLab write target, so those GitHub workflows have not validated the newer GitLab commits.
- A passing patcher test proves only that the source transformation is inserted correctly. A passing Ninja-file check proves only that the compiler-runtime argument is present in the configured link command. It does not prove that QEMU compiles, packages, loads on iOS, or boots a guest.
- The runtime workflow remains a macOS/Xcode CI job. It cannot be executed from an iPad browser or by the GitLab source editor itself. A fresh macOS/Xcode build is still required to verify the repaired workflow, exported callback ABI, physical-iOS Mach-O packaging, and a physical-device guest boot.
- Do not modify `.github/workflows/blank.yml`; it is the required GitHub → GitLab sync workflow. The repository validator explicitly checks that it remains present.

## Validation

Run `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` for the deterministic patcher tests. The full CI workflow additionally validates YAML with duplicate-key rejection, checks the release/runtime artifact contract, validates QEMU source integration, and compiles the iOS/tvOS/visionOS simulator schemes. A successful simulator or source-validation job is not evidence of a physical iPad guest boot.


The host JIT protocol is now tri-state and uses StikJIT's IOKit memory-map query. Standard devices use the existing split-WX allocator; confirmed TXM devices use the exported QEMU callback setter and StikDebug breakpoint allocator; unknown devices fail closed. The IOKit-linked host changes and QEMU selector still require a fresh macOS/Xcode build and physical-device validation.


## Objective-C class-selector compile verification

The Meson patcher now adds `-fno-objc-msgsend-class-selector-stubs` directly to QEMU's Objective-C project arguments with `checked: 'require'`. This is separate from the existing `OBJCFLAGS` environment fallback and the emulator link flags. The generated Ninja file is checked before compilation: the `spice-display-metal.m.o` Objective-C compile edge must contain the flag, and the QEMU dylib link edge must still contain `-objc_stubs_fast`, `-lobjc`, and the forced iOS compiler runtime. The build fails before the expensive compile if either edge is missing its required flags.


## Publication gate and channel tags

The combined IPA release and QEMU runtime artifact upload require the repository Actions variable `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED` to be set to the string `true` after qualified file-level and combined-work licensing review. Leave it unset until review is complete; while unset, the release workflow skips QEMU runtime distribution, IPA builds and publication. The standalone manual `build-qemu-runtime.yml` workflow can still be dispatched to compile and validate both JIT and TCI variants in an ephemeral runner. Its manual input defaults `rebuild_dependencies` to `true`, which bypasses dependency-cache restore/save, and the final runtime artifact is not uploaded while approval is unset. This is an engineering-only compile check, not a distributable build. The normal repository-validation workflow continues to run.

The main and nightly release tag names are intentionally retained because the AltStore/PAL updater keys off those names. Release assets update in place, but tag references are never force-pushed; the release notes record the exact source commit.
