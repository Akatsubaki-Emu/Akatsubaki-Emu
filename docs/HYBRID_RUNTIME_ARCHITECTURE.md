# Kenran Butō (絢爛舞踏) — Hybrid runtime composition

- **System name:** Kenran Butō (絢爛舞踏).
- **Status:** a bounded hybrid execution path is integrated for static x86-64 Linux ELF diagnostics: AOT translation/cache, a JIT-gated ARM64 block executor, a guest-register ABI, bounded dispatch, and interpreter side exits. The supported AOT subset is NOP/MOV only and physical iOS execution remains unverified. Full Windows/Linux userspace stacks are not integrated.
- **Component naming:** Kenran Butō AOT translates and dispatches a bounded static x86-64 → ARM64 instruction subset; Kenran Butō Cache stores revalidated translated-code artifacts; Kenran Butō Router selects backends and fallbacks; Kenran Butō Runtime orchestrates execution; Kenran Butō Graphics owns graphics translation. These names do not imply full guest compatibility.
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

## What is actually integrated today

- **Translation cache:** stores versioned artifacts with guest-code SHA-256, guest architecture, translator identity/version, host architecture, CPU features, guest ABI and instruction budget in the cache identity. Artifacts are integrity-checked, written atomically, and bounded. `KenranButoAOTCompiler` re-decodes cache hits and compares the complete translation before executable use; malformed, forged or mismatched artifacts are invalidated. The runtime block cache is separately keyed by exact guest bytes and bounded to 64 blocks.
- **Windows PE:** `WindowsPEImage` performs bounded metadata inspection; `WindowsPELoader` is read-only inspection. No PE image mapping, executable memory, import resolver or Windows process execution engine is integrated.
- **Static AOT execution:** `X86_64AOTTranslator` supports NOP, MOV immediate and register-only MOV, and stops at the first unsupported instruction with an exact fallback offset. REX.B forms of opcode 0x90 (XCHG) and ENDBR64 side-exit until their semantics/CET policy are explicitly represented. The decoder enforces the 15-byte x86 instruction limit and hard budgets. `KenranButoAOTExecutor` emits bounded ARM64 blocks into W^X executable memory; the interpreter dispatches at most 16 guest instructions per batch, stages register updates, and commits only validated block boundaries. Invalid or unsupported blocks fall back to the interpreter at the original RIP. Executable memory is available only when the JIT coordinator confirms a supported session; otherwise the interpreter remains the no-JIT path. Exact-byte cache keys prevent stale code reuse after self-modifying guest code.
- **FEXCore:** not integrated or packaged.
- **Box64:** a C/Swift bridge can look for an already-loaded Box64 entry point. It does not bundle Box64, provide a Linux rootfs/syscall ABI, or prove game execution.
- **Wine/Proton:** not integrated.
- **QEMU:** `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI library and asks the native bridge to load it with `RTLD_NOW`. Both modes require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`; only JIT mode requires `isteam_qemu_set_jit_callbacks`. The bridge matches the pinned UTM QEMU 10.0.12 lifecycle ABI: `void qemu_init(int, char **)`, `int qemu_main_loop(void)`, and `void qemu_cleanup(int status)`; cleanup receives the exact main-loop status and host-UI shutdown uses cause 5. `RuntimeCapabilityRegistry` records a loadable library as `loadable`, not `operational`, so it cannot yet make QEMU selectable in the planner. The bridge is deliberately one-shot per app process because QEMU global-state reinitialization is not proven safe. The JIT profile uses native TCG code generation and split-WX executable memory; the TCI profile uses UTM's threaded TCG interpreter and does not require executable-memory JIT. The dual-runtime workflow now uses upstream UTM's `iOS-SE` scheme and `UTM SE.app` product for TCI. The StikDebug allocator patch is gated to `ios` JIT builds, the TCI package rejects the JIT callback, the merger checks shared framework contents, and release validation checks both variants inside the final IPA. `.automatic` selects JIT only when a supported JIT session is ready; otherwise it selects the packaged TCI interpreter. These source/CI guards are implemented but the macOS archive build and physical iPad guest boot remain unverified. On physical iOS 26+, the host queries `IODeviceTree:/chosen/memory-map` through IOKit and classifies the JIT protocol as UNKNOWN, STANDARD, or STIKDEBUG/TXM. Unknown or malformed registry data blocks JIT launch and allocation, but must not block a validated no-JIT TCI path. STANDARD devices retain QEMU's normal split-WX allocator; confirmed TXM devices use the exported callback ABI. Launch Setup and `QEMUNativeRuntime` perform JIT readiness checks only for the JIT profile; TCI bypasses JIT readiness. Simulator, tvOS and visionOS skip the physical-iOS JIT path. QEMU remains full-system only, not a PE process translator. A successful dual-runtime build, physical guest boot, firmware compatibility, display/input, graceful stop and persistence remain unverified.
- **Linux ELF startup:** `GameLauncher` first asks `RuntimeBackendRouter` for the explicitly subset-validated interpreter route before starting `LinuxELFRuntime`, which owns a `GuestMachine` and runs bounded interpreter batches with cooperative stop. The capability registry labels this interpreter `validatedSubset`, not `operational`, and deliberately leaves the full `linuxSyscallABI` layer unavailable; the router permits only the bounded diagnostic subset and keeps general Linux execution false. `ELF64Loader` maps static ET_EXEC and self-contained ET_DYN PIE images, verifies program-header mapping, and applies bounded R_X86_64_RELATIVE relocations. `LinuxProcessStackBuilder` creates an aligned initial stack with argv, envp, AT_PHDR/AT_PHENT/AT_PHNUM, AT_ENTRY, AT_RANDOM and AT_EXECFN. PT_INTERP, DT_NEEDED dependencies, non-relative relocations, ELF PT_TLS initialization and a complete syscall ABI remain unsupported. Static PIE support is limited to self-contained images using R_X86_64_RELATIVE relocations; it is not a dynamic linker. The interpreter now handles ARCH_SET_FS/GS and ARCH_GET_FS/GS plus FS/GS-based memory operands; this is segment-base support, not a complete ELF TLS loader. The interpreter's syscall shim currently covers stdout/stderr write and bounded writev, stdin EOF, brk, anonymous mmap/munmap, mprotect/madvise validation, clock_gettime/gettimeofday, getrandom, process identity, and a small single-thread subset; it does not provide a guest filesystem, dynamic loader, ELF TLS initialization or full signal/thread semantics. A synthetic static ELF smoke test exercises the complete supported path from ELF loading and initial stack setup through x86-64 execution, Linux write and exit. The iOS game library now exposes imported entries and routes console launches through `GameLauncher`; this does not make dynamic ELF binaries, general Linux applications or commercial games compatible.
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

 
## Kenran Butō AOT translator bring-up

`src/Runtime/X86_64AOTTranslator.swift` provides bounded x86-64 to AArch64 block translation for NOP, MOV register-immediate (32/64-bit), and register-only MOV (32/64-bit). These operations do not modify x86 arithmetic flags. ENDBR64 is not emitted: it side-exits to the interpreter until an explicit guest CET policy exists. The translator hard-caps work at 4,096 guest instructions, 1 MiB of emitted AArch64 code and 65,536 guest input bytes (caller-supplied larger budgets are clamped). If an input budget ends mid-instruction, it returns `inputLimit` at that instruction's start; genuinely truncated guest code remains `truncatedInstruction`. It rejects both REX.B `0x41 0x90` and `0x49 0x90` XCHG forms rather than miscompiling them as NOP, and stops at the first unsupported/truncated instruction with a precise guest-byte fallback offset.

`KenranButoAOTCompiler` validates and caches serialized translation artifacts using guest-code SHA-256, guest ABI plus instruction budget, translator version, AArch64 target and CPU feature identity. Cache hits are re-decoded from the guest bytes and compared byte-for-byte before the executable block can be used.

**This is a bounded executable AOT subset, not a general x86 runtime.** The guest-register array ABI, executable-memory provider, block dispatcher, exact-byte cache key and interpreter side exits are integrated. Arithmetic/flags, memory operands, branches, calls/returns, SIMD, atomics, relocations and cross-block control flow remain unsupported; Linux syscalls continue through the interpreter. The path must not be called operational until differential tests and physical-iOS JIT execution are verified.

## AOT decoder correctness contract

The current conservative translator is a bounded bring-up subset, not an executable backend. Translator version 3 enforces the x86-64 architectural 15-byte instruction limit across the entire instruction (prefixes, opcode, ModRM and immediate), not just the prefix run. REX.B forms `41 90` and `49 90` are preserved for interpreter fallback because they encode XCHG rather than NOP. ENDBR64 is also preserved for fallback until the guest CET policy is represented. Guest-input, instruction-count and output-byte budgets stop only at instruction boundaries; an input budget that cuts through an instruction returns `inputLimit` at that instruction's start rather than misclassifying the guest binary as truncated. Unsupported and genuinely truncated instructions report the original guest offset.

The focused regression harness is `scripts/tests/test_kenran_buto_aot_translator.swift`. It checks AArch64 MOVZ/MOVK encodings, register moves, both REX.B exchange forms, legal 15-byte and rejected 16-byte instructions, input limits, ENDBR64 fallback, unsupported/truncated boundaries, and output/instruction budgets. `.github/workflows/validate-kenran-buto-aot.yml` compiles and runs both the decoder harness and translation-cache integration harness on macOS.

These changes cover decoder safety, bounded executable blocks, staged guest-register updates and interpreter fallback. Flags are deliberately untouched because the translated NOP/MOV subset does not modify them. The remaining validation gap is execution on a physical iOS device with supported JIT readiness, plus differential testing against the interpreter. Do not mark `.staticAOT` operational until that evidence exists.
