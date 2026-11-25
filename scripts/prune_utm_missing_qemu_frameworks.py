#!/usr/bin/env python3
"""Remove UTM Xcode references to QEMU targets absent from an iOS sysroot.

UTM's pinned iOS project can retain Embed Libraries entries for optional QEMU
architectures that its iOS dependency build does not produce. Xcode then fails
archive while copying those nonexistent framework bundles. This patch keeps
all built targets, but requires the x86_64 softmmu runtime used by Akatsubaki.
"""
from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path

FRAMEWORK_RE = re.compile(r"\b(qemu-[A-Za-z0-9_-]+-softmmu\.framework)\b")
UUID_RE = re.compile(r"\b[A-F0-9]{24}\b")
REQUIRED_FRAMEWORK = "qemu-x86_64-softmmu.framework"


def patch_project(source: str, frameworks_dir: Path) -> tuple[str, list[str]]:
    referenced = set(FRAMEWORK_RE.findall(source))
    if not referenced:
        raise ValueError("UTM project contains no QEMU softmmu framework references")

    present = {
        name for name in referenced
        if (frameworks_dir / name).is_dir()
    }
    if REQUIRED_FRAMEWORK not in present:
        raise ValueError(
            f"required x86_64 QEMU framework is missing from {frameworks_dir}"
        )

    missing = sorted(referenced - present)
    if not missing:
        return source, []

    missing_set = set(missing)
    removed_ids: set[str] = set()
    lines = source.splitlines(keepends=True)
    for line in lines:
        if missing_set.intersection(FRAMEWORK_RE.findall(line)):
            removed_ids.update(UUID_RE.findall(line))

    if not removed_ids:
        raise ValueError(
            "missing QEMU framework references were found, but no Xcode object IDs "
            "could be identified safely"
        )

    patched_lines: list[str] = []
    for line in lines:
        names = set(FRAMEWORK_RE.findall(line))
        if names.intersection(missing_set):
            continue
        if any(object_id in line for object_id in removed_ids):
            if names - missing_set:
                raise ValueError(
                    "an Xcode project line mixes missing and available QEMU framework references"
                )
            continue
        patched_lines.append(line)

    patched = "".join(patched_lines)
    remaining = sorted(name for name in missing if name in patched)
    if remaining:
        raise ValueError(f"failed to remove missing QEMU framework references: {remaining}")
    if REQUIRED_FRAMEWORK not in patched:
        raise ValueError("pruning unexpectedly removed the required x86_64 QEMU framework")
    if not FRAMEWORK_RE.search(patched):
        raise ValueError("pruning removed every QEMU softmmu framework reference")
    for object_id in removed_ids:
        if object_id in patched:
            raise ValueError(f"dangling Xcode object reference remains after pruning: {object_id}")

    return patched, missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="UTM.xcodeproj/project.pbxproj")
    parser.add_argument("frameworks_dir", type=Path, help="iOS sysroot Frameworks directory")
    args = parser.parse_args()

    if not args.project.is_file():
        parser.error(f"Xcode project file does not exist: {args.project}")
    if not args.frameworks_dir.is_dir():
        parser.error(f"QEMU Frameworks directory does not exist: {args.frameworks_dir}")

    original = args.project.read_text(encoding="utf-8")
    patched, removed = patch_project(original, args.frameworks_dir)
    if patched != original:
        mode = args.project.stat().st_mode
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=args.project.parent,
            prefix=f".{args.project.name}.", suffix=".tmp", delete=False,
        ) as temporary:
            temporary.write(patched)
            temporary_path = Path(temporary.name)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, args.project)

    if removed:
        print("Removed unavailable QEMU framework references: " + ", ".join(removed))
    else:
        print("All referenced QEMU softmmu frameworks exist in the selected iOS sysroot.")
    print(f"Retained required runtime framework: {REQUIRED_FRAMEWORK}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
