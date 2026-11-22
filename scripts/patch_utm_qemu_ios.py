#!/usr/bin/env python3
"""Install narrow, idempotent iOS/QEMU fixes into UTM's dependency build script."""
from pathlib import Path
import sys


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if new in source:
        return source
    if old not in source:
        raise SystemExit(f"UTM build_dependencies.sh changed: cannot locate {label}")
    return source.replace(old, new, 1)


def patch_script(source: str) -> str:
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

    objc_args_anchor = 'echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross'
    cross_start = source.find("generate_meson_cross() {")
    cross_end = source.find("\n}", cross_start)
    options_marker = 'echo "[built-in options]" >> $cross'
    binaries_marker = 'echo "[binaries]" >> $cross'
    options_position = source.find(options_marker, cross_start, cross_end)
    objc_args_position = source.find(objc_args_anchor, cross_start, cross_end)
    binaries_position = source.find(binaries_marker, cross_start, cross_end)
    if cross_start < 0 or cross_end < 0 or not (
        cross_start < options_position < objc_args_position < binaries_position < cross_end
    ):
        raise SystemExit("UTM build_dependencies.sh changed: Objective-C flags are not in Meson built-in options")

    qemu_flags = 'QEMU_PLATFORM_BUILD_FLAGS="--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"'
    qemu_flags_with_target = qemu_flags[:-1] + ' --target-list=x86_64-softmmu"'
    source = replace_once(source, qemu_flags, qemu_flags_with_target, "iOS QEMU target-list configuration")

    qemu_build = 'build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS'
    qemu_patch_call = (
        ': "${ISTEAM_QEMU_JIT_PATCHER:?ISTEAM_QEMU_JIT_PATCHER is required}"\n'
        'python3 "$ISTEAM_QEMU_JIT_PATCHER" "$QEMU_DIR/tcg/region.c"\n'
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
        'echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross',
        'echo "[built-in options]" >> $cross',
        'echo "[binaries]" >> $cross',
        "--target-list=x86_64-softmmu",
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
    patched = patch_script(source)
    path.write_text(patched, encoding="utf-8")
    print("Installed idempotent iOS QEMU JIT, Meson-link and pre-build verification hooks.")


if __name__ == "__main__":
    main()
