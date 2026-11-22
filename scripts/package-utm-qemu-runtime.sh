#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: package-utm-qemu-runtime.sh /path/to/UTM.xcarchive /path/to/output}"
OUT_REQUEST="${2:?usage: package-utm-qemu-runtime.sh /path/to/UTM.xcarchive build/output-name}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# The next step removes OUT recursively, so accept only a single named child of
# the real repository build/ directory. No absolute paths, traversal or symlinks.
case "$OUT_REQUEST" in
    build/*) OUT_NAME="${OUT_REQUEST#build/}" ;;
    *) echo "Refusing unsafe output path (must be build/<name>): $OUT_REQUEST" >&2; exit 2 ;;
esac
case "$OUT_NAME" in ""|"."|".."|*/*|*\\*) echo "Refusing invalid output directory name." >&2; exit 2 ;; esac
BUILD_DIR="$REPO_ROOT/build"
if [ -L "$BUILD_DIR" ]; then
    echo "Refusing a symlink build directory: $BUILD_DIR" >&2
    exit 2
fi
mkdir -p "$BUILD_DIR"
BUILD_ROOT="$(cd "$BUILD_DIR" && pwd -P)"
if [ "$BUILD_ROOT" != "$BUILD_DIR" ]; then
    echo "Refusing a build directory that resolves outside the repository." >&2
    exit 2
fi
OUT="$BUILD_ROOT/$OUT_NAME"
if [ -L "$OUT" ]; then
    echo "Refusing to replace a symlink output directory: $OUT" >&2
    exit 2
fi
APP="$ARCHIVE/Products/Applications/UTM.app"
test -d "$APP" || { echo "UTM.app missing from archive: $APP" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/QEMU" "$OUT/Frameworks"
: > "$OUT/runtime-file-inventory.txt"

# Keep UTM's Frameworks tree intact: the QEMU dylib can depend on sibling
# dylibs and frameworks through @rpath.
if [ -d "$APP/Frameworks" ]; then
  cp -R "$APP/Frameworks"/. "$OUT/Frameworks/"
fi

find "$APP" -type f \( -name '*.dylib' -o -name 'QEMU' -o -name 'qemu-*softmmu*' \) -print \
  | tee "$OUT/runtime-file-inventory.txt"

candidate=""
exports=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  file_description="$(file "$file")"
  if [[ "$file_description" == *"Mach-O"* && "$file_description" == *"dynamically linked shared library"* ]]; then
    candidate_exports="$(nm -gU "$file" 2>/dev/null || true)"
    if printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_init$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_main_loop$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_cleanup$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_system_shutdown_request$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?isteam_qemu_set_jit_callbacks$'; then
      candidate="$file"
      exports="$candidate_exports"
      break
    fi
  fi
done < "$OUT/runtime-file-inventory.txt"

if [ -z "$candidate" ]; then
  echo "No UTM in-process QEMU dynamic library exporting qemu_init, qemu_main_loop, qemu_cleanup, qemu_system_shutdown_request, and isteam_qemu_set_jit_callbacks was found." >&2
  echo "The artifact was rejected rather than pretending an executable is a loadable runtime." >&2
  exit 2
fi

ARCHS="$(lipo -archs "$candidate")"
case " $ARCHS " in
  *" arm64 "*) ;;
  *) echo "QEMU candidate is not device arm64: $candidate ($ARCHS)" >&2; exit 3 ;;
esac

# arm64 alone does not distinguish an iOS device binary from macOS or simulator code.
if ! PLATFORM_INFO="$(vtool -show-build "$candidate" 2>&1)"; then
  echo "Unable to inspect QEMU Mach-O build platform: $candidate" >&2
  exit 3
fi
if ! printf '%s\n' "$PLATFORM_INFO" | grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)'; then
  echo "QEMU candidate is not built for physical iOS: $candidate" >&2
  printf '%s\n' "$PLATFORM_INFO" >&2
  exit 3
fi

# Preserve the relative location inside UTM.app/Frameworks whenever possible.
case "$candidate" in
  "$APP/Frameworks/"*)
    relative="${candidate#"$APP/Frameworks/"}"
    test -e "$OUT/Frameworks/$relative" || {
      mkdir -p "$(dirname "$OUT/Frameworks/$relative")"
      cp "$candidate" "$OUT/Frameworks/$relative"
    }
    runtime_relative="Frameworks/$relative"
    ;;
  *)
    runtime_relative="Frameworks/$(basename "$candidate")"
    cp "$candidate" "$OUT/$runtime_relative"
    ;;
esac

# The app resolves the runtime through this manifest rather than assuming
# that every UTM revision names its loadable library the same way.
printf '%s\n' "$runtime_relative" > "$OUT/QEMU/runtime-library-path.txt"
printf '%s\n' "$exports" | grep -E ' _?qemu_(init|main_loop|cleanup)$| _?qemu_system_shutdown_request$| _?isteam_qemu_set_jit_callbacks$' > "$OUT/exports.txt" || true

data_dir=""
found="$(find "$APP" -type f \( \
  -name 'bios-256k.bin' -o -name 'vgabios-stdvga.bin' \
  -o -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -o -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \) -print -quit 2>/dev/null || true)"
if [ -n "$found" ]; then data_dir="$(dirname "$found")"; fi
if [ -z "$data_dir" ]; then
  echo "QEMU lifecycle library was found, but no recognizable QEMU BIOS/firmware data files were found." >&2
  exit 4
fi
cp -R "$data_dir"/. "$OUT/QEMU/"

# Preserve the generated path manifest if the source data directory happened
# to contain a file with the same name.
printf '%s\n' "$runtime_relative" > "$OUT/QEMU/runtime-library-path.txt"
while IFS= read -r firmware_file; do
  [ -n "$firmware_file" ] || continue
  cp "$firmware_file" "$OUT/QEMU/$(basename "$firmware_file")"
done < <(find "$APP" -type f \( \
  -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \
  -o -name 'OVMF_VARS.fd' -o -name 'OVMF_VARS_4M.fd' \
  -o -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -o -name 'edk2-x86_64-vars.fd' \) -print 2>/dev/null || true)

cat > "$OUT/BUILD-INFO.txt" <<EOF
Source: utmapp/UTM at the revision checked out by the workflow
Target: physical iOS arm64
Library source: $candidate
Packaged library path: $runtime_relative
Architectures: $ARCHS
Lifecycle, graceful-shutdown and StikDebug JIT callback exports: verified by nm before packaging
Data source: $data_dir
Package layout: Frameworks/ (UTM dependencies), QEMU/ (QEMU data files and runtime manifest)
Important: embed and code-sign nested code in Akatsubaki Emu and boot-test on a physical device before claiming runtime support.
EOF

# Record the actual Mach-O linkage and runtime search paths. This report helps
# distinguish a missing symbol from a missing @rpath dependency on-device.
REPORT="$OUT/dependency-report.txt"
: > "$REPORT"
for root in "$OUT/Frameworks" "$OUT/QEMU"; do
  [ -d "$root" ] || continue
  while IFS= read -r -d '' binary; do
    if file "$binary" | grep -q 'Mach-O'; then
      {
        printf '\n===== %s =====\n' "${binary#"$OUT/"}"
        printf '%s\n' '-- architectures --'
        lipo -archs "$binary" 2>&1 || true
        printf '%s\n' '-- linked libraries --'
        otool -L "$binary" 2>&1 || true
        printf '%s\n' '-- LC_RPATH entries --'
        otool -l "$binary" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; print}' || true
      } >> "$REPORT"
    fi
  done < <(find "$root" -type f -print0)
done

test -s "$REPORT"
find "$OUT/Frameworks" -type f -size +0c -print -quit | grep -q .
find "$OUT/QEMU" -type f -size +0c -print -quit | grep -q .
