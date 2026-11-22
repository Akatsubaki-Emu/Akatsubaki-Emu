#!/usr/bin/env python3
"""Export QEMU's graceful-shutdown ABI for the no-JIT iOS TCI runtime only."""
from pathlib import Path
import sys

BASE_REQUIRED = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
SHUTDOWN_EXPORT = "qemu_system_shutdown_request;"
JIT_CALLBACK_EXPORT = "isteam_qemu_set_jit_callbacks;"


def patch_exported_symbols(source: str) -> str:
    lines = source.splitlines()
    missing = [symbol for symbol in BASE_REQUIRED if not any(line.strip() == symbol for line in lines)]
    if missing:
        raise SystemExit("QEMU TCI export list is missing lifecycle exports: " + ", ".join(missing))
    if any(line.strip() == JIT_CALLBACK_EXPORT for line in lines):
        raise SystemExit("QEMU TCI export list unexpectedly contains the StikDebug JIT callback")
    shutdown_count = sum(1 for line in lines if line.strip() == SHUTDOWN_EXPORT)
    if shutdown_count > 1:
        raise SystemExit("QEMU TCI export list contains a duplicate graceful-shutdown export")
    closing = [index for index, line in enumerate(lines) if line.strip() == "};"]
    if len(closing) != 1:
        raise SystemExit("QEMU TCI export list changed: expected exactly one closing '};' line")
    if shutdown_count == 0:
        lines.insert(closing[0], "  " + SHUTDOWN_EXPORT)
    patched = "\n".join(lines) + ("\n" if source.endswith("\n") else "")
    for symbol in (*BASE_REQUIRED, SHUTDOWN_EXPORT):
        if sum(1 for line in patched.splitlines() if line.strip() == symbol) != 1:
            raise SystemExit("QEMU TCI export verification failed: " + symbol)
    if any(line.strip() == JIT_CALLBACK_EXPORT for line in patched.splitlines()):
        raise SystemExit("QEMU TCI export verification found a forbidden JIT callback")
    return patched


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_tci_ios.py /path/to/qemu/system/qemu.symbols")
    path = Path(sys.argv[1])
    if not path.is_file():
        raise SystemExit(f"QEMU TCI export list is missing: {path}")
    source = path.read_text(encoding="utf-8")
    patched = patch_exported_symbols(source)
    if patched != source:
        path.write_text(patched, encoding="utf-8")
    print("Verified the no-JIT TCI lifecycle and graceful-shutdown exports without adding StikDebug callbacks.")


if __name__ == "__main__":
    main()
