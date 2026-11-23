#!/usr/bin/env python3
"""Prepare QEMU's no-JIT TCI export list for Akatsubaki's runtime bridge."""
from pathlib import Path
import sys

REQUIRED_EXPORTS = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
SHUTDOWN_EXPORT = "qemu_system_shutdown_request;"
JIT_CALLBACK_EXPORT = "isteam_qemu_set_jit_callbacks;"


def patch_exported_symbols(source: str) -> str:
    lines = source.splitlines()
    for symbol in REQUIRED_EXPORTS:
        count = sum(1 for line in lines if line.strip() == symbol)
        if count != 1:
            raise SystemExit(
                f"QEMU system/qemu.symbols must contain exactly one {symbol!r} entry; found {count}"
            )

    closing = [index for index, line in enumerate(lines) if line.strip() == "};"]
    if len(closing) != 1:
        raise SystemExit("QEMU system/qemu.symbols must contain exactly one closing '};' line")

    shutdown_count = sum(1 for line in lines if line.strip() == SHUTDOWN_EXPORT)
    jit_count = sum(1 for line in lines if line.strip() == JIT_CALLBACK_EXPORT)
    if shutdown_count > 1:
        raise SystemExit("QEMU system/qemu.symbols contains duplicate shutdown exports")
    if jit_count > 1:
        raise SystemExit("QEMU system/qemu.symbols contains duplicate StikJIT callback exports")

    # TCI has no executable-memory callback. Remove one left by a reused source tree,
    # while retaining the common QEMU lifecycle and graceful-shutdown exports.
    lines = [line for line in lines if line.strip() != JIT_CALLBACK_EXPORT]
    if shutdown_count == 0:
        closing_index = next(index for index, line in enumerate(lines) if line.strip() == "};")
        lines.insert(closing_index, "  " + SHUTDOWN_EXPORT)

    if sum(1 for line in lines if line.strip() == SHUTDOWN_EXPORT) != 1:
        raise SystemExit("QEMU TCI shutdown export verification failed")
    if any(line.strip() == JIT_CALLBACK_EXPORT for line in lines):
        raise SystemExit("QEMU TCI export list still contains the StikJIT callback")
    if any(sum(1 for line in lines if line.strip() == symbol) != 1 for symbol in REQUIRED_EXPORTS):
        raise SystemExit("QEMU TCI lifecycle export verification failed")

    return "\n".join(lines) + ("\n" if source.endswith("\n") else "")


def patch_file(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"QEMU export list is missing: {path}")
    source = path.read_text(encoding="utf-8")
    patched = patch_exported_symbols(source)
    if patched != source:
        path.write_text(patched, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_tci_exports.py /path/to/qemu/system/qemu.symbols")
    patch_file(Path(sys.argv[1]))
    print("Prepared QEMU TCI lifecycle exports; removed the StikJIT callback export.")


if __name__ == "__main__":
    main()
