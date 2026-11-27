#!/usr/bin/env python3
"""Create a metadata-only license/dependency review bundle for a UTM QEMU runtime."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

LICENSE_NAME = re.compile(
    r"^(?:LICENSE|COPYING|NOTICE|COPYRIGHT|PATENTS|AUTHORS|THIRD_PARTY_NOTICES)(?:[._-].*)?$",
    re.IGNORECASE,
)
SPDX = re.compile(r"SPDX-License-Identifier:\s*([^*/\r\n]+)")
SOURCE_SUFFIXES = {
    ".c", ".h", ".cc", ".hh", ".cpp", ".hpp", ".cxx", ".m", ".mm",
    ".swift", ".py", ".sh", ".bash", ".cmake", ".meson", ".mk", ".in",
    ".txt", ".md", ".yml", ".yaml", ".json", ".xml", ".S", ".s",
}
SKIP_DIRS = {
    ".git", ".svn", ".hg", "node_modules", "__pycache__", "DerivedData",
    "utm_build", "CMakeFiles", "meson-private", "meson-logs", "meson-info",
}
PACKAGE_REPORTS = (
    "BUILD-INFO.txt",
    "dependency-report.txt",
    "runtime-file-inventory.txt",
    "QEMU-SOURCE-URL.txt",
    "UTM-SOURCE-REVISION.txt",
    "QEMU/runtime-mode-manifest.txt",
    "QEMU/JIT/runtime-library-path.txt",
    "QEMU/JIT/exports.txt",
    "QEMU/TCI/runtime-library-path.txt",
    "QEMU/TCI/exports.txt",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_inventory(root: Path) -> tuple[list[str], dict[str, list[str]]]:
    license_files: list[str] = []
    spdx_files: dict[str, list[str]] = defaultdict(list)
    if not root.is_dir():
        return license_files, spdx_files

    for current, dirnames, filenames in os.walk(root):
        current_path = Path(current)
        dirnames[:] = [
            name for name in dirnames
            if name not in SKIP_DIRS
            and not name.endswith(".xcarchive")
            and not name.startswith("sysroot-")
        ]
        for filename in filenames:
            path = current_path / filename
            relative = path.relative_to(root).as_posix()
            if LICENSE_NAME.match(filename):
                license_files.append(relative)
            if path.suffix not in SOURCE_SUFFIXES:
                continue
            try:
                if path.stat().st_size > 1024 * 1024:
                    continue
                with path.open("r", encoding="utf-8", errors="replace") as stream:
                    for _ in range(80):
                        line = stream.readline()
                        if not line:
                            break
                        match = SPDX.search(line)
                        if match:
                            expression = match.group(1).strip().strip("*/# ")
                            if expression:
                                spdx_files[expression].append(relative)
            except OSError:
                continue
    return sorted(set(license_files)), dict(spdx_files)


def framework_inventory(package_root: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    frameworks_root = package_root / "Frameworks"
    if not frameworks_root.is_dir():
        return results
    for framework in sorted(frameworks_root.rglob("*.framework")):
        if not framework.is_dir():
            continue
        info_candidates = [
            framework / "Info.plist",
            framework / "Resources" / "Info.plist",
            framework / "Versions" / "Current" / "Resources" / "Info.plist",
        ]
        info: dict[str, Any] = {}
        for candidate in info_candidates:
            if candidate.is_file():
                try:
                    with candidate.open("rb") as stream:
                        loaded = plistlib.load(stream)
                    if isinstance(loaded, dict):
                        info = loaded
                    break
                except Exception:
                    pass
        executable = info.get("CFBundleExecutable")
        binary_candidates: list[Path] = []
        if isinstance(executable, str) and executable:
            binary_candidates.extend([
                framework / executable,
                framework / "Versions" / "Current" / executable,
            ])
        binary = next((candidate for candidate in binary_candidates if candidate.is_file()), None)
        item: dict[str, Any] = {
            "path": framework.relative_to(package_root).as_posix(),
            "bundle_identifier": info.get("CFBundleIdentifier"),
            "executable": executable,
        }
        if binary:
            item["binary_path"] = binary.relative_to(package_root).as_posix()
            item["binary_size"] = binary.stat().st_size
            item["binary_sha256"] = sha256_file(binary)
        else:
            item["binary_path"] = None
        results.append(item)
    return results


def runtime_library_inventory(package_root: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for path in sorted(package_root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in {".dylib", ".a"}:
            continue
        results.append({
            "path": path.relative_to(package_root).as_posix(),
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        })
    return results


def package_file_inventory(package_root: Path) -> list[dict[str, Any]]:
    """Hash every packaged file without following symlinks outside the package.

    Categories are path/extension heuristics for reviewer triage only; they
    never assert that a file's licence has been identified.
    """
    results: list[dict[str, Any]] = []
    provenance_names = {name.lower() for name in PACKAGE_REPORTS}
    firmware_suffixes = {".fd", ".rom", ".efi", ".dtb", ".qcow2", ".img", ".bin"}
    firmware_directories = {"firmware", "bios", "keymaps", "ovmf", "edk2"}
    for path in sorted(package_root.rglob("*")):
        relative = path.relative_to(package_root).as_posix()
        if path.is_symlink():
            results.append({"path": relative, "category": "symlink", "target": os.readlink(path)})
            continue
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        parts = {part.lower() for part in path.parts}
        if parts & firmware_directories or suffix in firmware_suffixes:
            category = "firmware-data"
        elif suffix in {".dylib", ".a"}:
            category = "runtime-library"
        elif any(part.lower().endswith(".framework") for part in path.parts):
            category = "framework-resource"
        elif LICENSE_NAME.match(path.name):
            category = "license-or-notice"
        elif path.name.lower() in provenance_names:
            category = "build-provenance"
        else:
            category = "other"
        results.append({
            "path": relative,
            "category": category,
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        })
    return results


def build_report(utm_root: Path, package_root: Path, output_dir: Path) -> dict[str, Any]:
    utm_root = utm_root.resolve()
    package_root = package_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == package_root or package_root in output_dir.parents:
        raise ValueError("output directory must not be inside the runtime package")
    if output_dir == utm_root or utm_root in output_dir.parents:
        raise ValueError("output directory must not be inside the UTM source tree")

    output_dir.mkdir(parents=True, exist_ok=True)
    license_files, spdx_files = source_inventory(utm_root)
    spdx_counts = Counter({key: len(value) for key, value in spdx_files.items()})
    frameworks = framework_inventory(package_root)
    runtime_libraries = runtime_library_inventory(package_root)
    package_files = package_file_inventory(package_root)
    package_file_category_counts = Counter(item["category"] for item in package_files)

    copied_reports: list[str] = []
    for name in PACKAGE_REPORTS:
        source = package_root / name
        if source.is_file():
            destination = output_dir / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            copied_reports.append(name)

    (output_dir / "license-files.txt").write_text(
        "\n".join(license_files) + ("\n" if license_files else ""),
        encoding="utf-8",
    )
    (output_dir / "spdx-summary.txt").write_text(
        "\n".join(f"{count:6d}  {expression}" for expression, count in sorted(spdx_counts.items()))
        + ("\n" if spdx_counts else "No SPDX identifiers found in scanned source headers.\n"),
        encoding="utf-8",
    )

    manifest: dict[str, Any] = {
        "utm_source": utm_root.name,
        "runtime_package": package_root.name,
        "license_file_count": len(license_files),
        "license_files": license_files,
        "spdx_expression_counts": dict(sorted(spdx_counts.items())),
        "spdx_files": {key: sorted(value) for key, value in sorted(spdx_files.items())},
        "framework_count": len(frameworks),
        "frameworks": frameworks,
        "runtime_library_count": len(runtime_libraries),
        "runtime_libraries": runtime_libraries,
        "package_file_count": len(package_files),
        "package_file_category_counts": dict(sorted(package_file_category_counts.items())),
        "package_files": package_files,
        "copied_package_reports": copied_reports,
        "review_status": "INVENTORY_ONLY_REQUIRES_QUALIFIED_LICENSE_REVIEW",
    }
    (output_dir / "license-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    qemu_url_path = package_root / "QEMU-SOURCE-URL.txt"
    utm_revision_path = package_root / "UTM-SOURCE-REVISION.txt"
    qemu_url = qemu_url_path.read_text(encoding="utf-8").strip() if qemu_url_path.is_file() else "not recorded"
    utm_revision = utm_revision_path.read_text(encoding="utf-8").strip() if utm_revision_path.is_file() else "not recorded"
    lines = [
        "# QEMU iOS runtime license and dependency inventory",
        "",
        "**Status: INVENTORY ONLY — NOT A LEGAL OPINION OR REDISTRIBUTION APPROVAL.**",
        "",
        f"- UTM source revision: {utm_revision}",
        f"- QEMU source URL: {qemu_url}",
        f"- License/copyright files found: {len(license_files)}",
        f"- Distinct SPDX expressions found in scanned source headers: {len(spdx_counts)}",
        f"- Packaged frameworks inventoried: {len(frameworks)}",
        f"- Packaged dylib/static libraries inventoried: {len(runtime_libraries)}",
        f"- Complete package files hashed: {len(package_files)}",
        f"- Firmware/data candidates hashed: {package_file_category_counts.get('firmware-data', 0)}",
        f"- Package reports copied: {', '.join(copied_reports) if copied_reports else 'none'}",
        "",
        "## SPDX expression counts",
        "",
    ]
    if spdx_counts:
        lines.extend(f"- {expression} — {count} source files" for expression, count in sorted(spdx_counts.items()))
    else:
        lines.append("- No SPDX headers were found in the scanned source headers; this does not mean the files are unlicensed.")
    lines.extend(["", "## Packaged frameworks", ""])
    if frameworks:
        lines.extend(
            f"- {item['path']} — bundle {item.get('bundle_identifier') or 'unknown'}, executable {item.get('executable') or 'unknown'}, binary SHA-256 {item.get('binary_sha256') or 'not found'}"
            for item in frameworks
        )
    else:
        lines.append("- No framework directories were found in the package.")
    lines.extend(["", "## Runtime libraries", ""])
    if runtime_libraries:
        lines.extend(f"- {item['path']} — {item['size']} bytes, SHA-256 {item['sha256']}" for item in runtime_libraries)
    else:
        lines.append("- No dylib or static-library files were found.")
    lines.extend(["", "## Complete package file inventory", ""])
    if package_files:
        lines.extend(
            f"- [{item['category']}] {item['path']} — "
            + (f"{item['size']} bytes, SHA-256 {item['sha256']}" if "sha256" in item else f"symlink target {item['target']} (not followed)")
            for item in package_files
        )
    else:
        lines.append("- No regular files or symlinks were found in the runtime package.")
    lines.extend([
        "",
        "## Review notes",
        "",
        "- dependency-report.txt records Mach-O linked libraries and LC_RPATH entries for the packaged runtime and framework tree.",
        "- runtime-file-inventory.txt, BUILD-INFO.txt, QEMU-SOURCE-URL.txt and UTM-SOURCE-REVISION.txt preserve build provenance.",
        "- license-files.txt inventories license/copyright files under the pinned UTM checkout and downloaded dependency source trees.",
        "- spdx-summary.txt counts SPDX identifiers found in the first 80 lines of scanned source files. Missing SPDX headers are not evidence of public-domain or permissive licensing.",
        "- The report does not determine which optional components are linked or dynamically loaded at runtime; compare the dependency report, QEMU configure flags and actual feature use.",
        "- A qualified reviewer must inspect exact linked source files, bundled frameworks, static/dynamic linkage, notices and redistribution obligations before enabling the binary artifact gate.",
        "- The QEMU runtime IPA/framework upload gate remains unchanged and must not be bypassed.",
        "",
    ])
    (output_dir / "license-review.md").write_text("\n".join(lines), encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--utm-source", required=True, type=Path)
    parser.add_argument("--runtime-package", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if not args.utm_source.is_dir():
        parser.error(f"UTM source directory does not exist: {args.utm_source}")
    if not args.runtime_package.is_dir():
        parser.error(f"runtime package directory does not exist: {args.runtime_package}")
    manifest = build_report(args.utm_source, args.runtime_package, args.output_dir)
    print(f"License inventory generated: {args.output_dir}")
    print(f"License files: {manifest['license_file_count']}; SPDX expressions: {len(manifest['spdx_expression_counts'])}; frameworks: {manifest['framework_count']}")
    print("This is inventory only; it does not approve redistribution.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
