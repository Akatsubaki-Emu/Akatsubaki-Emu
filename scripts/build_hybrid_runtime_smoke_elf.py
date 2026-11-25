#!/usr/bin/env python3
"""Build a static x86-64 Linux ELF that exercises uname, write and exit."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

BASE = 0x401000
DATA = 0x402000
MARKER = b"KENRAN_BUTO_RUNTIME_OK\n"
EXPECTED = b"Linuxx86_64" + MARKER
PAGE = 0x1000


def mov_imm32(opcode: int, value: int) -> bytes:
    return bytes((opcode,)) + struct.pack("<I", value)


def build_code() -> tuple[bytes, int]:
    code = bytearray()
    # uname(&utsname) -> 0. The writable buffer lives in a separate RW PT_LOAD.
    code += mov_imm32(0xBF, DATA)
    code += mov_imm32(0xB8, 63)
    code += b"\x0f\x05"

    # Write utsname.sysname (5 bytes) and utsname.machine (6 bytes).
    for address, length in ((DATA, 5), (DATA + 4 * 65, 6)):
        code += mov_imm32(0xB8, 1)
        code += mov_imm32(0xBF, 1)
        code += mov_imm32(0xBE, address)
        code += mov_imm32(0xBA, length)
        code += b"\x0f\x05"

    marker_address = BASE + 0x100
    code += mov_imm32(0xB8, 1)
    code += mov_imm32(0xBF, 1)
    code += mov_imm32(0xBE, marker_address)
    code += mov_imm32(0xBA, len(MARKER))
    code += b"\x0f\x05"

    code += mov_imm32(0xB8, 60)
    code += mov_imm32(0xBF, 0)
    code += b"\x0f\x05"
    return bytes(code), marker_address - BASE


def build_elf() -> bytes:
    code, marker_offset = build_code()
    if len(code) >= 0x100 or marker_offset + len(MARKER) > PAGE:
        raise ValueError("text segment overflow")

    text = bytearray(PAGE)
    text[: len(code)] = code
    text[marker_offset : marker_offset + len(MARKER)] = MARKER

    # ELF64 ET_EXEC, x86-64, page-aligned RX text and RW data/BSS PT_LOADs.
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        b"\x7fELF" + bytes((2, 1, 1, 0, 0)) + bytes(7),
        2, 62, 1, BASE, 64, 0, 0, 64, 56, 2, 64, 0, 0,
    )
    phdr_rx = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 2 * PAGE, 2 * PAGE, PAGE)
    phdr_rw = struct.pack("<IIQQQQQQ", 1, 6, 2 * PAGE, DATA, DATA, 1, PAGE, PAGE)
    header = ehdr + phdr_rx + phdr_rw
    if len(header) > PAGE:
        raise ValueError("ELF headers exceed first page")
    image = bytearray(PAGE)
    image[: len(header)] = header
    image += text
    image += b"\x00"
    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="hybrid_runtime_smoke.elf")
    args = parser.parse_args()
    output = Path(args.output)
    image = build_elf()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    output.chmod(0o755)
    print(f"wrote {output} ({len(image)} bytes)")
    print(f"expected stdout: {EXPECTED.decode().rstrip()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
