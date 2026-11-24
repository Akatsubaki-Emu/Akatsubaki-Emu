# Kenran Butō (絢爛舞踏) — Hybrid runtime composition

- **System name:** Kenran Butō (絢爛舞踏).
- **Status:** composable execution-policy prototype with an explicit upstream-reuse strategy. The translation-cache artifact layer, bounded x86-64 → AArch64 AOT bring-up, limited static Linux process-entry stack, and QEMU integration work exist. FEXCore, Box64, Wine, Proton and a32rt are planned reuse/port targets, not currently integrated or packaged as a working user-mode stack.
- **Component naming:** Kenran Butō AOT is a bounded static x86-64 → ARM64 translator bring-up; Kenran Butō Cache stores validated translated-code artifacts; Kenran Butō Router selects backends and fallback; Kenran Butō Runtime orchestrates execution; Kenran Butō Graphics owns graphics translation. These names do not imply that missing implementations are complete.
- **Planner:** `src/Runtime/ExecutionBackendRouter.swift`
- **Cache:** `src/Performance/TranslationCache.swift`
- **Launch entry point:** `src/Steam/GameLauncher.swift` → `src/Steam/LinuxELFRuntime` (bounded static ELF bring-up through `GuestMachine`) or `src/Runtime/WindowsRuntime.swift` (Windows path still requires a verified compatibility stack)
- **Related code:** `src/Runtime/WindowsPEImage.swift`, `src/Runtime/WindowsPELoader.swift`, `src/Runtime/X86_64Interpreter.swift`, `iSteam/Box64Bridge.*`, `src/QEMU/`, `src/Windows/`, `src/GPU/`.

## How simultaneous composition works

"Use everything simultaneously" means composing independent stages, not running every CPU emulator against the same instruction stream.

1. **AOT cache:** run validated, previously translated ARM64 code for supported guest modules/blocks.
2. **Dynamic translator:** one selected translator handles cache misses, invalidated code and runtime-generated code. FEXCore and Box64 are alternatives for a given process, not concurrent duplicate engines.
3. **Diagnostic interpreter:** only a limited bring-up fallback for instructions the translation pipeline cannot yet handle. It is not a general game compatibility engine.
4. **OS compatibility:** Windows PE loading, DLL/import handling, Win32/NT services and Wine/Proton are composed with the CPU path.
5. **Graphics:** DirectX → Vulkan → Metal is a separate pipeline and can run alongside CPU work when the required translation layers are present.
6. **Host services:** audio, input, networking and storage are orthogonal subsystems and can run alongside CPU/GPU work.
7. **Full-system fallback:** QEMU TCG owns a complete guest machine when a whole OS/kernel is required. It is not an in-process fallback for a PE executable and cannot share CPU execution with Wine/FEX/Box64 for the same process.
8. **Architecture-specific paths:** a32rt is only for ARM32 guests; native ARM64 is used only where the guest ABI is compatible.

## Routing policy

| Guest workload | Composition |
|---|---|
| Windows x64 PE process | AOT cache + one of Wine/Proton+FEXCore or Wine/Proton+Box64; Win32/DLL compatibility; optional DirectX→Vulkan→Metal; audio/input/network/storage services |
| Linux x64 ELF process | AOT cache + one of FEXCore or Box64; Linux syscall ABI; diagnostic interpreter only for limited bring-up |
| ARM32 Linux ELF | a32rt architecture backend; QEMU full-system where a complete OS is needed |
| Native ARM64 process | native ARM64 under a compatible ABI |
| Complete OS/kernel | QEMU TCG full-system emulation |

## Upstream reuse and porting plan

The development strategy is to reuse mature upstream implementations wherever they solve a subsystem better than a new in-house implementation. Kenran Butō owns orchestration, platform adapters, guest-state contracts, policy, validation and integration; it should not reimplement a mature CPU translator or Windows compatibility layer without a measured reason.

### Target composition

| Subsystem | Preferred upstream implementation | Role in Kenran Butō | Porting boundary |
|---|---|---|---|
| Linux x86-64 → ARM64 user-mode execution | **FEXCore** (primary candidate) | Main dynamic translation engine for Linux x86-64 processes; reuse its decoder/IR/recompiler and supported instruction implementation | FEX is designed and tested for ARM64 Linux. iOS requires a Darwin host layer, syscall/runtime boundary, signal/thread/memory integration and Apple executable-memory policy work. Do not assume upstream FEX runs unchanged on iOS. |
| Linux x86-64 compatibility alternative | **Box64** | Secondary backend for workloads where its compatibility or measured performance is better; keep behind the same process/runtime interface | Box64 is also Linux-oriented and depends on Linux process, loader, signal and library behavior. Port and package it as an alternative, not as a second translator for the same process. |
| Windows user-mode API compatibility | **Wine** | PE process environment, Win32/NT user-mode APIs, DLL loading and Windows runtime behavior | Wine is not a CPU translator. It must be paired with exactly one x86-64 execution backend and a compatible guest userspace/root filesystem. Darwin/iOS host integration and required services must be evaluated separately. |
| Windows game distribution/runtime layer | **Proton** | Optional game-focused Wine configuration, patches and components after a minimal Wine path works | Proton is built around Steam-on-Linux assumptions and a collection of separately licensed dependencies. Port only the required components; do not treat Proton as a replacement for Wine or the CPU translator. |
| ARM32 guest execution | **a32rt** | Dedicated ARM32 execution backend where the guest ABI and source project match the required workload | Verify the exact upstream repository, revision, API, supported host OS and licence before selecting or importing code. It does not replace x86-64 translation or provide a complete Linux syscall ABI by itself. |
| Whole operating system / kernel | **QEMU TCG** | Full-system emulation, including booting complete guest OS images | Keep QEMU independent of user-mode FEX/Box64/Wine/Proton processes. Prefer the no-JIT TCI route where it is the viable iOS path; validate JIT separately. |
| Static hot-block acceleration | **Kenran Butō AOT/cache** | Optional project-owned fast path for a deliberately bounded subset and validated cached translations | Avoid building a competing general-purpose translator. Keep it only where differential tests and benchmarks demonstrate value over FEXCore/Box64. |

### Execution rules

1. A process selects **one** x86-64 dynamic translator: FEXCore or Box64. Never execute the same guest thread through both.
2. Wine supplies Windows API compatibility; Proton layers game-oriented patches/configuration and selected components over Wine. Neither is a CPU emulator.
3. The selected translator, Wine/Proton layer, guest root filesystem, syscall ABI and host services must be versioned and validated as one runtime profile.
4. QEMU owns a complete guest machine and its kernel. Do not try to compose QEMU TCG and FEX/Box64 as simultaneous CPU engines for the same guest process.
5. a32rt is an architecture-specific ARM32 route. Native ARM64 is used only when the guest ABI is genuinely compatible.
6. Keep the current diagnostic interpreter and bounded custom AOT translator as bring-up tools until upstream engines are built, integrated and proven. Do not silently route workloads to an unavailable backend.
7. Preserve the guest execution-context boundary so engines can be swapped without rewriting loaders, storage, display, input or application UI.

### Integration sequence — optimise for the first playable build

**Track A — first physical guest (continues immediately):**
1. Finish and package the QEMU TCI no-JIT runtime and its iOS device-arm64 dependencies.
2. Build the unsigned iOS IPA, install it on a physical iPad, and boot a known-good small Linux guest.
3. Verify display, input, stop/cleanup, repeat launch and persistent disk state. This is the first-playable acceptance path; do not block it on Wine/Proton or user-mode translator ports.

**Track B — reusable user-mode engines (parallel after the shared interfaces are stable):**
1. Pin and audit FEXCore's upstream revision, licence and dependencies; build a minimal ARM64 host-side library harness and measure the build footprint.
2. Define the Darwin host adapter and explicit Linux guest syscall, signal, thread, memory-map, loader and filesystem contracts. Port FEXCore incrementally and run its upstream correctness tests plus differential guest tests.
3. Benchmark the existing bounded interpreter/AOT path against FEXCore before deciding which custom code remains useful.
4. Evaluate Box64 against the same Linux ELF test corpus. Integrate it only if it adds compatibility or performance that justifies a second backend.
5. Add Wine only after one x86-64 engine can run a Linux userspace reliably. Start with a small Windows console program, DLL loading and Win32 API tests before graphical applications.
6. Add Proton as an optional profile after Wine works; audit each submodule and dependency independently and port only the components that can be supported on Apple platforms.
7. Audit and integrate a32rt against a named upstream source and ARM32 test corpus; connect its Linux syscall/runtime adapter before advertising ARM32 support.

### Licensing, provenance and platform gates

- The project is GPL-3.0. Record the exact upstream URL, commit, licence, copyright notices, modifications and transitive dependency licences for every imported component.
- FEXCore's upstream repository identifies the project as MIT-licensed and targets ARM64 Linux; Box64, Wine and Proton have their own licence terms and dependency trees. Proton's submodules must be audited individually rather than assuming the top-level licence covers every component.
- Do not copy code from an unverified project called “a32rt”: first establish the canonical repository and licence. Keep it as a candidate until that check is complete.
- Prefer linking or vendoring an unmodified upstream component with its notices where practical. Keep local iOS changes in clearly separated patch sets and preserve upstream attribution.
- A successful ARM64 compile is not proof of iOS compatibility. Each candidate must pass device-SDK compilation, dependency closure, runtime loading, guest correctness tests, memory/permission checks and physical-device validation.
- No upstream project listed in this plan is currently promoted to an operational iOS backend solely by this plan. Runtime capability registration must remain fail-closed until the concrete binary, ABI, dependencies and guest workload have been tested.

## What is actually integrated today

- **Translation cache:** stores versioned translated-code artifacts using a cache identity that includes guest-code SHA-256, guest architecture, translator identity/version, host architecture, CPU features and guest ABI. Each artifact has an integrity digest, is written atomically, is rejected and removed if corrupt or mismatched, and is bounded to 8 MiB per code artifact, 512 entries and 256 MiB total. Cache entries can be explicitly invalidated. The cache itself returns validated bytes; the Linux ELF AOT execution adapter revalidates cached translations, materializes bounded ARM64 blocks through the W^X executable-memory provider, and invokes them only while live JIT readiness is present. Declined or revoked blocks fall back to the interpreter.
- **Windows PE:** `WindowsPEImage` performs bounded metadata inspection; `WindowsPELoader` is read-only inspection. No PE image mapping, executable memory, import resolver, AOT translator or Windows process execution engine is integrated.
- **Static AOT:** `X86_64AOTTranslator` currently translates a deliberately small subset (NOP, exact ENDBR64 fallback until guest CET policy is represented, MOV immediate and register-only MOV) and stops at the first unsupported instruction with an exact fallback offset. `KenranButoAOTCompiler` keys and caches the validated artifact. This is not a complete decoder/IR/code generator/relinker and the executable adapter dispatches only this small subset through a versioned guest-state ABI, with exact interpreter side exits for unsupported instructions.
- **FEXCore:** not integrated or packaged.
- **Box64:** a C/Swift bridge can look for an already-loaded Box64 entry point. It does not bundle Box64, provide a Linux rootfs/syscall ABI, or prove game execution.
- **Wine/Proton:** not integrated.
- **QEMU:** `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI library and asks the native bridge to load it with `RTLD_NOW`. Both modes require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`; only JIT mode requires `isteam_qemu_set_jit_callbacks`. `RuntimeCapabilityRegistry` records a loadable library as `loadable`, not `operational`, so it cannot yet make QEMU selectable in the planner. The bridge is deliberately one-shot per app process because QEMU global-state reinitialization is not proven safe. The shared runtime uses QMP to pause and resume the same guest; generation leases prevent stale backends from stopping or resetting a newer session, and duplicate active starts are rejected. Switching configurations requires an app restart. The JIT profile uses native TCG code generation with a 128 MiB split-WX translation buffer. The TCI profile uses UTM's threaded TCG interpreter, selects `-accel tcg`, and does not require executable-memory JIT. The runtime workflow builds the upstream UTM `iOS` and `iOS-SE` schemes using the `ios` and `ios-tci` dependency targets, respectively; the TCI archive product is `UTM SE.app`. Both are packaged under `QEMU/JIT` and `QEMU/TCI`. A successful hosted dual-runtime build and physical guest boot remain unverified. On physical iOS 26+, the host queries `IODeviceTree:/chosen/memory-map` through IOKit and classifies the JIT protocol as UNKNOWN, STANDARD, or STIKDEBUG/TXM, matching StikJIT's query. Empty, malformed, inaccessible, or missing registry data blocks JIT launch and JIT allocation, but does not block the no-JIT TCI path. STANDARD devices retain QEMU's normal split-WX allocator; confirmed TXM devices use the exported `isteam_qemu_set_jit_callbacks` ABI to obtain the RX region, remap its RW alias, and detach the debugger. Launch Setup rejects unknown protocol modes and waits for `CS_DEBUGGED` only when the JIT profile is selected; TCI bypasses JIT readiness. `QEMUNativeRuntime` repeats the readiness check before JIT startup. Simulator, tvOS and visionOS skip the physical-iOS JIT request path. QEMU remains full-system only, not a PE process translator. Guest boot, firmware compatibility, device-level graceful stop, display/input and persistence remain unverified.
- **Linux ELF startup:** `GameLauncher` first asks `RuntimeBackendRouter` for the explicitly subset-validated interpreter route before starting `LinuxELFRuntime`, which owns a `GuestMachine`, injects the optional Kenran Butō AOT executor for the supported NOP/MOV subset, and runs bounded batches with cooperative stop; unsupported instructions side-exit to the interpreter. The capability registry labels this interpreter `validatedSubset`, not `operational`, and deliberately leaves the full `linuxSyscallABI` layer unavailable; the router permits only the bounded diagnostic subset and keeps general Linux execution false. `ELF64Loader` maps static ET_EXEC and self-contained ET_DYN PIE images, verifies program-header mapping, and applies bounded R_X86_64_RELATIVE relocations. `LinuxProcessStackBuilder` creates an aligned initial stack with argv, envp, AT_PHDR/AT_PHENT/AT_PHNUM, AT_ENTRY, AT_RANDOM and AT_EXECFN. PT_INTERP, DT_NEEDED dependencies, non-relative relocations, ELF PT_TLS initialization and a complete syscall ABI remain unsupported. Static PIE support is limited to self-contained images using R_X86_64_RELATIVE relocations; it is not a dynamic linker. The interpreter now handles ARCH_SET_FS/GS and ARCH_GET_FS/GS plus FS/GS-based memory operands; this is segment-base support, not a complete ELF TLS loader. The interpreter's syscall shim currently covers stdout/stderr write and bounded writev, stdin EOF, brk, anonymous mmap/munmap, mprotect/madvise validation, clock_gettime/gettimeofday, getrandom, process identity, and a small single-thread subset; it does not provide a guest filesystem, dynamic loader, ELF TLS initialization or full signal/thread semantics. A synthetic static ELF smoke test exercises the complete supported path from ELF loading and initial stack setup through x86-64 execution, Linux write and exit. The iOS game library now exposes imported entries and routes console launches through `GameLauncher`; this does not make dynamic ELF binaries, general Linux applications or commercial games compatible.
- **Interpreter:** diagnostic x86-64 subset with 8-bit register moves and byte memory stores with high-byte/REX semantics; byte ADD/OR/AND/SUB/XOR/CMP/TEST register/memory and immediate forms plus 32/64-bit register and memory operations; 32/64-bit memory forms of MOV/LEA/ADD/SUB/CMP/AND/OR/XOR; signed IMUL, MOVSXD and MOVZX/MOVSX byte/word extensions; ModRM/SIB base-index-scale and RIP-relative addressing (including trailing-immediate displacement bases); sign-extended immediate arithmetic; CF/PF/AF/ZF/SF/OF flags; Linux SYSCALL RCX/R11 return-state semantics; all 16 short/near conditional branches; SETcc and CMOVcc; multi-byte NOP; SHL/SHR/SAR immediate, one and CL forms; byte and wider TEST-immediate, NOT, NEG, INC and DEC; C7 immediates; direct register/immediate PUSH and register POP, LEAVE/RET-imm16, indirect CALL/JMP/PUSH, accumulator/register XCHG; exact ENDBR64 (`F3 0F 1E FA`) landing-pad no-op handling for legacy execution (CET enforcement is not implemented). Other memory widths and addressing prefixes, SIMD, atomics, exceptions, paging, and most Linux syscalls remain unsupported; this is not a general game backend.
- **a32rt:** not integrated. A future Linux ARM32 ELF process route must also provide the Linux syscall ABI; the translator alone is not a launchable runtime.
- **Graphics:** Metal framebuffer presentation exists; DirectX→Vulkan→Metal guest translation is not integrated.
- **Audio/input/network/storage:** host and prototype services exist in parts, but complete guest-device adapters are not proven.

The planner's availability set must be populated only by concrete runtime probes that validate the binary, architecture, ABI, transitive libraries, required compatibility services and platform constraints. The QEMU probe now validates loadability and lifecycle exports, but the higher-level planner is not yet wired to populate availability from this probe. A source file or enum case is not proof that a backend is installed. Empty availability is deliberately safe.

## Performance policy

- Prefer native ARM64 guest code when its ABI is already compatible.
- Reuse cached AOT translations only when source hash, translator version, CPU feature set, host architecture and guest ABI match.
- Use exactly one dynamic translator per process; prefer FEX or Box64 only after compatibility and measured performance checks.
- Compile hot blocks asynchronously where permitted; never block the render/input thread for translation.
- Keep QEMU for whole-machine requirements rather than routing every simple process through it.
- Bound guest memory, translation cache growth, worker concurrency and framebuffer allocations to device capabilities.
- Keep graphics translation independent from CPU translation and use Metal-native presentation when possible.
- Record backend choice, fallback reason, cache hit/miss and startup errors in diagnostics.

## Safety and compatibility boundaries

- iOS/iPadOS sandboxing, code-signing, executable-memory/JIT entitlements, memory budgets and available APIs constrain dynamic translation.
- A Windows kernel and kernel-mode anti-cheat cannot be replaced by user-mode CPU translation. Anti-cheat support requires publisher approval for the exact environment.
- Do not disable, bypass, spoof or tamper with anti-cheat.
- A planned composition is not a working runtime. Verify physical-device boot, process launch, graphics, input/audio, shutdown and persistence before claiming compatibility.

 
## Kenran Butō AOT execution subset

The translator is now connected to a versioned ARM64 guest-state ABI, a W^X executable-memory provider, a bounded executable-block cache and interpreter side exits. ABI details and field offsets are documented in [KENRAN_BUTO_AOT_ABI.md](KENRAN_BUTO_AOT_ABI.md).

Translator version 4 currently emits NOP, MOV register-immediate (32/64-bit), register-only MOV (32/64-bit), and bounded flag-preserving LEA forms (32/64-bit base/index/SIB addressing with supported signed displacements and no-base disp32 constants). ENDBR64, arithmetic, memory operations, branches, calls/returns, syscalls, SIMD, atomics, relocations and cross-block control flow remain interpreter fallbacks. The translated subset does not modify x86 arithmetic flags.

AOT is injected at the Linux ELF launch boundary. Generic GuestMachine instances remain interpreter-only unless an executor is explicitly supplied. The C invocation boundary rechecks JIT readiness for every block; unavailable or revoked JIT returns to the interpreter. The ARM64 workflow validates the ABI, register preservation, side-exit RIP, cache bounds and a static ELF hybrid run. This is a validated execution subset, not a general-purpose x86-64 backend or proof of physical-iPad compatibility.

## AOT decoder correctness contract

Translator version 4 enforces the x86-64 architectural 15-byte instruction limit across prefixes, opcode, ModRM and immediate. REX.B forms 41 90 and 49 90 are preserved for interpreter fallback because they encode XCHG rather than NOP. ENDBR64 is preserved for fallback until guest CET policy is represented. Guest-input, instruction-count and output-byte budgets stop only at instruction boundaries; unsupported and truncated instructions report the original guest offset.

The focused regression harness is scripts/tests/test_kenran_buto_aot_translator.swift. It checks AArch64 MOVZ/MOVK encodings, register moves, both REX.B exchange forms, legal 15-byte and rejected 16-byte instructions, multi-instruction blocks, hard budget clamps, input limits, ENDBR64 fallback, unsupported/truncated boundaries and output/instruction budgets. A separate allocation-contract test guards the borrowed input buffer, fixed four-word instruction buffer and single final Data copy.

## Kenran Butō executable AOT subset

The ARM64 executable-memory provider and Swift execution adapter now connect the bounded translator to the x86-64 interpreter. The launch path injects this adapter only for Linux ELF guests; generic GuestMachine users remain interpreter-only unless they explicitly inject an executor.

The current translated subset is deliberately narrow: NOP, MOV immediate-to-register, register-only MOV, and bounded flag-preserving LEA forms. ENDBR64, arithmetic, memory operations, control flow, syscalls and all other unsupported instructions side-exit to the interpreter at the exact guest RIP. No full Linux ABI or general x86-64 compatibility is implied.

The native ABI is versioned and size-checked. Guest registers are copied into the ARM64 call registers and written back on return. The executor validates state pointers, budgets, register state and exact byte accounting; failed native invocation restores the original registers. The C invocation boundary rechecks live JIT readiness before each block, so a revoked or unavailable JIT session falls back to interpretation.

Executable blocks use separate writable and executable mappings and are capped at 64 blocks / 16 MiB of page-rounded executable memory. The translation cache identity includes ABI and resource budgets, and cached artifacts are compared with a canonical translation before reuse. The translator uses bounded input/output budgets and a fixed four-word instruction emission buffer.

The dedicated ARM64 workflow now has ABI, memory-callback, side-exit, differential interpreter, cache-limit and static-ELF hybrid tests. These are hosted validation gates only. Physical iPad execution, JIT entitlement behavior, app signing, graphics/input, persistent guest state and repeat-launch cleanup still require device verification.

## Process-lifetime QEMU and VNC frame ownership

QEMU's native library remains a process-global, one-shot initialization. The application now owns one shared QEMUNativeRuntime for the process lifetime and does not call the native shutdown path when a user stops a guest. The command line uses -no-shutdown and a private AF_UNIX QMP socket at FileManager.default.temporaryDirectory/q.sock (app-container sandbox). The bridge accepts only stop, cont, system_reset and query-status commands. Stopping a VM pauses the guest; launching the same configuration resumes it with `cont` without resetting RAM. Explicit reset uses `system_reset`. Each successful start or resume receives a generation lease, and only the current lease can stop or reset the guest. A different VM configuration is rejected with an app-restart diagnostic rather than attempting unsafe qemu_init re-entry. Disk and firmware security scopes remain held while the QEMU process is alive.

VNC frames carry the QEMUVNCClient session generation from the locked framebuffer snapshot through VirtIOGPU and the Metal backend. Session replacement invalidates pending uploads, pending full-frame snapshots and published framebuffer slots. The Metal draw path rechecks both session and framebuffer generations immediately before command-buffer presentation, so work queued by an old VNC connection cannot replace the new session's frame.

The QMP and frame-generation source tests verify these lifecycle contracts. They do not replace physical iPad testing of QEMU initialization, QMP socket availability, JIT policy, guest boot, display and input, repeat launches or persistent guest state.
