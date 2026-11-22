# Kenran Butō AOT execution ABI v1

## Guest-state contract

`KenranButoAOTGuestState` is defined in `iSteam/JIT26Protocol.h`. It is 96 bytes
on 64-bit targets; the GPR pointer is at byte offset 8, enforced by a C static
assert. It carries ABI version/size, 16 guest GPRs, RIP/RFLAGS, FS/GS bases, a
versioned memory-callback table, instruction budget/count, and side-exit metadata.

A generated block receives the state pointer in AArch64 x0. The wrapper preserves
it in x17 and loads the GPR-array pointer into x16. Guest registers map to x0-x15;
x16/x17 are wrapper scratch registers.

## Memory callbacks and side exits

The callback table routes reads and writes through `GuestMemory`, preserving bounds
checks. The C helpers record explicit memory-fault reasons, the faulting address and
current guest RIP. Future memory-op lowering must set the current instruction RIP
before invoking a callback and branch to the interpreter on failure.

Current translated instructions are limited to NOP and register-only MOV, so
callbacks are tested by the ABI harness but are not yet emitted by the translator.
Unsupported instructions resume at `blockStartRIP + guestBytesConsumed`.

## Exit reasons

| Value | Meaning |
|---:|---|
| 0 | No exit recorded |
| 1 | Unsupported instruction |
| 2 | Truncated instruction |
| 3 | Input limit |
| 4 | Instruction limit |
| 5 | Output limit |
| 6 | End of input |
| 7 | Guest memory read fault |
| 8 | Guest memory write fault |
| 9 | Invalid state / ABI |

## Executable memory and cache safety

Standard JIT mode maps writable pages and seals them read/execute before invocation.
StikDebug/TXM mode uses an executable mapping plus a separate writable alias. Both
mappings are released on remap/protection failure. The executable block cache is
bounded to 64 entries and keyed by exact guest bytes, translator version, ABI and
instruction budget. Persistent translation artifacts are re-decoded and compared
with canonical output before a cache hit is trusted.

## Limits

ABI v1 is an interpreter fast path, not a complete x86-64 AOT backend. Unsupported
instructions always fall back. Physical iOS/TXM execution remains unverified until
tested on a real iOS ARM64 device.


## Runtime hardening follow-up

The interpreter now supplies AOT with a separate 4 KiB maximum input window,
clamped to the remainder of the current guest page. This is distinct from the
15-byte architectural x86 instruction decoder window and prevents a translated
block from reading across a page boundary. The translation cache identity includes
translator/ABI versions plus instruction, guest-byte and output-byte budgets.

Executable blocks begin with an AArch64 `BTI C` landing instruction. The runtime
revalidates the ABI, guest-state pointer, budget, exit RIP and exit reason after
native execution; malformed results restore the pre-call GPR snapshot and fall
back to interpretation. The in-memory executable-block cache is bounded by both
64 entries and 16 MiB of page-rounded executable mappings.

The focused native harness includes a 20-byte, four-instruction block to ensure
multi-instruction AOT dispatch is not accidentally constrained by the 15-byte
single-instruction decoder window. Native execution is required to run on an
ARM64 macOS runner; an x86_64 runner must fail rather than silently skip it.
