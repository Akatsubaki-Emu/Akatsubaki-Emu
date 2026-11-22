# Kenran Butō (絢爛舞踏) — Hybrid runtime composition

- **System name:** Kenran Butō (絢爛舞踏).
- **Status:** composable execution-policy prototype; the translation-cache artifact layer and a bounded x86-64 to AArch64 AOT translation/cache bring-up are implemented, alongside a limited static Linux process-entry stack. A limited executable AOT fast path now cooperates with the diagnostic interpreter; a general Windows/Linux userspace stack is not integrated.
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

- **Translation cache:** stores versioned artifacts with guest-code SHA-256, guest architecture/ABI, translator version, host architecture and CPU-feature identity. Artifacts are atomically written, integrity-checked, bounded and invalidated when corrupt. `KenranButoAOTCompiler` revalidates cache hits against canonical translation; `KenranButoAOTExecutor` consumes supported artifacts through a separate bounded W^X executable-block cache and dispatches them with interpreter side exits. The persistent artifact cache itself does not allocate executable memory.
- **Windows PE:** `WindowsPEImage` performs bounded metadata inspection; `WindowsPELoader` is read-only inspection. No PE image mapping, executable memory, import resolver, AOT translator or Windows process execution engine is integrated.
- **Static AOT:** `X86_64AOTTranslator` emits a deliberately small NOP/MOV register-only subset and stops at the first unsupported instruction with an exact fallback offset. ABI v1, W^X executable memory, a bounded block dispatcher and interpreter side exits are now integrated. This is a tested-in-CI bring-up path, not a complete decoder/IR/code generator/relinker or general x86-64 backend.
- **FEXCore:** not integrated or packaged.
- **Box64:** a C/Swift bridge can look for an already-loaded Box64 entry point. It does not bundle Box64, provide a Linux rootfs/syscall ABI, or prove game execution.
- **Wine/Proton:** not integrated.
- **QEMU:** `QEMURuntimeStatus.inspect(requiresJIT:)` selects the JIT or TCI library and asks the native bridge to load it with `RTLD_NOW`. Both modes require `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`; only JIT mode requires `isteam_qemu_set_jit_callbacks`. `RuntimeCapabilityRegistry` records a loadable library as `loadable`, not `operational`, so it cannot yet make QEMU selectable in the planner. The bridge is deliberately one-shot per app process because QEMU global-state reinitialization is not proven safe. The JIT profile uses native TCG code generation with a 128 MiB split-WX translation buffer. The TCI profile uses UTM's threaded TCG interpreter, selects `-accel tcg`, and does not require executable-memory JIT. The runtime workflow now builds the `iOS` and `iOS-TCI` archives and packages both under `QEMU/JIT` and `QEMU/TCI`; this source integration is committed, but a successful hosted dual-runtime build and physical guest boot remain unverified. On physical iOS 26+, the host queries `IODeviceTree:/chosen/memory-map` through IOKit and classifies the JIT protocol as UNKNOWN, STANDARD, or STIKDEBUG/TXM, matching StikJIT's query. Empty, malformed, inaccessible, or missing registry data blocks JIT launch and JIT allocation, but does not block the no-JIT TCI path. STANDARD devices retain QEMU's normal split-WX allocator; confirmed TXM devices use the exported `isteam_qemu_set_jit_callbacks` ABI to obtain the RX region, remap its RW alias, and detach the debugger. Launch Setup rejects unknown protocol modes and waits for `CS_DEBUGGED` only when the JIT profile is selected; TCI bypasses JIT readiness. `QEMUNativeRuntime` repeats the readiness check before JIT startup. Simulator, tvOS and visionOS skip the physical-iOS JIT request path. QEMU remains full-system only, not a PE process translator. Guest boot, firmware compatibility, device-level graceful stop, display/input and persistence remain unverified.
- **Linux ELF startup:** `GameLauncher` first asks `RuntimeBackendRouter` for the explicitly subset-validated interpreter route before starting `LinuxELFRuntime`, which owns a `GuestMachine` and runs bounded interpreter batches with cooperative stop. The capability registry labels this interpreter `validatedSubset`, not `operational`, and deliberately leaves the full `linuxSyscallABI` layer unavailable; the router permits only the bounded diagnostic subset and keeps general Linux execution false. `ELF64Loader` maps static ET_EXEC and self-contained ET_DYN PIE images, verifies program-header mapping, and applies bounded R_X86_64_RELATIVE relocations. `LinuxProcessStackBuilder` creates an aligned initial stack with argv, envp, AT_PHDR/AT_PHENT/AT_PHNUM, AT_ENTRY, AT_RANDOM and AT_EXECFN. PT_INTERP, DT_NEEDED dependencies, non-relative relocations, ELF PT_TLS initialization and a complete syscall ABI remain unsupported. Static PIE support is limited to self-contained images using R_X86_64_RELATIVE relocations; it is not a dynamic linker. The interpreter supports ARCH_SET_FS/GS and ARCH_GET_FS/GS plus FS/GS-based memory operands, not complete ELF TLS. Its syscall shim covers stdout/stderr write and bounded writev, stdin EOF, brk, anonymous mmap/munmap, mprotect/madvise validation, clock_gettime/gettimeofday, getrandom, process identity, and a small single-thread subset; it has no guest filesystem, dynamic loader or full signal/thread semantics. A synthetic static ELF smoke test now exercises ELF loading, initial stack setup, x86-64 execution, Linux write/exit and at least one native AOT block on ARM64 CI. The iOS game library exposes imported entries and routes console launches through `GameLauncher`; this does not make dynamic ELF binaries, general Linux applications or commercial games compatible.
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

`src/Runtime/X86_64AOTTranslator.swift` provides bounded x86-64 to AArch64 block translation for NOP, MOV register-immediate (32/64-bit), and register-only MOV (32/64-bit). These operations do not modify x86 arithmetic flags. ENDBR64 is preserved for interpreter fallback until guest CET policy is represented. The translator enforces instruction, output and guest-input budgets, rejects the REX.B `0x90` XCHG form rather than miscompiling it as NOP, and stops at the first unsupported/truncated instruction with a precise guest-byte fallback offset.

`KenranButoAOTCompiler` validates and caches serialized translation artifacts using guest-code SHA-256, guest ABI, translator version, AArch64 target and CPU feature identity. Cache hits are revalidated against the original guest bytes.

ABI v1 now provides the guest-register context, W^X executable-memory provider, bounded block dispatcher and exact interpreter side exits. The executor commits a private register snapshot only after validating the returned ABI and RIP. Targeted invalidation on guest writes, arithmetic/flags, memory operands, branches, calls/returns, SIMD, atomics, relocations and cross-block control flow remain incomplete; do not advertise `.staticAOT` as a general operational backend. Physical iOS/TXM execution is still unverified.

## AOT decoder correctness contract

Translator version 3 is a bounded bring-up subset consumed by the executable adapter. It enforces the architectural 15-byte instruction limit across prefixes, opcode, ModRM and immediates; preserves REX.B forms `41 90` and `49 90` for XCHG fallback; preserves ENDBR64 for fallback until guest CET policy is represented; and stops at instruction boundaries for guest-input, instruction-count and output-byte budgets.

The focused decoder regression harness is `scripts/tests/test_kenran_buto_aot_translator.swift`. It checks AArch64 encodings, REX.B XCHG fallback, the architectural 15-byte limit, ENDBR64 fallback, input/instruction/output budgets and unsupported/truncated boundaries. The ARM64 AOT workflow additionally executes the ABI/interpreter tests and a static ELF guest that must emit its known output after executing at least one native AOT block.

This paragraph describes the translator-only stage before ABI v1 integration. The runtime now has a bounded register-only AOT fast path, executable-memory management and interpreter side exits. It is not a general-purpose backend, and real guest workloads must remain on validated interpreter/QEMU routes until differential and physical-device tests pass.


## Kenran Butō executable AOT integration — ABI v1

The interpreter now has an optional ARM64 AOT fast path. A versioned guest-state
ABI carries the x86-64 GPR array, RIP/RFLAGS, FS/GS bases, an instruction budget,
and explicit bounded GuestMemory callbacks. The adapter executes a translated
register-only block, validates the returned ABI and exact side-exit RIP, and only
then commits a temporary register snapshot to the interpreter. Invalid blocks
fall back without mutating live interpreter registers.

Executable code is W^X. Physical iOS standard-JIT mode uses a Darwin `vm_remap`
split-W^X pair (RW write alias and RX execute alias); StikDebug/TXM mode obtains
its RX mapping through the prepare-region protocol and remaps a separate RW alias.
The provider records the allocation type and releases both mappings through the
matching Mach or `munmap` API. The macOS ARM64 validation path seals a single
mapping RX before invocation. The
executor cache is bounded by both 64 blocks and 16 MiB of page-rounded executable
memory. Persistent cache hits are re-decoded and compared against canonical
translation output. Generated entries begin with a BTI C landing-pad hint.

The interpreter fetch window is 64 bytes for block translation, while the x86
decoder continues to enforce the architectural 15-byte maximum for each guest
instruction. The current AOT instruction set remains deliberately small:
NOP and register-only MOV immediate/register forms. Arithmetic, memory operands,
branches, calls, SIMD, atomics, relocations and general cross-block control flow
still side-exit to the interpreter. This is an integrated bring-up fast path, not
a general-purpose x86-64 translator or proof of game compatibility.

The native AOT workflow must run on ARM64 and execute generated AArch64 blocks;
a skipped native execution test is not accepted as a pass. Physical iPad execution,
StikDebug/TXM entitlement success, ELF page permissions, full Linux ABI, QEMU TCI
boot, graphics/input and persistent guest-state acceptance tests remain separate
requirements.
