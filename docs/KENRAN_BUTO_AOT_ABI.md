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

Physical iOS standard-JIT mode uses Darwin split-W^X: an anonymous writable
mapping plus a separate `vm_remap` executable alias sealed RX. StikDebug/TXM
mode obtains its RX mapping through the prepare-region protocol and remaps a
separate writable alias. The provider tracks the allocation type and releases
both aliases with the matching `munmap` or `vm_deallocate` path. The macOS
ARM64 validation path uses a writable mapping sealed RX before invocation. The executable block cache is
bounded to 64 entries and keyed by exact guest bytes, translator version, ABI and
instruction budget. Persistent translation artifacts are re-decoded and compared
with canonical output before a cache hit is trusted.

## Limits

ABI v1 is an interpreter fast path, not a complete x86-64 AOT backend. Unsupported
instructions always fall back. Physical iOS/TXM execution remains unverified until
tested on a real iOS ARM64 device.
