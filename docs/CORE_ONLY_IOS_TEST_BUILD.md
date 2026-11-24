# Core-only iOS test build (no QEMU runtime)

This manual workflow produces an unsigned iOS arm64 IPA containing the Akatsubaki Emu application and its interpreter/AOT code, but **no QEMU engine, QEMU firmware, or QEMU runtime manifest**.

It exists to validate the iOS app shell and the bounded static x86-64 ELF execution path while the separate QEMU combined-work licensing review remains open. It is not a full-system VM build and does not enable Windows 10, QEMU TCI/JIT, or guest graphics through QEMU.

## Run

1. Open GitHub Actions and select **Build Core-Only iOS IPA**.
2. Choose **Run workflow** on `main`.
3. Wait for the `Akatsubaki-Emu-CoreOnly-iOS-*` artifact.
4. Download the artifact and install the unsigned IPA using SideStore or another permitted signing workflow.
5. Copy a static x86-64 Linux ELF to the iPad. In the app choose **Import Game / Executable**, select the ELF, and launch it.
6. Inspect the emulator runtime log for guest stdout and the final exit status.

The companion `hybrid_xchg_smoke.elf` test artifact exercises 32-bit and 64-bit accumulator and register-only ModRM XCHG, MOV immediate, RIP-relative LEA, CMP/JNE, and Linux `write`/`exit` syscalls. It is a diagnostic program, not a Linux distribution.

## Limits

- The IPA is unsigned. SideStore signing is still required.
- The QEMU runtime is intentionally absent; full-system guest boot is unavailable in this build.
- The ELF interpreter is a bounded diagnostic bring-up path, not a complete Linux ABI. Dynamic ELF dependencies, PT_INTERP, PT_TLS, broad syscalls, and general userspace compatibility remain incomplete.
- This workflow does not publish a GitHub Release or create a tag. The artifact is retained for seven days.
- The separate GPL compatibility gate remains in force for any IPA or runtime that bundles QEMU.
