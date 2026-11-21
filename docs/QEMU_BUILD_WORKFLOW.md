# QEMU iOS runtime build workflow

This note documents the iOS device-arm64 QEMU runtime build in `.github/workflows/build-qemu-runtime.yml` and the patch/verification scripts it invokes.

## Build flow

1. Check out UTM and its submodules on macOS 15 with Xcode and the iOS device SDK; install both `spirv-tools` and `spirv-llvm-translator` because Mesa's iOS cross-build checks for the `SPIRV-Tools` pkg-config dependency.
2. Locate Apple's `libclang_rt.ios.a` from the selected Xcode toolchain and expose it as `IOS_COMPILER_RT`.
3. Restore the UTM dependency/sysroot cache only when its key matches the UTM commit, selected Xcode/iOS SDK versions, and the workflow plus all QEMU patch scripts. The cache namespace is bumped when build behavior changes; the current namespace is v11.
4. Run `scripts/patch_utm_qemu_ios.py` against UTM's `scripts/build_dependencies.sh`. The patch is idempotent, fails if upstream changes the expected integration points, and rewrites the blocked GNU libiconv HTTP source URL to the official HTTPS archive path.
5. During UTM's dependency build, `scripts/patch_qemu_meson_ios.py` updates QEMU's iOS POSIX_MEMALIGN feature and adds Apple's compiler runtime to QEMU's `emulator_link_args` list, which is passed into the actual `libqemu-x86_64-softmmu.dylib` target's `link_args`.
6. Immediately after QEMU's Meson configure step and before its compilation starts, UTM invokes `scripts/verify_qemu_meson_link.py` against the QEMU source directory's `build/build.ninja` using `$PWD` (UTM's build helper has already changed into that source directory). It requires the `libqemu-x86_64-softmmu.dylib` link edge itself to contain the exact `-Wl,-force_load,<libclang_rt.ios.a>` argument. The build stops before thousands of compile tasks if the argument is absent.
7. Build the UTM iOS archive, package its device-arm64 QEMU library, framework dependencies and firmware/data, validate the artifact, and upload `iSteam-qemu-runtime-ios-arm64`.
8. The release workflow downloads that artifact from the same workflow run before packaging the iOS IPA; it does not fall back to a stale or optional runtime artifact.

## Patch and test files

- `scripts/patch_utm_qemu_ios.py` — idempotently patches the upstream UTM dependency script: POSIX_MEMALIGN cross-file feature, x86_64-softmmu target selection, QEMU Meson patch invocation, and a pre-build link verification hook.
- `scripts/patch_qemu_meson_ios.py` — patches QEMU's Meson feature probe and adds the compiler-runtime force-load argument to the emulator-specific link-argument list consumed by the generated shared-library target.
- `scripts/verify_qemu_meson_link.py` — inspects the generated Ninja link edge for `libqemu-x86_64-softmmu.dylib`; verifies the actual link configuration rather than checking only environment variables or source text.
- `scripts/tests/test_qemu_build_patches.py` — regression tests idempotence, expected patch insertion and fail-closed linker verification.
- `.github/workflows/build-qemu-runtime.yml` — reusable/manual runtime build, cache fingerprint and same-run artifact upload.
- `.github/workflows/release.yml` — runtime dependency ordering and required artifact download before the iOS IPA is packaged.
- `.github/workflows/validate-repository.yml` — strict YAML checks, both-direction mirror preservation, workflow contract checks and Python patcher tests.

## Runtime integration constraints

The in-app QEMU command builder uses an explicit q35 device graph rather than relying on implicit devices disabled by `-nodefaults`:

- An explicit ICH9 AHCI controller carries the guest disk and CD-ROM. Windows guests use the broadly supported AHCI path rather than requiring VirtIO storage drivers during installation.
- Windows guests use standard VGA and E1000E networking; Linux guests use the configured VirtIO GPU and VirtIO networking.
- USB keyboard/tablet devices are explicit. QEMU's monitor, serial and parallel consoles are disabled because the UI uses the loopback VNC client.
- The QEMU VNC server binds to `127.0.0.1`; the app accepts only the no-authentication RFB method on that loopback connection. Framebuffer allocation is capped at 64 MiB.
- SteamOS UEFI profiles require both a code image and a writable variable-store template. The app copies the template into per-configuration Application Support storage and passes it as the second pflash device; it never writes variables into the signed app bundle.
- Runtime preflight requires `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`. A library without graceful shutdown is rejected rather than starting a VM that the app cannot safely stop.

The launch picker currently accepts one bootable disk image or one ISO. An ISO can be used as live media, but a Windows installer cannot be completed until the UI exposes a separate writable destination disk. Do not describe ISO-based Windows installation as supported yet. The native QEMU bridge is intentionally one-shot per app process because the embedded QEMU global state is not proven safe to reinitialize. After stopping a QEMU guest, relaunch Akatsubaki Emu before starting another one. No physical-device guest boot has been verified.

## Run locally on macOS

```sh
python3 scripts/patch_utm_qemu_ios.py UTM/scripts/build_dependencies.sh
IOS_COMPILER_RT=/path/to/libclang_rt.ios.a python3 scripts/patch_qemu_meson_ios.py UTM/build-iOS-arm64/qemu-*/meson.build
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The normal workflow invokes the Meson patcher only after UTM has downloaded the QEMU source, and invokes the Ninja verifier after QEMU configure has generated `build/build.ninja`.

## Failure diagnosis and limits

- The November 21 dependency-build logs exposed two independent failures: Mesa stopped at `meson.build:2092:18` because `SPIRV-Tools` was not found, and a later run exhausted five retries downloading libiconv from `http://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz` (curl exit 28). The workflow now installs the missing Homebrew `spirv-tools` formula, and the UTM patch switches only that URL to `https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.16.tar.gz`; other source URLs are unchanged. The previously observed link failure was `___isPlatformVersionAtLeast` unresolved in `tcg/region.c.o`; the project-level Meson argument did not propagate into the explicit `emulator_link_args` list used by the generated shared-library target.
- The patch now changes the exact `emulator_link_args` list consumed by QEMU's `build_lib_args`; the pre-build verifier checks that generated target edge. It is designed to fail early if a future UTM/QEMU update stops propagating the Meson emulator-specific link arguments.
- A passing Ninja-file check proves only that the compiler-runtime argument is present in the configured link command. It does not prove that QEMU compiles, packages, loads on iOS, or boots a guest.
- The runtime workflow remains a macOS/Xcode CI job. It cannot be executed from an iPad browser or by the GitLab source editor itself.
- Do not modify `.github/workflows/blank.yml`; it is the required GitHub → GitLab sync workflow. The repository validator explicitly checks that it remains present.

## Validation

Run `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` for the deterministic patcher tests. The full CI workflow additionally validates YAML with duplicate-key rejection, checks the release/runtime artifact contract, validates QEMU source integration, and compiles the iOS/tvOS/visionOS simulator schemes. A successful simulator or source-validation job is not evidence of a physical iPad guest boot.
