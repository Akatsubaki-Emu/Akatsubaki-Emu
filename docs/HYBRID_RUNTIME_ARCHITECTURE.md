# Kenran Butō (絢爛舞踏) — Hybrid runtime composition

- **System name:** Kenran Butō (絢爛舞踏).
- **Status:** composable execution-policy prototype; the translation-cache artifact layer is implemented and a limited static Linux process-entry stack is now built, but no production translator or full Windows/Linux userspace stack is integrated.
- **Component naming:** Kenran Butō AOT is the planned static x86-64 → ARM64 translator; Kenran Butō Cache stores validated translated-code artifacts; Kenran Butō Router selects backends and fallback; Kenran Butō Runtime orchestrates execution; Kenran Butō Graphics owns graphics translation. These names do not imply that missing implementations are complete.
- **Planner:** `src/Runtime/ExecutionBackendRouter.swift`
- **Cache:** `src/Performance/TranslationCache.swift`
- **Launch entry point:** `src/Steam/GameLauncher.swift` → `src/Runtime/WindowsRuntime.swift`
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

- **Translation cache:** stores versioned translated-code artifacts using a cache identity that includes guest-code SHA-256, guest architecture, translator identity/version, host architecture, CPU features and guest ABI. Each artifact has an integrity digest, is written atomically, is rejected and removed if corrupt or mismatched, and is bounded to 8 MiB per code artifact, 512 entries and 256 MiB total. Cache entries can be explicitly invalidated. The cache returns bytes only; it does not allocate executable memory, invoke JIT, or execute code. No translator currently consumes or produces these artifacts.
- **Windows PE:** `WindowsPEImage` performs bounded metadata inspection; `WindowsPELoader` is read-only inspection. No PE image mapping, executable memory, import resolver, AOT translator or Windows process execution engine is integrated.
- **Static AOT:** no complete x86-64→ARM64 decoder, semantic IR, code generator or relinker is integrated.
- **FEXCore:** not integrated or packaged.
- **Box64:** a C/Swift bridge can look for an already-loaded Box64 entry point. It does not bundle Box64, provide a Linux rootfs/syscall ABI, or prove game execution.
- **Wine/Proton:** not integrated.
- **QEMU:** `QEMURuntimeStatus` asks the native bridge to `dlopen` the candidate with `RTLD_NOW` and resolve `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and `qemu_system_shutdown_request`. `RuntimeCapabilityRegistry` records this as `loadable`, not `operational`, so it cannot yet make QEMU selectable in the planner. The bridge is deliberately one-shot per app process because QEMU global-state reinitialization is not proven safe. Guest boot, firmware compatibility, device-level graceful stop, display/input and persistence remain unverified. QEMU remains full-system only, not a PE process translator.
- **Linux ELF startup:** `ELF64Loader` maps fixed-address static ET_EXEC segments and verifies that the program-header table is mapped. `LinuxProcessStackBuilder` creates an aligned initial stack with argv, envp, AT_PHDR/AT_PHENT/AT_PHNUM, AT_ENTRY, AT_RANDOM and AT_EXECFN. PIE, PT_INTERP, dynamic linking, TLS and a complete syscall ABI remain unsupported. The interpreter's syscall shim currently covers stdout/stderr write, stdin EOF, brk, anonymous mmap/munmap, mprotect/madvise validation, clock_gettime/gettimeofday, getrandom, process identity, and a small single-thread subset; it does not provide a guest filesystem, dynamic loader, TLS or full signal/thread semantics.
- **Interpreter:** diagnostic x86-64 subset with 32/64-bit register moves, register and 32/64-bit memory forms of MOV/LEA/ADD/SUB/CMP/AND/OR/XOR, ModRM/SIB base-index-scale and RIP-relative addressing, sign-extended immediate arithmetic, condition flags (CF/PF/AF/ZF/SF/OF), and selected short/near conditional branches, plus sign-extended C7 immediates, LEAVE/RET-imm16 and indirect CALL/JMP/PUSH. Other memory widths and addressing prefixes, SIMD, atomics, exceptions, paging, and most Linux syscalls remain unsupported; this is not a general game backend.
- **a32rt:** not integrated.
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
