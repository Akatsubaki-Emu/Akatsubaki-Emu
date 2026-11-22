#!/usr/bin/env python3
"""Export QEMU shutdown for the no-JIT TCI build without enabling StikJIT callbacks."""
from __future__ import annotations

from pathlib import Path
import sys

LIFECYCLE_SYMBOLS = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
SHUTDOWN_SYMBOL = "qemu_system_shutdown_request;"
JIT_CALLBACK_SYMBOL = "isteam_qemu_set_jit_callbacks;"


def _symbol_name(line: str) -> str:
    value = line.strip()
    if value.startswith("_"):
        value = value[1:]
    return value


def patch_symbols(source: str) -> str:
    lines = source.splitlines()
    if not lines:
        raise ValueError("QEMU symbol list is empty.")
    if sum(1 for line in lines if line.strip() == "{") != 1:
        raise ValueError("QEMU symbol list must contain exactly one opening brace.")
    closing = [index for index, line in enumerate(lines) if line.strip() == "};"]
    if len(closing) != 1:
        raise ValueError("QEMU symbol list must contain exactly one closing brace.")

    for symbol in LIFECYCLE_SYMBOLS:
        count = sum(1 for line in lines if _symbol_name(line) == symbol)
        if count != 1:
            raise ValueError(f"TCI symbol list must contain exactly one {symbol}")

    if any(_symbol_name(line) == JIT_CALLBACK_SYMBOL for line in lines):
        raise ValueError("TCI must not export the JIT callback.")

    shutdown_count = sum(1 for line in lines if _symbol_name(line) == SHUTDOWN_SYMBOL)
    if shutdown_count > 1:
        raise ValueError("TCI symbol list contains duplicate qemu_system_shutdown_request exports.")
    if shutdown_count == 0:
        lines.insert(closing[0], f"  {SHUTDOWN_SYMBOL}")

    result = "\n".join(lines)
    return result + ("\n" if source.endswith("\n") else "")


def patch_file(path: Path) -> bool:
    if not path.is_file():
        raise ValueError(f"QEMU symbol list does not exist: {path}")
    original = path.read_text(encoding="utf-8")
    updated = patch_symbols(original)
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: patch_qemu_tci_ios.py <QEMU source>/system/qemu.symbols", file=sys.stderr)
        return 2
    try:
        changed = patch_file(Path(argv[1]))
    except (OSError, ValueError) as error:
        print(f"TCI symbol patch failed: {error}", file=sys.stderr)
        return 1
    print("TCI shutdown export patched." if changed else "TCI shutdown export already present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
