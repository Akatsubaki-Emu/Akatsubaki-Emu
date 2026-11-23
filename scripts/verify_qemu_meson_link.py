#!/usr/bin/env python3
"""Verify Objective-C compilation and iOS compiler-rt on QEMU Meson edges."""
from pathlib import Path
import sys

OBJC_COMPILE_FLAG = "-fno-objc-msgsend-class-selector-stubs"
OBJC_TARGET_HINT = "spice-display-metal.m.o"


def edge_block(lines: list[str], start: int) -> str:
    block = [lines[start]]
    for line in lines[start + 1:]:
        if line and not line[0].isspace() and line.startswith(("build ", "rule ", "default ")):
            break
        block.append(line)
    return "\n".join(block)


def verify_objc_compile_edge(ninja_text: str) -> None:
    lines = ninja_text.splitlines()
    start = next((
        index for index, line in enumerate(lines)
        if line.startswith("build ") and ".m.o:" in line
        and "objc_COMPILER" in line and OBJC_TARGET_HINT in line
    ), None)
    if start is None:
        raise SystemExit(
            "QEMU build.ninja has no Metal Objective-C compile edge for spice-display-metal.m.o"
        )
    block = edge_block(lines, start)
    if OBJC_COMPILE_FLAG not in block:
        raise SystemExit(
            "QEMU Metal Objective-C compile edge is missing " + OBJC_COMPILE_FLAG
            + "; Meson did not propagate the class-selector-stub workaround to the failing source file"
        )


def verify_link(ninja_text: str, runtime_path: str, require_objc_compile: bool = False) -> None:
    if require_objc_compile:
        verify_objc_compile_edge(ninja_text)
    lines = ninja_text.splitlines()
    target_prefix = "build libqemu-x86_64-softmmu.dylib:"
    start = next((i for i, line in enumerate(lines) if line.startswith(target_prefix)), None)
    if start is None:
        raise SystemExit("QEMU build.ninja has no libqemu-x86_64-softmmu.dylib link target")

    link_edge = edge_block(lines, start)
    if "LINK_ARGS =" not in link_edge:
        raise SystemExit("QEMU Ninja target has no explicit LINK_ARGS entry to validate")
    if "-Wl,-objc_stubs_fast" not in link_edge:
        raise SystemExit("QEMU link configuration is missing Objective-C message-stub generation on the emulator link edge")
    if "-lobjc" not in link_edge:
        raise SystemExit("QEMU link configuration is missing the Objective-C runtime on the emulator link edge")
    expected = "-Wl,-force_load," + runtime_path
    if expected not in link_edge:
        raise SystemExit(
            "QEMU link configuration is missing Apple's iOS compiler runtime. "
            "The Meson emulator-specific link arguments did not reach "
            "libqemu-x86_64-softmmu.dylib; refusing to compile with a known-broken link."
        )


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_qemu_meson_link.py /path/to/build.ninja /path/to/libclang_rt.ios.a")
    ninja = Path(sys.argv[1])
    runtime = Path(sys.argv[2])
    if not ninja.is_file():
        raise SystemExit(f"QEMU Meson build file not found: {ninja}")
    if not runtime.is_file():
        raise SystemExit(f"Apple iOS compiler runtime not found: {runtime}")
    verify_link(ninja.read_text(encoding="utf-8"), str(runtime), require_objc_compile=True)
    print("Verified: QEMU's Metal Objective-C compile edge and x86_64 emulator link edge include the required Objective-C and iOS compiler-runtime flags.")


if __name__ == "__main__":
    main()
