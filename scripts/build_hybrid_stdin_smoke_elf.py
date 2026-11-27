#!/usr/bin/env python3
"""Build a static x86-64 Linux ELF that blocks in read(0), echoes console input and exits."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

BASE = 0x401000
DATA = 0x402000
PAGE = 0x1000
READY_OFFSET = 0x200
PREFIX_OFFSET = 0x220
DONE_OFFSET = 0x240
READ_RESULT_OFFSET = 0x10
WRITE_RESULT_OFFSET = 0x18
BUFFER_WORD_OFFSET = 0x20
DATA_FILE_SIZE = BUFFER_WORD_OFFSET + 8
READY = b"KENRAN_BUTO_STDIN_READY\n"
PREFIX = b"KENRAN_BUTO_STDIN_ECHO:"
DONE = b"KENRAN_BUTO_STDIN_OK\n"
EXPECTED = READY + PREFIX + b"hello\n" + DONE


def mov_imm32(opcode: int, value: int) -> bytes:
    return bytes((opcode,)) + struct.pack("<I", value)


def lea_rsi_rip(code: bytearray, target: int) -> None:
    code.extend(b"\x48\x8D\x35\x00\x00\x00\x00")
    displacement_offset = len(code) - 4
    next_instruction = BASE + len(code)
    struct.pack_into("<i", code, displacement_offset, target - next_instruction)

def store_rax_rip(code: bytearray, target: int) -> None:
    code.extend(b"\x48\x89\x05\x00\x00\x00\x00")
    displacement_offset = len(code) - 4
    next_instruction = BASE + len(code)
    struct.pack_into("<i", code, displacement_offset, target - next_instruction)


def build_code() -> bytes:
    code = bytearray()
    code += mov_imm32(0xB8, 1)
    code += mov_imm32(0xBF, 1)
    lea_rsi_rip(code, BASE + READY_OFFSET)
    code += mov_imm32(0xBA, len(READY))
    code += b"\x0F\x05"
    code += b"\x31\xC0"
    code += b"\x31\xFF"
    code += b"\x48\x8D\x74\x24\x80"
    code += mov_imm32(0xBA, 128)
    code += b"\x0F\x05"
    store_rax_rip(code, DATA + READ_RESULT_OFFSET)
    code += b"\x48\x89\xC3"
    code += b"\x48\x8B\x44\x24\x80"
    store_rax_rip(code, DATA + BUFFER_WORD_OFFSET)
    code += mov_imm32(0xB8, 1)
    code += mov_imm32(0xBF, 1)
    lea_rsi_rip(code, BASE + PREFIX_OFFSET)
    code += mov_imm32(0xBA, len(PREFIX))
    code += b"\x0F\x05"
    code += mov_imm32(0xB8, 1)
    code += mov_imm32(0xBF, 1)
    code += b"\x48\x8D\x74\x24\x80"
    code += b"\x48\x89\xDA"
    code += b"\x0F\x05"
    store_rax_rip(code, DATA + WRITE_RESULT_OFFSET)
    code += mov_imm32(0xB8, 1)
    code += mov_imm32(0xBF, 1)
    lea_rsi_rip(code, BASE + DONE_OFFSET)
    code += mov_imm32(0xBA, len(DONE))
    code += b"\x0F\x05"
    code += mov_imm32(0xB8, 60)
    code += b"\x31\xFF"
    code += b"\x0F\x05"
    return bytes(code)


def build_elf() -> bytes:
    code = build_code()
    if len(code) >= READY_OFFSET:
        raise ValueError("text segment code overlaps the read-ready string")
    text = bytearray(PAGE)
    text[:len(code)] = code
    text[READY_OFFSET:READY_OFFSET + len(READY)] = READY
    text[PREFIX_OFFSET:PREFIX_OFFSET + len(PREFIX)] = PREFIX
    text[DONE_OFFSET:DONE_OFFSET + len(DONE)] = DONE
    ident = b"\x7fELF" + bytes((2, 1, 1, 0, 0)) + bytes(7)
    ehdr = struct.pack("<16sHHIQQQIHHHHHH", ident, 2, 62, 1, BASE, 64, 0, 0, 64, 56, 2, 64, 0, 0)
    phdr_rx = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 2 * PAGE, 2 * PAGE, PAGE)
    phdr_rw = struct.pack("<IIQQQQQQ", 1, 6, 2 * PAGE, DATA, DATA, DATA_FILE_SIZE, PAGE, PAGE)
    header = ehdr + phdr_rx + phdr_rw
    image = bytearray(PAGE)
    image[:len(header)] = header
    image += text
    image += bytes(DATA_FILE_SIZE)
    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="hybrid_stdin_smoke.elf")
    args = parser.parse_args()
    output = Path(args.output)
    image = build_elf()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    output.chmod(0o755)
    print(f"wrote {output} ({len(image)} bytes)")
    print("expected interactive output: " + EXPECTED.decode().replace("\n", "\\n"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
