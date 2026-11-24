# Core-only iOS test build (no QEMU runtime)

This manual workflow produces an unsigned iOS arm64 IPA containing the Akatsubaki Emu application and its interpreter/AOT code, but **no QEMU engine, QEMU firmware, or QEMU runtime manifest**.

It exists to validate the iOS app shell and the bounded static x86-64 ELF execution path while the separate QEMU combined-work licensing review remains open. It is not a full-system VM build and does not enable Windows 10, QEMU TCI/JIT, or guest graphics through QEMU.

The workflow installs XcodeGen and regenerates iSteam.xcodeproj from project.yml before building, ensuring the device project receives the configured GNU C++17 language standard.

## Run

1. Open GitHub Actions and select **Build Core-Only iOS IPA**.
2. Choose **Run workflow** on main.
3. Wait for the Akatsubaki-Emu-CoreOnly-iOS-* artifact.
4. Download the artifact and install the unsigned IPA using SideStore or another permitted signing workflow.
5. Copy a static x86-64 Linux ELF to the iPad. In the app choose **Import Game / Executable**, select the ELF, and launch it.
6. Inspect the emulator runtime log for guest stdout and the final exit status.

The same Akatsubaki-Emu-CoreOnly-iOS-* artifact includes hybrid_xchg_smoke.elf alongside the IPA, build information and Xcode build log. It prints hello and exits with status 0; import this file in step 5. The Ubuntu repository-validation test executes the guest directly and checks that deliberately broken inputs for all four 32-bit/64-bit accumulator and register-only ModRM XCHG forms take the nonzero failure exit. The Apple Silicon workflow also passes the same generated ELF to the Swift static-ELF harness, which executes it through the x86-64 interpreter without JIT; it never attempts native x86-64 execution on the ARM64 host.

The companion hybrid_xchg_smoke.elf test artifact exercises 32-bit accumulator XCHG EAX,ECX; 64-bit accumulator XCHG RAX,R9; 32-bit register-only ModRM XCHG R8D,R9D; 64-bit register-only ModRM XCHG R10,R11; MOV immediate; CMP/JNE interpreter-fallback checks; RIP-relative LEA; and Linux write/exit syscalls. It is a diagnostic program, not a Linux distribution.

## Limits

- The IPA is unsigned. SideStore signing is still required.
- The QEMU runtime is intentionally absent; full-system guest boot is unavailable in this build.
- The ELF interpreter is a bounded diagnostic bring-up path, not a complete Linux ABI. Dynamic ELF dependencies, PT_INTERP, PT_TLS, broad syscalls, and general userspace compatibility remain incomplete.
- This workflow does not publish a GitHub Release or create a tag. The artifact is retained for seven days.
- The separate GPL compatibility gate remains in force for any IPA or runtime that bundles QEMU.
