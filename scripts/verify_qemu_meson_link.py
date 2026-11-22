#!/usr/bin/env python3
"""Fail early if UTM's QEMU target drops iOS linker inputs or required bridge exports."""
from pathlib import Path
import sys

TARGET = "libqemu-x86_64-softmmu.dylib"
EXPORT_LIST_ARGUMENT = "-Wl,-exported_symbols_list,system/qemu-ld64.symbols"
REQUIRED_EXPORTS = (
    "_qemu_init",
    "_qemu_main_loop",
    "_qemu_cleanup",
    "_qemu_system_shutdown_request",
    "_isteam_qemu_set_jit_callbacks",
)


def verify_link(ninja_text: str, runtime_path: str, export_symbols_text: str) -> None:
    lines = ninja_text.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith(f"build {TARGET}:")]
    if len(starts) != 1:
        raise SystemExit(f"expected exactly one Ninja link edge for {TARGET}, found {len(starts)}")

    edge_lines = [lines[starts[0]]]
    for line in lines[starts[0] + 1:]:
        if line.startswith(("build ", "rule ", "default ")):
            break
        edge_lines.append(line)
    edge = "\n".join(edge_lines)

    if "LINK_ARGS =" not in edge:
        raise SystemExit("QEMU Ninja target has no explicit LINK_ARGS entry to validate")
    if "-Wl,-objc_stubs_fast" not in edge:
        raise SystemExit("QEMU link edge is missing Objective-C message-stub generation")
    if "-lobjc" not in edge:
        raise SystemExit("QEMU link edge is missing the Objective-C runtime")
    if f"-Wl,-force_load,{runtime_path}" not in edge:
        raise SystemExit("emulator-specific link arguments are missing the exact iOS compiler-runtime force-load")
    if EXPORT_LIST_ARGUMENT not in edge:
        raise SystemExit("QEMU link edge is missing its generated exported-symbol list")

    export_lines = [line.strip() for line in export_symbols_text.splitlines()]
    invalid_exports = [symbol for symbol in REQUIRED_EXPORTS if export_lines.count(symbol) != 1]
    if invalid_exports:
        raise SystemExit(
            "generated QEMU exported-symbol list is missing or duplicates required bridge exports: "
            + ", ".join(invalid_exports)
        )

    print(
        f"Verified {TARGET} Objective-C/runtime/compiler-rt link inputs and "
        "all five QEMU runtime exports."
    )


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_qemu_meson_link.py <build.ninja> <libclang_rt.ios.a>")

    ninja_path = Path(sys.argv[1])
    runtime_path = Path(sys.argv[2])
    if not ninja_path.is_file():
        raise SystemExit(f"QEMU Ninja build file not found: {ninja_path}")
    if not runtime_path.is_file():
        raise SystemExit(f"iOS compiler runtime archive not found: {runtime_path}")

    export_symbols_path = ninja_path.parent / "system" / "qemu-ld64.symbols"
    if not export_symbols_path.is_file():
        raise SystemExit(f"generated QEMU exported-symbol list not found: {export_symbols_path}")

    verify_link(
        ninja_path.read_text(encoding="utf-8"),
        str(runtime_path),
        export_symbols_path.read_text(encoding="utf-8"),
    )


if __name__ == "__main__":
    main()
