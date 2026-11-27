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
import shlex
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


def resolve_inside_root(path: Path, root: Path) -> Path | None:
    """Resolve a path only when its target remains inside the declared root."""
    try:
        resolved_root = root.resolve(strict=True)
        resolved_path = path.resolve(strict=True)
        resolved_path.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError):
        return None
    return resolved_path


def spdx_expression_for_file(path: Path) -> str | None:
    """Return the first SPDX expression in a source file's leading header."""
    try:
        if path.stat().st_size > 1024 * 1024:
            return None
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            for _ in range(80):
                line = stream.readline()
                if not line:
                    break
                match = SPDX.search(line)
                if match:
                    expression = match.group(1).strip().strip("*/# ")
                    if expression:
                        return expression
    except OSError:
        return None
    return None


def qemu_source_root_inventory(root: Path) -> list[dict[str, Any]]:
    """Record QEMU source roots and the default stated by each root LICENSE."""
    root = root.resolve()
    results: list[dict[str, Any]] = []
    for candidate in sorted(root.glob("build-*/qemu-*")):
        resolved_root = resolve_inside_root(candidate, root)
        if resolved_root is None or not resolved_root.is_dir():
            continue
        license_path = resolve_inside_root(resolved_root / "LICENSE", root)
        license_text = ""
        license_relative = None
        license_hash = None
        if license_path is not None and license_path.is_file():
            license_relative = license_path.relative_to(root).as_posix()
            license_hash = sha256_file(license_path)
            try:
                license_text = license_path.read_text(encoding="utf-8", errors="replace").lower()
            except OSError:
                license_text = ""
        unannotated_default = None
        if (
            "source files with no licensing information" in license_text
            and "or (at your option) any later version" in license_text
        ):
            unannotated_default = "GPL-2.0-or-later"
        restricted_paths: list[str] = []
        if (
            "only accepted for the following files or directories" in license_text
            and all(path in license_text for path in ("bsd-user/", "linux-user/", "hw/vfio/", "hw/xen/xen_pt*"))
        ):
            restricted_paths = ["bsd-user/", "linux-user/", "hw/vfio/", "hw/xen/xen_pt*"]
        results.append({
            "path": resolved_root.relative_to(root).as_posix(),
            "license_file": license_relative,
            "license_sha256": license_hash,
            "unannotated_source_default": unannotated_default,
            "gpl2_only_contribution_policy_paths": restricted_paths,
        })
    return results


def compile_command_output_path(entry: dict[str, Any], directory: Path) -> Path | None:
    output = entry.get("output")
    if not isinstance(output, str) or not output:
        arguments = entry.get("arguments")
        if not isinstance(arguments, list):
            command = entry.get("command")
            try:
                arguments = shlex.split(command) if isinstance(command, str) else []
            except ValueError:
                arguments = []
        output = None
        for index, argument in enumerate(arguments):
            if not isinstance(argument, str):
                continue
            if argument == "-o" and index + 1 < len(arguments):
                output = arguments[index + 1]
                break
            if argument.startswith("-o") and len(argument) > 2:
                output = argument[2:]
                break
    if not isinstance(output, str) or not output:
        return None
    candidate = Path(output)
    return candidate if candidate.is_absolute() else directory / candidate


def compiled_source_object_inventory(
    root: Path, qemu_roots: list[dict[str, Any]]
) -> tuple[list[str], list[dict[str, Any]]]:
    """Map Meson compile-database source entries to object paths and hashes.

    This is a compile-input inventory, not proof of the final linker closure.
    """
    root = root.resolve()
    qemu_paths: list[tuple[Path, dict[str, Any]]] = []
    for item in qemu_roots:
        qemu_path = resolve_inside_root(root / item["path"], root)
        if qemu_path is not None and qemu_path.is_dir():
            qemu_paths.append((qemu_path, item))

    database_paths: list[str] = []
    records: list[dict[str, Any]] = []
    skipped_dirs = SKIP_DIRS - {"utm_build"}
    for current, dirnames, filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        dirnames[:] = [
            name for name in dirnames
            if name not in skipped_dirs
            and not name.endswith(".xcarchive")
            and not name.startswith("sysroot-")
            and not (current_path / name).is_symlink()
        ]
        if current_path.name != "utm_build":
            continue
        database_path = resolve_inside_root(current_path / "compile_commands.json", root)
        if database_path is None or not database_path.is_file():
            dirnames[:] = []
            continue
        database_relative = database_path.relative_to(root).as_posix()
        database_paths.append(database_relative)
        try:
            entries = json.loads(database_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid Meson compile database {database_relative}: {error}") from error
        if not isinstance(entries, list):
            raise ValueError(f"Meson compile database is not a list: {database_relative}")

        for entry_index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                continue
            source_value = entry.get("file")
            if not isinstance(source_value, str) or not source_value:
                continue
            directory_value = entry.get("directory")
            command_directory = Path(directory_value) if isinstance(directory_value, str) and directory_value else current_path
            if not command_directory.is_absolute():
                command_directory = current_path / command_directory
            command_directory = command_directory.resolve(strict=False)
            source_candidate = Path(source_value)
            if not source_candidate.is_absolute():
                source_candidate = command_directory / source_candidate
            source_resolved = resolve_inside_root(source_candidate, root)
            source_path = (
                source_resolved.relative_to(root).as_posix()
                if source_resolved is not None else str(source_candidate)
            )
            source_spdx = spdx_expression_for_file(source_resolved) if source_resolved is not None else None

            qemu_root_info = None
            qemu_relative = None
            if source_resolved is not None:
                for qemu_path, qemu_info in qemu_paths:
                    try:
                        qemu_relative = source_resolved.relative_to(qemu_path).as_posix()
                        qemu_root_info = qemu_info
                        break
                    except ValueError:
                        continue

            if source_spdx:
                effective_license = source_spdx
                license_basis = "SPDX_HEADER"
            elif qemu_root_info and qemu_root_info.get("unannotated_source_default"):
                effective_license = qemu_root_info["unannotated_source_default"]
                license_basis = "QEMU_LICENSE_DEFAULT_FOR_UNANNOTATED_SOURCE"
            else:
                effective_license = None
                license_basis = "NO_SPDX_OR_PROJECT_DEFAULT"

            policy_paths = qemu_root_info.get("gpl2_only_contribution_policy_paths", []) if qemu_root_info else []
            restricted_policy_path = False
            if qemu_relative:
                restricted_policy_path = any(
                    qemu_relative.startswith(policy[:-1] if policy.endswith("*") else policy)
                    for policy in policy_paths
                )

            object_candidate = compile_command_output_path(entry, command_directory)
            object_resolved = resolve_inside_root(object_candidate, root) if object_candidate is not None else None
            object_path = (
                object_resolved.relative_to(root).as_posix()
                if object_resolved is not None else str(object_candidate) if object_candidate is not None else None
            )
            source_exists = source_resolved is not None and source_resolved.is_file()
            object_exists = object_resolved is not None and object_resolved.is_file()
            gpl2_only_candidate = bool(
                effective_license
                and ("GPL-2.0-only" in effective_license or effective_license.strip() == "GPL-2.0")
            )
            records.append({
                "compile_database": database_relative,
                "entry_index": entry_index,
                "source_path": source_path,
                "source_exists": source_exists,
                "source_size": source_resolved.stat().st_size if source_exists else None,
                "source_sha256": sha256_file(source_resolved) if source_exists else None,
                "source_spdx": source_spdx,
                "effective_license": effective_license,
                "license_basis": license_basis,
                "qemu_source_root": qemu_root_info.get("path") if qemu_root_info else None,
                "qemu_restricted_gpl2_policy_path": restricted_policy_path,
                "gpl2_only_candidate": gpl2_only_candidate,
                "object_path": object_path,
                "object_exists": object_exists,
                "object_size": object_resolved.stat().st_size if object_exists else None,
                "object_sha256": sha256_file(object_resolved) if object_exists else None,
            })
        dirnames[:] = []
    return sorted(set(database_paths)), sorted(
        records, key=lambda item: (item["compile_database"], item["source_path"], item["object_path"] or "")
    )


def source_inventory(root: Path) -> tuple[list[str], dict[str, list[str]]]:
    license_files: list[str] = []
    spdx_files: dict[str, list[str]] = defaultdict(list)
    if not root.is_dir():
        return license_files, spdx_files
    root = root.resolve()

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
            resolved_path = resolve_inside_root(path, root)
            if resolved_path is None:
                continue
            relative = path.relative_to(root).as_posix()
            if LICENSE_NAME.match(filename):
                license_files.append(relative)
            if path.suffix not in SOURCE_SUFFIXES:
                continue
            try:
                if resolved_path.stat().st_size > 1024 * 1024:
                    continue
                with resolved_path.open("r", encoding="utf-8", errors="replace") as stream:
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
    package_root = package_root.resolve()
    frameworks_root = resolve_inside_root(package_root / "Frameworks", package_root)
    if frameworks_root is None or not frameworks_root.is_dir():
        return results

    seen_frameworks: set[Path] = set()
    for framework in sorted(frameworks_root.rglob("*.framework")):
        resolved_framework = resolve_inside_root(framework, package_root)
        if resolved_framework is None or not resolved_framework.is_dir():
            continue
        if resolved_framework in seen_frameworks:
            continue
        seen_frameworks.add(resolved_framework)

        info_candidates = [
            resolved_framework / "Info.plist",
            resolved_framework / "Resources" / "Info.plist",
            resolved_framework / "Versions" / "Current" / "Resources" / "Info.plist",
        ]
        info: dict[str, Any] = {}
        for candidate in info_candidates:
            resolved_candidate = resolve_inside_root(candidate, package_root)
            if resolved_candidate is not None and resolved_candidate.is_file():
                try:
                    with resolved_candidate.open("rb") as stream:
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
                resolved_framework / executable,
                resolved_framework / "Versions" / "Current" / executable,
            ])
        binary: Path | None = None
        binary_path: str | None = None
        for candidate in binary_candidates:
            resolved_binary = resolve_inside_root(candidate, package_root)
            if resolved_binary is not None and resolved_binary.is_file():
                binary = resolved_binary
                binary_path = candidate.relative_to(package_root).as_posix()
                break

        item: dict[str, Any] = {
            "path": framework.relative_to(package_root).as_posix(),
            "bundle_identifier": info.get("CFBundleIdentifier"),
            "executable": executable,
        }
        if binary is not None:
            item["binary_path"] = binary_path
            item["binary_size"] = binary.stat().st_size
            item["binary_sha256"] = sha256_file(binary)
        else:
            item["binary_path"] = None
        results.append(item)
    return results


def runtime_library_inventory(package_root: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    package_root = package_root.resolve()
    for path in sorted(package_root.rglob("*")):
        if path.suffix.lower() not in {".dylib", ".a"}:
            continue
        resolved_path = resolve_inside_root(path, package_root)
        if resolved_path is None or not resolved_path.is_file():
            continue
        results.append({
            "path": path.relative_to(package_root).as_posix(),
            "size": resolved_path.stat().st_size,
            "sha256": sha256_file(resolved_path),
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
    package_root = package_root.resolve()
    for path in sorted(package_root.rglob("*")):
        relative_path = path.relative_to(package_root)
        relative = relative_path.as_posix()
        if path.is_symlink():
            results.append({"path": relative, "category": "symlink", "target": os.readlink(path)})
            continue
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        parts = {part.lower() for part in relative_path.parts}
        if parts & firmware_directories or suffix in firmware_suffixes:
            category = "firmware-data"
        elif suffix in {".dylib", ".a"}:
            category = "runtime-library"
        elif any(part.lower().endswith(".framework") for part in relative_path.parts):
            category = "framework-resource"
        elif LICENSE_NAME.match(path.name):
            category = "license-or-notice"
        elif relative.lower() in provenance_names:
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
    qemu_source_roots = qemu_source_root_inventory(utm_root)
    compile_database_paths, compiled_sources = compiled_source_object_inventory(utm_root, qemu_source_roots)
    compiled_source_license_counts = Counter(
        item["effective_license"] or "UNMAPPED" for item in compiled_sources
    )
    compiled_gpl2_only_count = sum(item["gpl2_only_candidate"] for item in compiled_sources)
    compiled_restricted_policy_count = sum(item["qemu_restricted_gpl2_policy_path"] for item in compiled_sources)
    compiled_missing_spdx_count = sum(item["source_spdx"] is None for item in compiled_sources)
    compiled_unmapped_count = sum(item["effective_license"] is None for item in compiled_sources)
    frameworks = framework_inventory(package_root)
    runtime_libraries = runtime_library_inventory(package_root)
    package_files = package_file_inventory(package_root)
    package_file_category_counts = Counter(item["category"] for item in package_files)

    copied_reports: list[str] = []
    for name in PACKAGE_REPORTS:
        source = package_root / name
        resolved_source = resolve_inside_root(source, package_root)
        if resolved_source is not None and resolved_source.is_file():
            destination = output_dir / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(resolved_source, destination)
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
        "qemu_source_root_count": len(qemu_source_roots),
        "qemu_source_roots": qemu_source_roots,
        "compile_database_count": len(compile_database_paths),
        "compile_database_paths": compile_database_paths,
        "compiled_source_count": len(compiled_sources),
        "compiled_source_license_counts": dict(sorted(compiled_source_license_counts.items())),
        "compiled_gpl2_only_candidate_count": compiled_gpl2_only_count,
        "compiled_restricted_policy_path_count": compiled_restricted_policy_count,
        "compiled_source_missing_spdx_count": compiled_missing_spdx_count,
        "compiled_source_unmapped_count": compiled_unmapped_count,
        "compiled_sources": compiled_sources,
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
    (output_dir / "qemu-source-root-inventory.json").write_text(
        json.dumps(qemu_source_roots, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "compiled-source-object-inventory.json").write_text(
        json.dumps(compiled_sources, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    qemu_url_path = resolve_inside_root(package_root / "QEMU-SOURCE-URL.txt", package_root)
    utm_revision_path = resolve_inside_root(package_root / "UTM-SOURCE-REVISION.txt", package_root)
    qemu_url = (
        qemu_url_path.read_text(encoding="utf-8").strip()
        if qemu_url_path is not None and qemu_url_path.is_file()
        else "not recorded"
    )
    utm_revision = (
        utm_revision_path.read_text(encoding="utf-8").strip()
        if utm_revision_path is not None and utm_revision_path.is_file()
        else "not recorded"
    )
    lines = [
        "# QEMU iOS runtime license and dependency inventory",
        "",
        "**Status: INVENTORY ONLY — NOT A LEGAL OPINION OR REDISTRIBUTION APPROVAL.**",
        "",
        f"- UTM source revision: {utm_revision}",
        f"- QEMU source URL: {qemu_url}",
        f"- License/copyright files found: {len(license_files)}",
        f"- Distinct SPDX expressions found in scanned source headers: {len(spdx_counts)}",
        f"- QEMU source roots discovered: {len(qemu_source_roots)}",
        f"- Meson compile databases discovered: {len(compile_database_paths)}",
        f"- Compiled source/object records: {len(compiled_sources)}",
        f"- Compiled GPL-2.0-only candidates: {compiled_gpl2_only_count}",
        f"- Compiled files in QEMU GPL-2-only contribution-policy paths: {compiled_restricted_policy_count}",
        f"- Compiled files without SPDX headers: {compiled_missing_spdx_count}",
        f"- Compiled files without a project license fallback: {compiled_unmapped_count}",
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
    lines.extend(["", "## QEMU source-root license statements", ""])
    if qemu_source_roots:
        for item in qemu_source_roots:
            lines.append(
                f"- {item['path']}: unannotated-source default "
                f"{item['unannotated_source_default'] or 'not identified'}; "
                f"LICENSE {item['license_file'] or 'not found'} "
                f"(SHA-256 {item['license_sha256'] or 'not available'})"
            )
            if item["gpl2_only_contribution_policy_paths"]:
                lines.append(
                    "  - QEMU LICENSE contribution-policy paths: "
                    + ", ".join(item["gpl2_only_contribution_policy_paths"])
                )
    else:
        lines.append("- No QEMU source roots matching build-*/qemu-* were found.")
    lines.extend(["", "## Compiled source/object inventory", ""])
    lines.append(
        f"- Full source/object records and hashes: compiled-source-object-inventory.json "
        f"({len(compiled_sources)} records across {len(compile_database_paths)} compile databases)"
    )
    lines.append(
        "- This is a Meson compile-input inventory, not the final linker closure; it does not cover every Autotools/CMake target."
    )
    gpl2_candidates = [item for item in compiled_sources if item["gpl2_only_candidate"]]
    if gpl2_candidates:
        lines.append("- GPL-2.0-only candidates found in compiled sources:")
        lines.extend(
            f"  - {item['source_path']} -> {item['object_path'] or 'object output unavailable'}"
            for item in gpl2_candidates
        )
    else:
        lines.append("- No GPL-2.0-only SPDX candidates were found in captured Meson compile databases.")
    restricted_candidates = [item for item in compiled_sources if item["qemu_restricted_gpl2_policy_path"]]
    if restricted_candidates:
        lines.append("- Compiled sources under QEMU LICENSE contribution-policy paths:")
        lines.extend(f"  - {item['source_path']}" for item in restricted_candidates)
    else:
        lines.append("- No captured compiled sources fall under the restricted paths listed by the QEMU LICENSE file.")
    unmapped_candidates = [item for item in compiled_sources if item["effective_license"] is None]
    if unmapped_candidates:
        lines.append("- Compiled sources requiring manual license mapping:")
        lines.extend(f"  - {item['source_path']}" for item in unmapped_candidates)
    else:
        lines.append("- All captured compiled sources have an SPDX header or a recorded QEMU project-level default.")
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
        "- qemu-source-root-inventory.json records QEMU LICENSE defaults and contribution-policy paths as written in each discovered source tree; it is not a legal conclusion.",
        "- compiled-source-object-inventory.json maps Meson compile database source entries to object paths and hashes. It is not the final linked-object closure and does not cover all Autotools/CMake builds.",
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
    print(f"Meson compile databases: {manifest['compile_database_count']}; compiled source/object records: {manifest['compiled_source_count']}")
    print("This is inventory only; it does not approve redistribution.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
