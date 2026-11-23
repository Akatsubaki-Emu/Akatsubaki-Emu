#!/usr/bin/env python3
"""Patch QEMU iOS features, Objective-C compilation, and emulator link configuration."""
from pathlib import Path
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


def _objc_conditional_blocks(source: str):
    """Return complete Objective-C conditional blocks without assuming there is only one."""
    lines = source.splitlines(keepends=True)
    blocks = []
    for start, line in enumerate(lines):
        if line.strip() != OBJC_BLOCK_MARKER:
            continue
        depth = 1
        end = start + 1
        while end < len(lines) and depth:
            token = lines[end].strip()
            if token.startswith("if "):
                depth += 1
            elif token == "endif":
                depth -= 1
            end += 1
        if depth:
            raise SystemExit("QEMU meson.build changed: Objective-C conditional block is unterminated")
        blocks.append((start, end, "".join(lines[start:end])))
    return lines, blocks


def patch_objc_compile_flag(source: str) -> str:
    lines, blocks = _objc_conditional_blocks(source)
    if not blocks:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler block not found exactly once")

    anchors = [anchor for anchor in OBJC_ARGUMENTS if source.count(anchor)]
    if len(anchors) > 1 or any(source.count(anchor) > 1 for anchor in OBJC_ARGUMENTS):
        raise SystemExit("QEMU meson.build changed: duplicate Objective-C compiler argument anchor")

    patched_forms = [form for form in OBJC_ARGUMENTS.values() if source.count(form)]
    if len(patched_forms) > 1 or any(source.count(form) > 1 for form in OBJC_ARGUMENTS.values()):
        raise SystemExit("QEMU meson.build changed: duplicate Objective-C compiler flag patch")

    target_blocks = [
        (start, end, block)
        for start, end, block in blocks
        if any(anchor in block for anchor in OBJC_ARGUMENTS)
        or any(form in block for form in OBJC_ARGUMENTS.values())
    ]
    if not target_blocks:
        if patched_forms:
            raise SystemExit("QEMU meson.build changed: Objective-C compiler flag is outside its compiler block")
        raise SystemExit("QEMU meson.build changed: Objective-C compiler argument anchor not found exactly once")
    if len(target_blocks) != 1:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler block not found exactly once")

    block_start, block_end, block = target_blocks[0]
    if patched_forms:
        patched = patched_forms[0]
        if block.count(patched) != 1:
            raise SystemExit("QEMU meson.build changed: Objective-C compiler flag is outside its compiler block")
        if anchors:
            raise SystemExit("QEMU meson.build changed: unpatched Objective-C compiler call remains")
        return source

    if len(anchors) != 1:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler argument anchor not found exactly once")
    anchor = anchors[0]
    if block.count(anchor) != 1:
        raise SystemExit("QEMU meson.build changed: Objective-C compiler argument anchor is outside its compiler block")

    patched = OBJC_ARGUMENTS[anchor]
    position = block_start
    block_offset = block.find(anchor)
    line_offset = sum(len(item) for item in lines[:block_start])
    insertion = line_offset + block_offset
    return source[:insertion] + patched + source[insertion + len(anchor):]


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
    if patched.count(OBJC_BLOCK_MARKER) != 1 or not any(value in patched for value in OBJC_ARGUMENTS.values()):
        raise SystemExit("QEMU meson.build patch verification failed: Objective-C compiler flag was not applied")
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
