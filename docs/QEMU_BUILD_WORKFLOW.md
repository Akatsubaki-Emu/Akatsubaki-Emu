# QEMU iOS runtime build workflow

This note documents the iOS device-arm64 QEMU runtime build in `.github/workflows/build-qemu-runtime.yml` and the patch/verification scripts it invokes.

## Build flow

1. Check out UTM and its submodules on the macOS 26 runner with Xcode 26.2 and the iOS device SDK; install both `spirv-tools` and `spirv-llvm-translator` because Mesa's iOS cross-build checks for the `SPIRV-Tools` pkg-config dependency.
2. Locate Apple's `libclang_rt.ios.a` from the selected Xcode toolchain and expose it as `IOS_COMPILER_RT`.
3. Restore the UTM dependency/sysroot cache only when its key matches the UTM commit, selected Xcode/iOS SDK versions, and the workflow plus all QEMU patch scripts. The cache namespace is bumped when build behavior changes; the current namespace is v12.
4. Run `scripts/patch_utm_qemu_ios.py` against UTM's `scripts/build_dependencies.sh`. It installs the StikDebug TCG allocator patcher before QEMU configure, then installs the existing Meson/link-verifier hooks; the patch is idempotent and fails if upstream changes its expected integration points.
5. During UTM's dependency build, `scripts/patch_qemu_stikjit_ios.py` patches QEMU `tcg/region.c`: on iOS 26+ it obtains the RX translation buffer from the host app's StikDebug breakpoint protocol, remaps a writable alias, and detaches the debugger after the one-time allocation. Earlier iOS releases retain UTM's existing split-WX allocator. `scripts/patch_qemu_meson_ios.py` then updates QEMU's iOS POSIX_MEMALIGN feature and adds Apple's compiler runtime to the emulator-specific link arguments.
6. Immediately after QEMU's Meson configure step and before its compilation starts, UTM invokes `scripts/verify_qemu_meson_link.py` against the QEMU source directory's `build/build.ninja` using `$PWD` (UTM's build helper has already changed into that source directory). It requires the `libqemu-x86_64-softmmu.dylib` link edge itself to contain the exact `-Wl,-force_load,<libclang_rt.ios.a>` argument. The build stops before thousands of compile tasks if the argument is absent.
7. Build the UTM iOS archive, package its device-arm64 QEMU library, framework dependencies and firmware/data. The packager verifies both the `arm64` architecture and Mach-O `IOS` build platform, rejecting macOS or simulator binaries before upload. Validate the artifact and upload `iSteam-qemu-runtime-ios-arm64`.
8. The release workflow downloads that artifact from the same workflow run before packaging the iOS IPA; it does not fall back to a stale or optional runtime artifact.

## Patch and test files

- `scripts/patch_utm_qemu_ios.py` — idempotently patches the upstream UTM dependency script and invokes the JIT allocator patcher before QEMU configure.
- `scripts/patch_qemu_stikjit_ios.py` — patches QEMU's Darwin split-W^X TCG allocator to request one debugger-prepared RX region on iOS 26+ and create its RW alias.
- `scripts/patch_qemu_meson_ios.py` — patches QEMU's Meson feature probe and adds the compiler-runtime force-load argument to the emulator-specific link-argument list consumed by the generated shared-library target. Its unique marker lets it replace only its own runtime entry while preserving unrelated upstream linker arguments.
- `scripts/verify_qemu_meson_link.py` — inspects the generated Ninja link edge for `libqemu-x86_64-softmmu.dylib`; verifies the actual link configuration rather than checking only environment variables or source text.
- `scripts/tests/test_qemu_build_patches.py` — regression tests idempotence, StikDebug allocator insertion, split-WX command construction, expected patch insertion and fail-closed linker verification.
- `.github/workflows/build-qemu-runtime.yml` — reusable/manual runtime build, cache fingerprint, non-cancelling concurrency policy and same-run artifact upload.
- `.github/workflows/release.yml` — runtime dependency ordering and required artifact download before the iOS IPA is packaged.
- `.github/workflows/validate-repository.yml` — strict YAML checks, both-direction mirror preservation, workflow contract checks and Python patcher tests.

## Runtime integration constraints

The in-app QEMU command builder uses an explicit q35 device graph rather than relying on implicit devices disabled by `-nodefaults`. Both acceleration profiles request split-WX: the 128 MiB profile uses the larger translation buffer, while the 64 MiB profile is still TCG JIT, not a JIT-less interpreter.

- An explicit ICH9 AHCI controller carries the guest disk and CD-ROM. Windows guests use the broadly supported AHCI path rather than requiring VirtIO storage drivers during installation.
- Windows guests use standard VGA and E1000E networking; Linux guests use the configured VirtIO GPU and VirtIO networking.
- USB keyboard/tablet devices are explicit. QEMU's monitor, serial and parallel consoles are disabled because the UI uses the loopback VNC client.
- The QEMU VNC server binds to `127.0.0.1`; the app accepts only the no-authentication RFB method on that loopback connection. Framebuffer allocation is capped at 64 MiB.
- Windows and SteamOS UEFI profiles require both a code image and a writable variable-store template. The app copies the template into per-configuration Application Support storage and passes it as the second pflash device; it never writes variables into the signed app bundle.
- Runtime packaging and preflight require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, `qemu_system_shutdown_request`, and `isteam_qemu_set_jit_callbacks`. The packager and standalone validator reject a library missing the StikDebug JIT callback registration export or graceful shutdown rather than uploading an artifact the native bridge cannot start.
- On iOS 17.4+, QEMU startup requires an active StikDebug debugger session. On iOS 26+, the patched TCG allocator obtains the executable RX region through `iSteamJITPrepareRegion`, creates the writable alias with `mach_vm_remap`/`mach_vm_protect`, and calls `iSteamJITDetach` once the buffer is ready. The app checks `CS_DEBUGGED` before starting; this protects against calling the breakpoint protocol when no debugger is attached.

The launch picker currently accepts one bootable disk image or one ISO. An ISO can be used as live media, but a Windows installer cannot be completed until the UI exposes a separate writable destination disk. Do not describe ISO-based Windows installation as supported yet. The native QEMU bridge is intentionally one-shot per app process because the embedded QEMU global state is not proven safe to reinitialize. After stopping a QEMU guest, relaunch Akatsubaki Emu before starting another one. No physical-device guest boot has been verified.

## Run locally on macOS

```sh
ISTEAM_QEMU_JIT_PATCHER=scripts/patch_qemu_stikjit_ios.py python3 scripts/patch_utm_qemu_ios.py UTM/scripts/build_dependencies.sh
IOS_COMPILER_RT=/path/to/libclang_rt.ios.a python3 scripts/patch_qemu_meson_ios.py UTM/build-iOS-arm64/qemu-*/meson.build
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The normal workflow invokes the Meson patcher only after UTM has downloaded the QEMU source, and invokes the Ninja verifier after QEMU configure has generated `build/build.ninja`.

## Failure diagnosis and limits

- The November 22 GitHub Actions QEMU build on macOS 15 selected Xcode 16.4 and stopped in Mesa's Metal bridge because `Metal/MTL4ArgumentTable.h` was unavailable. The runtime job now uses `macos-26`, explicitly selects Xcode 26.2, verifies the selected version before dependency installation, and invalidates the prior dependency cache with namespace v12.

- The release app-build matrix and platform-validation workflow also pin `macos-26` and Xcode 26.2; the separate release publisher runs on `ubuntu-24.04` and verifies downloaded assets with `sha256sum -c`.
- The November 21 dependency-build logs exposed two independent failures: Mesa stopped at `meson.build:2092:18` because `SPIRV-Tools` was not found, and a later run exhausted five retries downloading libiconv from `http://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz` (curl exit 28). The workflow now installs the missing Homebrew `spirv-tools` formula, and the UTM patch switches only that URL to `https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.16.tar.gz`; other source URLs are unchanged. The previously observed link failure was `___isPlatformVersionAtLeast` unresolved in `tcg/region.c.o`; the project-level Meson argument did not propagate into the explicit `emulator_link_args` list used by the generated shared-library target.
- The patch now changes the exact `emulator_link_args` list consumed by QEMU's `build_lib_args`; the pre-build verifier checks that generated target edge. The 19:07 UTC failure in [run 44936563725](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/runs/44936563725) confirms that the older project-level argument did not reach that edge. The patcher now owns one uniquely marked compiler-runtime entry and preserves unrelated upstream `-Wl,-force_load` arguments when updating or rerunning the patch. It is designed to fail early if a future UTM/QEMU update stops propagating the Meson emulator-specific link arguments.
- A passing patcher test proves only that the source transformation is inserted correctly. A passing Ninja-file check proves only that the compiler-runtime argument is present in the configured link command. It does not prove that QEMU compiles, packages, loads on iOS, or boots a guest.
- The runtime workflow remains a macOS/Xcode CI job. It cannot be executed from an iPad browser or by the GitLab source editor itself. The iOS 26+ StikDebug allocator patch has not yet been compiled against UTM's pinned QEMU source or exercised on a physical iPad.
- Do not modify `.github/workflows/blank.yml`; it is the required GitHub → GitLab sync workflow. The repository validator explicitly checks that it remains present.

## Validation

Run `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` for the deterministic patcher tests. The full CI workflow additionally validates YAML with duplicate-key rejection, checks the release/runtime artifact contract, validates QEMU source integration, and compiles the iOS/tvOS/visionOS simulator schemes. A successful simulator or source-validation job is not evidence of a physical iPad guest boot.
