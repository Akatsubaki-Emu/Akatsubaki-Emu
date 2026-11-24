#!/usr/bin/env python3
"""Build a static x86-64 ELF that exercises Kenran Butō's hybrid smoke path."""
from __future__ import annotations
import argparse
import struct
from pathlib import Path

ELF_BASE = 0x400000
CODE_OFFSET = 0x1000
ENTRY_POINT = ELF_BASE + CODE_OFFSET
PAGE_SIZE = 0x1000


def build_elf() -> bytes:
    code = bytearray()
    labels: dict[str, int] = {}
    fixups: list[tuple[int, str]] = []

    def emit(instructions: str) -> None:
        code.extend(bytes.fromhex(instructions))

    def jne(label: str) -> None:
        emit("0f 85")
        fixups.append((len(code), label))
        code.extend(bytes(4))

    # 32-bit accumulator XCHG: eax=1, ecx=0 -> eax=0, ecx=1.
    emit("b8 01 00 00 00")
    emit("b9 00 00 00 00")
    emit("91")
    emit("83 f8 00")
    jne("fail")
    emit("83 f9 01")
    jne("fail")

    # 64-bit accumulator XCHG: rax=1, r9=0 -> rax=0, r9=1.
    emit("49 b9 00 00 00 00 00 00 00 00")
    emit("b8 01 00 00 00")
    emit("49 91")
    emit("48 83 f8 00")
    jne("fail")
    emit("49 83 f9 01")
    jne("fail")

    # 32-bit register-only ModRM XCHG: r8d=0, r9d=1 -> r8d=1, r9d=0.
    emit("41 b8 00 00 00 00")
    emit("41 b9 01 00 00 00")
    emit("45 87 c8")
    emit("41 83 f8 01")
    jne("fail")
    emit("41 83 f9 00")
    jne("fail")

    # 64-bit register-only ModRM XCHG: r10=0, r11=1 -> r10=1, r11=0.
    emit("49 ba 00 00 00 00 00 00 00 00")
    emit("49 bb 01 00 00 00 00 00 00 00")
    emit("4d 87 da")
    emit("49 83 fa 01")
    jne("fail")
    emit("49 83 fb 00")
    jne("fail")

    # Success: write hello and exit(0).
    emit("bf 01 00 00 00")
    lea_offset = len(code)
    emit("48 8d 35 00 00 00 00")
    emit("ba 06 00 00 00")
    emit("b8 01 00 00 00")
    emit("0f 05")
    emit("b8 3c 00 00 00")
    emit("31 ff")
    emit("0f 05")

    # Any failed compare reaches exit(1).
    labels["fail"] = len(code)
    emit("b8 3c 00 00 00")
    emit("bf 01 00 00 00")
    emit("0f 05")

    message = b"hello\n"
    message_offset = len(code)
    struct.pack_into("<i", code, lea_offset + 3, message_offset - (lea_offset + 7))
    for displacement_offset, label in fixups:
        struct.pack_into("<i", code, displacement_offset, labels[label] - (displacement_offset + 4))
    code.extend(message)

    ident = b"\x7fELF" + bytes((2, 1, 1, 0)) + bytes(8)
    header = struct.pack("<16sHHIQQQIHHHHHH", ident, 2, 62, 1,
                         ENTRY_POINT, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    total_size = CODE_OFFSET + len(code)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, ELF_BASE, ELF_BASE,
                       total_size, total_size, PAGE_SIZE)
    padding_length = CODE_OFFSET - len(header) - len(phdr)
    if padding_length < 0:
        raise RuntimeError("ELF headers exceed the code offset.")
    return header + phdr + bytes(padding_length) + bytes(code)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    image = build_elf()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    args.output.chmod(0o755)
    print(f"Created static x86-64 ELF: {args.output} ({len(image)} bytes)")


if __name__ == "__main__":
    main()
