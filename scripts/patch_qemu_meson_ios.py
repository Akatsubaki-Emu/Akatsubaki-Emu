#!/usr/bin/env python3
"""Patch QEMU iOS features, Objective-C compilation, and emulator link configuration."""
from pathlib import Path
import re
import os
import sys

MARKER_COMMENT = "# i-Steam iOS: force-load Apple's compiler runtime into the emulator dylib."
LEGACY_MARKER_COMMENT = "# i-Steam iOS: put compiler-rt on the actual emulator library link edge."

OBJC_BLOCK_MARKER = "if 'objc' in all_languages"
OBJC_ARGUMENTS = {
    "objc.get_supported_arguments(warn_flags)": (
        "objc.get_supported_arguments(warn_flags + "
        "['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')"
    ),
    "objc.get_supported_arguments(qemu_common_flags + warn_flags)": (
        "objc.get_supported_arguments(qemu_common_flags + warn_flags + "
        "['-fno-objc-msgsend-class-selector-stubs'], checked: 'require')"
    ),
}


def _matching_conditional_end(source: str, block_start: int) -> int:
    """Find the matching endif for a Meson if block, including nested conditions."""
    depth = 0
    offset = 0
    for line in source.splitlines(keepends=True):
        if offset >= block_start:
            stripped = line.lstrip()
            if not stripped.startswith("#"):
                if re.match(r"if\b", stripped):
                    depth += 1
                elif re.match(r"endif\b", stripped):
                    depth -= 1
                    if depth == 0:
                        return offset
        offset += len(line)
    return -1


def patch_objc_compile_flag(source: str) -> str:
    # QEMU has multiple Objective-C conditionals. Select the one that contains
    # the compiler-argument call, not the later summary/reporting conditionals.
    starts = []
    offset = 0
    for line in source.splitlines(keepends=True):
        stripped = line.lstrip()
        if not stripped.startswith("#") and stripped.split("#", 1)[0].strip() == OBJC_BLOCK_MARKER:
            starts.append(offset)
        offset += len(line)

    if not starts:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler block not found")

    blocks = []
    for block_start in starts:
        block_end = _matching_conditional_end(source, block_start)
        if block_end < 0:
            raise SystemExit("QEMU meson.build changed: Objective-C compiler block is unterminated")
        blocks.append((block_start, block_end, source[block_start:block_end]))

    candidates = [
        item for item in blocks
        if any(anchor in item[2] for anchor in OBJC_ARGUMENTS)
        or any(form in item[2] for form in OBJC_ARGUMENTS.values())
    ]
    if not candidates:
        raise SystemExit(
            "QEMU meson.build changed: Objective-C compiler argument anchor not found in a compiler block"
        )
    if len(candidates) != 1:
        raise SystemExit(
            "QEMU meson.build changed: expected exactly one Objective-C compiler configuration block"
        )

    block_start, _block_end, block = candidates[0]
    patched_forms = [value for value in OBJC_ARGUMENTS.values() if value in block]
    patched_outside_block = [
        value for value in OBJC_ARGUMENTS.values()
        if source.count(value) != block.count(value)
    ]
    if patched_outside_block:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler flag is outside its compiler block")
    if patched_forms:
        if len(patched_forms) != 1 or block.count(patched_forms[0]) != 1:
            raise SystemExit("QEMU meson.build changed: duplicate Objective-C compiler flag patch")
        if any(anchor in block for anchor in OBJC_ARGUMENTS):
            raise SystemExit("QEMU meson.build changed: unpatched Objective-C compiler call remains")
        return source

    matches = [anchor for anchor in OBJC_ARGUMENTS if block.count(anchor) == 1]
    if len(matches) != 1 or any(block.count(anchor) for anchor in OBJC_ARGUMENTS if anchor not in matches):
        raise SystemExit("QEMU meson.build changed: Objective-C compiler argument anchor not found exactly once")
    anchor = matches[0]
    patched = OBJC_ARGUMENTS[anchor]
    position = block_start + block.find(anchor)
    return source[:position] + patched + source[position + len(anchor):]

def patch_source(source: str, runtime_path: str) -> str:
    old_probe = "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))"
    new_probe = "config_host_data.set('CONFIG_POSIX_MEMALIGN', true)"
    if new_probe not in source:
        if old_probe not in source:
            raise SystemExit("QEMU meson.build changed: POSIX_MEMALIGN feature probe not found")
        source = source.replace(old_probe, new_probe, 1)

    source = patch_objc_compile_flag(source)
    if not runtime_path or "\n" in runtime_path or "\r" in runtime_path:
        raise SystemExit("A valid IOS_COMPILER_RT path is required")
    meson_path = runtime_path.replace("\\", "\\\\").replace("'", "\\'")
    marker = "emulator_link_args += ['-Wl,-objc_stubs_fast', '-lobjc', '-Wl,-force_load," + meson_path + "']"
    anchor = "emulator_link_args = []"

    lines = source.splitlines()
    owned_comments = [i for i, line in enumerate(lines) if line.strip() == MARKER_COMMENT]
    owned_runtime_lines = [
        i for i, line in enumerate(lines)
        if line.strip().startswith("emulator_link_args += ")
        and "libclang_rt.ios.a" in line
    ]

    if owned_comments:
        first_comment = owned_comments[0]
        first_runtime = first_comment + 1
        if (first_runtime >= len(lines)
                or not lines[first_runtime].strip().startswith("emulator_link_args += ")
                or "libclang_rt.ios.a" not in lines[first_runtime]):
            raise SystemExit("QEMU meson.build changed: compiler-runtime marker is not followed by its link argument")
        output = []
        for index, line in enumerate(lines):
            if index == first_comment:
                output.extend((MARKER_COMMENT, marker))
            elif (index == first_runtime or index in owned_comments[1:] or index in owned_runtime_lines
                  or line.strip() == LEGACY_MARKER_COMMENT):
                continue
            else:
                output.append(line)
        lines = output
    elif owned_runtime_lines:
        first_runtime = owned_runtime_lines[0]
        output = []
        for index, line in enumerate(lines):
            if index == first_runtime:
                output.extend((MARKER_COMMENT, marker))
            elif index in owned_runtime_lines or line.strip() == LEGACY_MARKER_COMMENT:
                continue
            else:
                output.append(line)
        lines = output
    else:
        if anchor not in source:
            raise SystemExit("QEMU meson.build changed: emulator_link_args declaration not found")
        source = source.replace(anchor, anchor + "\n" + MARKER_COMMENT + "\n" + marker, 1)
        lines = source.splitlines()

    patched = "\n".join(lines) + ("\n" if source.endswith("\n") else "")
    if new_probe not in patched or marker not in patched:
        raise SystemExit("QEMU meson.build patch verification failed")
    if patch_objc_compile_flag(patched) != patched:
        raise SystemExit("QEMU meson.build patch verification failed: Objective-C compiler flag was not applied exactly once")
    if "add_project_link_arguments('-Wl,-force_load,'" in patched:
        raise SystemExit("Obsolete project-level compiler-runtime patch remains")
    return patched


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_meson_ios.py /path/to/qemu/meson.build")
    runtime = Path(os.environ.get("IOS_COMPILER_RT", ""))
    if not runtime.is_file():
        raise SystemExit("IOS_COMPILER_RT must point to an existing libclang_rt.ios.a")
    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    patched = patch_source(source, str(runtime))
    path.write_text(patched, encoding="utf-8")
    print(f"Patched QEMU Objective-C compiler flags and emulator link arguments: {runtime}")


if __name__ == "__main__":
    main()
