#!/usr/bin/env python3
"""Patch QEMU's iOS feature and emulator-specific link configuration before configure."""
from pathlib import Path
import sys


def patch_source(source: str, runtime_path: str) -> str:
    old_probe = "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))"
    new_probe = "config_host_data.set('CONFIG_POSIX_MEMALIGN', true)"
    if new_probe not in source:
        if old_probe not in source:
            raise SystemExit("QEMU meson.build changed: POSIX_MEMALIGN feature probe not found")
        source = source.replace(old_probe, new_probe, 1)

    if not runtime_path or "\n" in runtime_path or "\r" in runtime_path:
        raise SystemExit("A valid IOS_COMPILER_RT path is required")
    meson_path = runtime_path.replace("\\", "\\\\").replace("'", "\\'")
    marker = "emulator_link_args += ['-Wl,-force_load," + meson_path + "']"
    anchor = "emulator_link_args = []"

    lines = source.splitlines()
    existing = [
        index for index, line in enumerate(lines)
        if line.strip().startswith("emulator_link_args += ['-Wl,-force_load,")
    ]
    if existing:
        first = existing[0]
        lines[first] = marker
        for index in reversed(existing[1:]):
            del lines[index]
        source = "\n".join(lines) + ("\n" if source.endswith("\n") else "")
    else:
        if anchor not in source:
            raise SystemExit("QEMU meson.build changed: emulator_link_args declaration not found")
        source = source.replace(
            anchor,
            anchor + "\n"
            "# i-Steam iOS: put compiler-rt on the actual emulator library link edge.\n"
            + marker,
            1
        )

    if new_probe not in source or marker not in source:
        raise SystemExit("QEMU meson.build patch verification failed")
    if "add_project_link_arguments('-Wl,-force_load,'" in source:
        raise SystemExit("Obsolete project-level compiler-runtime patch remains")
    return source


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_meson_ios.py /path/to/qemu/meson.build")
    runtime = Path(__import__("os").environ.get("IOS_COMPILER_RT", ""))
    if not runtime.is_file():
        raise SystemExit("IOS_COMPILER_RT must point to an existing libclang_rt.ios.a")
    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    patched = patch_source(source, str(runtime))
    path.write_text(patched, encoding="utf-8")
    print(f"Patched QEMU emulator link arguments for iOS compiler runtime: {runtime}")


if __name__ == "__main__":
    main()
