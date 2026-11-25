#!/usr/bin/env python3
"""Install narrow, idempotent iOS/QEMU fixes into UTM's dependency build script."""
from pathlib import Path
import sys

TCI_BUILD_FAMILY_MARKER = 'PLATFORM_FAMILY_NAME="$PLATFORM_FAMILY_PREFIX-TCI"'

TCI_TARGET_LIST_DEFAULT = "x86_64-softmmu"
TCI_TARGET_LIST_UPSTREAM = "aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu"
TCI_TARGET_LIST_PATTERN = r"^[a-z0-9_]+-softmmu(,[a-z0-9_]+-softmmu)*$"
TCI_FLAGS_PREFIX = 'TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list='


def tci_target_list_shell_block() -> str:
    """Return the validated Bash block used by UTM's iOS TCI build."""
    default = TCI_TARGET_LIST_DEFAULT
    return (
        'TCI_GUEST_TARGETS="${ISTEAM_QEMU_TCI_TARGET_LIST:-' + default + '}"\n'
        'if [[ ! "$TCI_GUEST_TARGETS" =~ ' + TCI_TARGET_LIST_PATTERN + ' ]]; then\n'
        '    echo "Invalid ISTEAM_QEMU_TCI_TARGET_LIST: $TCI_GUEST_TARGETS (expected comma-separated *-softmmu targets)." >&2\n'
        '    exit 1\n'
        'fi'
    )


def patch_tci_target_list(source: str) -> str:
    """Default TCI to x86-64 while preserving a validated multi-architecture override."""
    marker = 'TCI_GUEST_TARGETS="'
    if marker in source:
        required = (
            marker,
            '[[ ! "$TCI_GUEST_TARGETS" =~ ' + TCI_TARGET_LIST_PATTERN + ' ]]',
            '--target-list=$TCI_GUEST_TARGETS',
        )
        if any(token not in source for token in required):
            raise SystemExit("Existing TCI guest-target override is incomplete")
        return source

    if source.count(TCI_FLAGS_PREFIX) != 1:
        raise SystemExit("UTM TCI_BUILD_FLAGS target-list anchor changed")
    start = source.index(TCI_FLAGS_PREFIX)
    line_start = source.rfind("\n", 0, start) + 1
    indent = source[line_start:start]
    target_start = start + len(TCI_FLAGS_PREFIX)
    quote_end = source.find('"', target_start)
    if quote_end < 0:
        raise SystemExit("UTM TCI_BUILD_FLAGS quote is missing")
    target_end = source.find(" ", target_start, quote_end)
    if target_end < 0 or source[target_start:target_end] != TCI_TARGET_LIST_UPSTREAM:
        raise SystemExit("UTM upstream TCI target list changed; review before patching")

    line_end = source.find("\n", quote_end)
    if line_end < 0:
        line_end = len(source)
    flags_tail = source[target_end:quote_end]
    suffix = source[quote_end + 1:line_end]
    new_lines = [indent + line for line in tci_target_list_shell_block().splitlines()]
    new_lines.append(
        indent + 'TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list=$TCI_GUEST_TARGETS'
        + flags_tail + '"' + suffix
    )
    return source[:line_start] + "\n".join(new_lines) + source[line_end:]




def validate_tci_build_directory(source: str) -> None:
    if "ios-tci" not in source or TCI_BUILD_FAMILY_MARKER not in source:
        raise SystemExit("UTM build_dependencies.sh no longer isolates the iOS TCI build directory")


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if new in source:
        return source
    if old not in source:
        raise SystemExit(f"UTM build_dependencies.sh changed: cannot locate {label}")
    return source.replace(old, new, 1)


def patch_script(source: str) -> str:
    source = patch_tci_target_list(source)
    # Keep the reusable workflow's freshness guard available before patching/building UTM.
    freshness_script = Path(__file__).with_name("check-build-freshness.sh")
    if not freshness_script.is_file():
        raise SystemExit("Required build freshness guard is missing: scripts/check-build-freshness.sh")

    download_hook = "download () {\n    URL=$1"
    download_patch = (
        "download () {\n"
        "    URL=$1\n"
        "    case \"$URL\" in\n"
        "        http://ftp.gnu.org/gnu/libiconv/*)\n"
        "            URL=\"https://ftp.gnu.org/pub/gnu/libiconv/${URL##*/}\"\n"
        "            ;;\n"
        "    esac"
    )
    source = replace_once(
        source, download_hook, download_patch,
        "GNU libiconv HTTPS download"
    )

    cross_marker = 'echo "has_function_dup3 = false" >> $cross'
    cross_override = 'echo "has_function_posix_memalign = true" >> $cross'
    source = replace_once(
        source, cross_marker,
        cross_marker + "\n    " + cross_override,
        "Meson cross-file feature overrides"
    )

    qemu_flags = 'QEMU_PLATFORM_BUILD_FLAGS="--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"'
    qemu_flags_with_mode = (
        qemu_flags + "\n"
        'case "$PLATFORM" in\n'
        '    *-tci) ;; # TCI_BUILD_FLAGS already selects the threaded interpreter and guest targets.\n'
        '    *) QEMU_PLATFORM_BUILD_FLAGS="$QEMU_PLATFORM_BUILD_FLAGS --target-list=x86_64-softmmu" ;;\n'
        'esac'
    )
    source = replace_once(source, qemu_flags, qemu_flags_with_mode, "mode-aware iOS QEMU target-list configuration")

    qemu_build = 'build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS'
    qemu_patch_call = (
        'case "$PLATFORM" in\n'
        '    *-tci) : "${ISTEAM_QEMU_TCI_EXPORT_PATCHER:?ISTEAM_QEMU_TCI_EXPORT_PATCHER is required for TCI mode}"\n'
        '           python3 "$ISTEAM_QEMU_TCI_EXPORT_PATCHER" "$QEMU_DIR/system/qemu.symbols" ;;\n'
        '    *) : "${ISTEAM_QEMU_JIT_PATCHER:?ISTEAM_QEMU_JIT_PATCHER is required for JIT mode}"\n'
        '       python3 "$ISTEAM_QEMU_JIT_PATCHER" "$QEMU_DIR/tcg/region.c" ;;\n'
        'esac\n'
        ': "${ISTEAM_QEMU_MESON_PATCHER:?ISTEAM_QEMU_MESON_PATCHER is required}"\n'
        'python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"\n'
        + qemu_build
    )
    source = replace_once(source, qemu_build, qemu_patch_call, "QEMU configure invocation")

    configure_block = (
        '        ./configure --prefix="$PREFIX" --host="$CHOST" $@\n'
        '    fi\n'
        '    echo "${GREEN}Building ${NAME}...${NC}"'
    )
    configure_with_check = (
        '        ./configure --prefix="$PREFIX" --host="$CHOST" $@\n'
        '    fi\n'
        '    if [ "$DIR" = "$QEMU_DIR" ]; then\n'
        '        : "${IOS_COMPILER_RT:?IOS_COMPILER_RT is required for the QEMU link check}"\n'
        '        : "${ISTEAM_QEMU_LINK_VERIFIER:?ISTEAM_QEMU_LINK_VERIFIER is required}"\n'
        '        python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"\n'
        '    fi\n'
        '    echo "${GREEN}Building ${NAME}...${NC}"'
    )
    source = replace_once(source, configure_block, configure_with_check, "QEMU configure/build boundary")

    required = [
        'http://ftp.gnu.org/gnu/libiconv/*',
        'https://ftp.gnu.org/pub/gnu/libiconv/${URL##*/}',
        cross_override,
        '*-tci) ;; # TCI_BUILD_FLAGS already selects the threaded interpreter and guest targets.',
        "ISTEAM_QEMU_TCI_EXPORT_PATCHER is required for TCI mode",
        'python3 "$ISTEAM_QEMU_TCI_EXPORT_PATCHER" "$QEMU_DIR/system/qemu.symbols"',
        "--target-list=x86_64-softmmu",
        "ISTEAM_QEMU_TCI_TARGET_LIST",
        "TCI_GUEST_TARGETS",
        "--target-list=$TCI_GUEST_TARGETS",
        'python3 "$ISTEAM_QEMU_JIT_PATCHER" "$QEMU_DIR/tcg/region.c"',
        'python3 "$ISTEAM_QEMU_MESON_PATCHER" "$QEMU_DIR/meson.build"',
        'python3 "$ISTEAM_QEMU_LINK_VERIFIER" "$PWD/build/build.ninja" "$IOS_COMPILER_RT"',
    ]
    missing = [item for item in required if item not in source]
    if missing:
        raise SystemExit("UTM patch verification failed: " + ", ".join(missing))
    return source


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_utm_qemu_ios.py /path/to/UTM/scripts/build_dependencies.sh")
    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    validate_tci_build_directory(source)
    patched = patch_script(source)
    path.write_text(patched, encoding="utf-8")
    print("Installed idempotent iOS QEMU JIT/TCI, Meson-link and pre-build verification hooks.")


if __name__ == "__main__":
    main()
