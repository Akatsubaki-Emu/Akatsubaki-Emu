# Kenran Butō (絢爛舞踏) — Hybrid runtime composition

- **System name:** Kenran Butō (絢爛舞踏).
- **Status:** composable execution-policy prototype; the translation-cache artifact layer and a bounded x86-64 to AArch64 AOT translation/cache bring-up are implemented, alongside a limited static Linux process-entry stack. No executable AOT dispatcher or full Windows/Linux userspace stack is integrated.
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

## What is actually integrated today

- **Translation cache:** stores versioned translated-code artifacts using a cache identity that includes guest-code SHA-256, guest architecture, translator identity/version, host architecture, CPU features and guest ABI. Each artifact has an integrity digest, is written atomically, is rejected and removed if corrupt or mismatched, and is bounded to 8 MiB per code artifact, 512 entries and 256 MiB total. Cache entries can be explicitly invalidated. The cache stores validated translation artifacts. `KenranButoAOTExecutor` wraps supported blocks in a guest-register ABI, allocates bounded W^X memory through `iSteam/KenranButoAOTExecutableMemory.c`, and dispatches at most 16 guest instructions per batch. The interpreter stages register state and resumes at the exact side-exit offset. Executable memory is deliberately enabled only for a confirmed StikDebug/TXM session; standard iOS JIT and no-JIT devices remain on the interpreter path.
- **Windows PE:** `WindowsPEImage` performs bounded metadata inspection; `WindowsPELoader` is read-only inspection. No PE image mapping, import resolver, Wine/Proton compatibility layer or Windows process execution engine is integrated.
- **Static AOT:** `X86_64AOTTranslator` translates a deliberately small, flag-neutral subset (NOP, MOV immediate and register-only MOV) and stops at the first unsupported instruction with an exact fallback offset. `KenranButoAOTCompiler` validates and caches artifacts by guest hash, ABI, budget and translator version. `KenranButoAOTExecutor` wraps the translated prefix in a guest-register ABI and executes it through a bounded W^X block cache when the StikDebug/TXM executable-memory protocol is confirmed. The interpreter stages register state and falls back at the exact guest RIP. Standard iOS JIT and no-JIT devices use the interpreter. This is not a complete decoder/IR/code generator/relinker or a general x86 runtime; physical-device execution remains unverified.
- **FEXCore:** not integrated or packaged.
- **Box64:** a C/Swift bridge can look for an already-loaded Box64 entry point. It does not bundle Box64, provide a Linux rootfs/syscall ABI, or prove game execution.
- **Wine/Proton:** not integrated.
- **QEMU:** `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI library and asks the native bridge to load it with `RTLD_NOW`. Both modes require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`; only JIT mode requires `isteam_qemu_set_jit_callbacks`. `RuntimeCapabilityRegistry` records a loadable library as `loadable`, not `operational`, so it cannot yet make QEMU selectable in the planner. The bridge is deliberately one-shot per app process because QEMU global-state reinitialization is not proven safe. The JIT profile uses native TCG code generation with a 128 MiB split-WX translation buffer. The TCI profile uses UTM's threaded TCG interpreter, selects `-accel tcg`, and does not require executable-memory JIT. The runtime workflow now builds the `iOS` and `iOS-TCI` archives and packages both under `QEMU/JIT` and `QEMU/TCI`; this source integration is committed, but a successful hosted dual-runtime build and physical guest boot remain unverified. On physical iOS 26+, the host queries `IODeviceTree:/chosen/memory-map` through IOKit and classifies the JIT protocol as UNKNOWN, STANDARD, or STIKDEBUG/TXM, matching StikJIT's query. Empty, malformed, inaccessible, or missing registry data blocks JIT launch and JIT allocation, but does not block the no-JIT TCI path. STANDARD devices retain QEMU's normal split-WX allocator; confirmed TXM devices use the exported `isteam_qemu_set_jit_callbacks` ABI to obtain the RX region, remap its RW alias, and detach the debugger. Launch Setup rejects unknown protocol modes and waits for `CS_DEBUGGED` only when the JIT profile is selected; TCI bypasses JIT readiness. `QEMUNativeRuntime` repeats the readiness check before JIT startup. Simulator, tvOS and visionOS skip the physical-iOS JIT request path. QEMU remains full-system only, not a PE process translator. Guest boot, firmware compatibility, device-level graceful stop, display/input and persistence remain unverified.
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

`src/Runtime/X86_64AOTTranslator.swift` provides bounded x86-64 to AArch64 block translation for NOP, MOV register-immediate (32/64-bit), and register-only MOV (32/64-bit). These operations preserve x86 arithmetic flags. ENDBR64, REX.B XCHG, memory operands and all other unsupported instructions side-exit to the interpreter. Translator version 3 enforces the 15-byte x86 instruction limit and hard caps of 4,096 instructions, 1 MiB of output and 65,536 guest input bytes.

`KenranButoAOTCompiler` keys artifacts by guest-code SHA-256, ABI, instruction budget, translator version, AArch64 target and CPU features. Cache hits are re-decoded and compared byte-for-byte before use. `KenranButoAOTExecutor` wraps the translated prefix with a 16-register guest ABI, keeps a 64-block exact-byte cache, stages register state, and returns an exact guest-byte side-exit offset. `iSteam/KenranButoAOTExecutableMemory.c` provides bounded W^X memory; on physical iOS it currently fails closed unless the StikDebug/TXM protocol is confirmed. Standard split-WX and no-JIT devices retain the interpreter fallback.

**This is an integrated executable AOT subset, not a general x86 runtime.** Arithmetic/flags, memory operands, branches, calls/returns, SIMD, atomics, relocations and cross-block control flow remain unsupported and must side-exit. The translator and executor have host regression harnesses, but physical-iOS JIT execution and differential testing against a reference x86 CPU remain outstanding. Do not advertise `.staticAOT` as a general operational backend.

## AOT decoder correctness contract

Translator version 3 enforces the x86-64 architectural 15-byte instruction limit across prefixes, opcode, ModRM and immediates, plus hard guest-input, instruction-count and output-byte budgets. REX.B forms `41 90` and `49 90` are preserved for interpreter fallback because they encode XCHG rather than NOP. ENDBR64 is also preserved for fallback until guest CET policy is represented. The allocation hot path uses bounded buffer views instead of per-byte array materialisation.

The focused regression harnesses are `scripts/tests/test_kenran_buto_aot_translator.swift`, `scripts/tests/test_kenran_buto_aot_cache.swift`, `scripts/tests/test_kenran_buto_aot_execution.swift`, `scripts/tests/test_aot_translator_allocation_hot_path.py`, and the AOT dispatch additions in `scripts/tests/test_x86_64_interpreter.swift`. `.github/workflows/validate-kenran-buto-aot.yml` compiles and runs decoder, cache, interpreter side-exit, executable-memory and native ARM64 block tests on macOS.

The executable path is deliberately limited to the flag-neutral NOP/MOV subset. It does not implement arithmetic/flags, memory operands, branches, calls/returns, SIMD, atomics, relocations or cross-block control flow. Host tests do not prove iOS executable-memory entitlement compatibility or physical-device guest execution; keep `.staticAOT` unavailable as a general backend until differential correctness and on-device tests pass.
