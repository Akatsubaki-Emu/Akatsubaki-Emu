# Core-only iOS test build (no QEMU runtime)

This manual workflow produces an unsigned iOS arm64 IPA containing the Akatsubaki Emu application and its interpreter/AOT code, but **no QEMU engine, QEMU firmware, or QEMU runtime manifest**.

It exists to validate the iOS app shell and the bounded static x86-64 ELF execution path while the separate QEMU combined-work licensing review remains open. It is not a full-system VM build and does not enable Windows 10, QEMU TCI/JIT, or guest graphics through QEMU.

The workflow installs XcodeGen and regenerates iSteam.xcodeproj from project.yml before building, ensuring the device project receives the configured GNU C++17 language standard.

## Run

1. Open GitHub Actions and select **Build Core-Only iOS IPA**.
2. Choose **Run workflow** on main.
3. Wait for the Akatsubaki-Emu-CoreOnly-iOS-* artifact.
4. Download the artifact and install the unsigned IPA using SideStore or another permitted signing workflow.
5. Copy `hybrid_xchg_smoke.elf` from the downloaded artifact to the iPad. In the app choose **Import Game / Executable**, select the ELF, and launch it.
6. Inspect the emulator runtime log for guest stdout and the final exit status.

The same Akatsubaki-Emu-CoreOnly-iOS-* artifact includes `hybrid_xchg_smoke.elf`, its Python builder, focused test, and SHA-256 manifest alongside the IPA, build information and Xcode build log. It prints `KENRAN_BUTO_XCHG_OK` and exits with status `0`; import this file in step 5. The Ubuntu repository-validation test executes the guest directly and checks that deliberately broken inputs for all four 32-bit/64-bit accumulator and register-only ModRM XCHG forms take the nonzero failure exit. The Apple Silicon workflow also passes the same generated ELF to the Swift static-ELF harness, which executes it through the x86-64 interpreter without JIT; it never attempts native x86-64 execution on the ARM64 host.

The diagnostic guest exercises 32-bit accumulator `XCHG EAX,ECX`; 64-bit accumulator `XCHG RAX,R9`; 32-bit register-only ModRM `XCHG R8D,R9D`; 64-bit register-only ModRM `XCHG R10,R11`; MOV immediate; CMP/JNE interpreter-fallback checks; RIP-relative LEA; and Linux `write`/`exit` syscalls. It is a diagnostic program, not a Linux distribution.

## Limits

- The IPA is unsigned. SideStore signing is still required.
- The QEMU runtime is intentionally absent; full-system guest boot is unavailable in this build.
- The ELF interpreter is a bounded diagnostic bring-up path, not a complete Linux ABI. Dynamic ELF dependencies, PT_INTERP, PT_TLS, broad syscalls, and general userspace compatibility remain incomplete.
- This workflow does not publish a GitHub Release or create a tag. The artifact is retained for seven days.
- The separate GPL compatibility gate remains in force for any IPA or runtime that bundles QEMU.


## Additional end-to-end runtime smoke guest

The build now includes a second static guest, hybrid_runtime_smoke.elf. It calls Linux syscall 63 (uname) into a separate writable PT_LOAD segment, writes the virtual sysname and machine fields to stdout, writes KENRAN_BUTO_RUNTIME_OK, and exits with status 0.

Expected console output includes Linux, x86_64, KENRAN_BUTO_RUNTIME_OK, and guest exit status 0.

This guest checks separate RX and RW mappings, the zero-filled data segment, guest-memory write/read permissions, syscall dispatch, stdout and process-exit propagation in one no-JIT interpreter run. The XCHG guest remains the focused instruction/ALU smoke test.

On a physical iPad, import both ELF files from the core-only IPA's smoke-kit artifact through Import Game / Executable, launch them from My Games, and verify both markers and exit statuses. Host execution of the Python-generated ELF is not a substitute for this device test.


## GitLab validation artifact

The GitLab main-branch API/web validation pipeline also builds and runs both static guests and retains them as job artifacts for seven days. The job is deliberately manual/API-triggered; if GitLab reports shared-runner quota exhaustion, no tests have run and the pipeline must be retried after quota is restored.


## Native GuestMachine integration regression

The core-only iOS workflow now runs the runtime smoke guest through the application's actual GuestMachine, ELF64Loader, LinuxProcessStackBuilder, X86_64Interpreter and C-backed GuestMemory implementation. It checks uname-written guest memory, captured stdout, exit status 0, a second launch after CPU reset, and guest-page cleanup after stop.

This closes the previous test-double-only gap for the execution engine. It still does not replace installation and execution on a physical iPad.
