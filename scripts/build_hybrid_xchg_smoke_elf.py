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
    jne_offsets = []
    code.extend(bytes.fromhex("b8 01 00 00 00"))  # mov eax, 1
    code.extend(bytes.fromhex("b9 00 00 00 00"))  # mov ecx, 0
    code.extend(bytes.fromhex("91"))              # xchg eax, ecx (32-bit)
    code.extend(bytes.fromhex("83 f8 00"))        # cmp eax, 0
    jne_offsets.append(len(code))
    code.extend(bytes.fromhex("75 00"))           # jne fail

    code.extend(bytes.fromhex("49 b9 00 00 00 00 00 00 00 00"))  # mov r9, 0
    code.extend(bytes.fromhex("b8 01 00 00 00"))  # mov eax, 1
    code.extend(bytes.fromhex("49 91"))           # xchg rax, r9 (64-bit)
    code.extend(bytes.fromhex("83 f8 00"))        # cmp eax, 0
    jne_offsets.append(len(code))
    code.extend(bytes.fromhex("75 00"))           # jne fail

    code.extend(bytes.fromhex("bf 01 00 00 00"))  # mov edi, 1
    lea_offset = len(code)
    code.extend(bytes.fromhex("48 8d 35 00 00 00 00"))  # lea rsi, [rip+disp32]
    code.extend(bytes.fromhex("ba 06 00 00 00"))  # mov edx, 6
    code.extend(bytes.fromhex("b8 01 00 00 00"))  # mov eax, 1 (write)
    code.extend(bytes.fromhex("0f 05"))           # syscall: write
    code.extend(bytes.fromhex("b8 3c 00 00 00"))  # mov eax, 60
    code.extend(bytes.fromhex("31 ff"))           # xor edi, edi
    code.extend(bytes.fromhex("0f 05"))           # syscall: exit 0

    fail_offset = len(code)
    code.extend(bytes.fromhex("b8 3c 00 00 00"))  # mov eax, 60
    code.extend(bytes.fromhex("bf 01 00 00 00"))  # mov edi, 1
    code.extend(bytes.fromhex("0f 05"))           # syscall: exit 1

    message = b"hello\n"
    message_offset = len(code)
    for offset in jne_offsets:
        struct.pack_into("<b", code, offset + 1, fail_offset - (offset + 2))
    struct.pack_into("<i", code, lea_offset + 3, message_offset - (lea_offset + 7))
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
