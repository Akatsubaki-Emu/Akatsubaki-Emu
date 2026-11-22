#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: package-utm-qemu-runtime.sh /path/to/UTM.xcarchive /path/to/output [jit|tci]}"
OUT_REQUEST="${2:?usage: package-utm-qemu-runtime.sh /path/to/UTM.xcarchive build/output-name [jit|tci]}"
MODE="${3:-jit}"
case "$MODE" in
  jit|tci) ;;
  *) echo "Runtime mode must be jit or tci: $MODE" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

case "$OUT_REQUEST" in
  build/*) OUT_NAME="${OUT_REQUEST#build/}" ;;
  *) echo "Refusing unsafe output path (must be build/<name>): $OUT_REQUEST" >&2; exit 2 ;;
esac
case "$OUT_NAME" in
  ""|"."|".."|*/*|*\\*) echo "Refusing invalid output directory name." >&2; exit 2 ;;
esac

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
MODE_DIR="$OUT/QEMU"
if [ "$MODE" = "tci" ]; then
  MODE_DIR="$OUT/QEMU/TCI"
  mkdir -p "$MODE_DIR"
fi
: > "$OUT/runtime-file-inventory.txt"

if [ -d "$APP/Frameworks" ]; then
  cp -R "$APP/Frameworks"/. "$OUT/Frameworks/"
fi

find "$APP" -type f \( -name '*.dylib' -o -name 'QEMU' -o -name 'qemu-*softmmu*' \) -print \
  | tee "$OUT/runtime-file-inventory.txt"

has_export() {
  grep -Eq " _?${1}$" <<< "$candidate_exports"
}

candidate=""
exports=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  file_description="$(file "$file")"
  if [[ "$file_description" != *"Mach-O"* || "$file_description" != *"dynamically linked shared library"* ]]; then
    continue
  fi

  candidate_exports="$(nm -gU "$file" 2>/dev/null || true)"
  if ! has_export qemu_init \
    || ! has_export qemu_main_loop \
    || ! has_export qemu_cleanup \
    || ! has_export qemu_system_shutdown_request; then
    continue
  fi

  has_jit_callbacks=false
  if grep -qE ' _?isteam_qemu_set_jit_callbacks$' <<< "$candidate_exports"; then
    has_jit_callbacks=true
  fi

  if [ "$MODE" = "jit" ] && [ "$has_jit_callbacks" != true ]; then
    continue
  fi
  if [ "$MODE" = "tci" ] && [ "$has_jit_callbacks" = true ]; then
    continue
  fi

  candidate="$file"
  exports="$candidate_exports"
  break
done < "$OUT/runtime-file-inventory.txt"

if [ -z "$candidate" ]; then
  echo "No UTM in-process QEMU $MODE dynamic library with the required lifecycle/shutdown exports and mode-specific JIT policy was found." >&2
  echo "The artifact was rejected rather than pretending an executable is a loadable runtime." >&2
  exit 2
fi

ARCHS="$(lipo -archs "$candidate")"
case " $ARCHS " in
  *" arm64 "*) ;;
  *) echo "QEMU candidate is not device arm64: $candidate ($ARCHS)" >&2; exit 3 ;;
esac

if ! PLATFORM_INFO="$(vtool -show-build "$candidate" 2>&1)"; then
  echo "Unable to inspect QEMU Mach-O build platform: $candidate" >&2
  exit 3
fi
if ! printf '%s\n' "$PLATFORM_INFO" | grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)'; then
  echo "QEMU candidate is not built for physical iOS: $candidate" >&2
  printf '%s\n' "$PLATFORM_INFO" >&2
  exit 3
fi

# JIT and TCI packages come from separate UTM archives. Preserve the framework's
# original install name/path; renaming it can invalidate LC_ID_DYLIB/@rpath.
case "$candidate" in
  "$APP/Frameworks/"*)
    relative="${candidate#"$APP/Frameworks/"}"
    runtime_relative="Frameworks/$relative"
    ;;
  *)
    runtime_relative="Frameworks/$(basename "$candidate")"
    cp "$candidate" "$OUT/$runtime_relative"
    ;;
esac

# Keep the legacy JIT paths used by release.yml. A separate TCI archive stores
# its manifest/data in QEMU/TCI, as QEMURuntimeStatus expects for requiresJIT=false.
printf '%s\n' "$runtime_relative" > "$MODE_DIR/runtime-library-path.txt"
printf '%s\n' "$exports" \
  | grep -E ' _?qemu_(init|main_loop|cleanup)$| _?qemu_system_shutdown_request$| _?isteam_qemu_set_jit_callbacks$' \
  > "$MODE_DIR/exports.txt" || true
if [ "$MODE" = "jit" ]; then
  cp "$MODE_DIR/exports.txt" "$OUT/exports.txt"
fi

data_dir=""
found="$(find "$APP" -type f \( \
  -name 'bios-256k.bin' -o -name 'vgabios-stdvga.bin' \
  -o -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -o -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \
  \) -print -quit 2>/dev/null || true)"
if [ -n "$found" ]; then
  data_dir="$(dirname "$found")"
fi
if [ -z "$data_dir" ]; then
  echo "QEMU lifecycle library was found, but no recognizable QEMU BIOS/firmware data files were found." >&2
  exit 4
fi
cp -R "$data_dir"/. "$MODE_DIR/"

printf '%s\n' "$runtime_relative" > "$MODE_DIR/runtime-library-path.txt"

while IFS= read -r firmware_file; do
  [ -n "$firmware_file" ] || continue
  source_dir="$(dirname "$firmware_file")"
  [ "$source_dir" = "$data_dir" ] && continue
  case "$source_dir" in
    "$APP") relative_dir="root" ;;
    "$APP"/*) relative_dir="${source_dir#"$APP"/}" ;;
    *) echo "Refusing firmware path outside UTM.app: $firmware_file" >&2; exit 5 ;;
  esac
  case "/$relative_dir/" in
    *"/../"*|*"/./"*) echo "Refusing unsafe firmware directory: $relative_dir" >&2; exit 5 ;;
  esac
  target_dir="$MODE_DIR/firmware/$relative_dir"
  mkdir -p "$target_dir"
  cp "$firmware_file" "$target_dir/"
done < <(find "$APP" -type f \( \
  -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \
  -name 'OVMF_VARS.fd' -o -name 'OVMF_VARS_4M.fd' \
  -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -name 'edk2-x86_64-vars.fd' \
  \) -print 2>/dev/null || true)

cat > "$OUT/BUILD-INFO.txt" <<EOF
Source: utmapp/UTM at the revision checked out by the workflow
Target: physical iOS arm64
Runtime mode: $MODE
Library source: $candidate
Packaged library path: $runtime_relative
Architectures: $ARCHS
Lifecycle and graceful-shutdown exports: verified by nm before packaging
StikJIT callback export required: $([ "$MODE" = "jit" ] && echo yes || echo no)
Data source: $data_dir
Package layout: Frameworks/ (UTM dependencies), QEMU/ (mode-specific data and runtime manifest)
Important: embed and code-sign nested code in Akatsubaki Emu and boot-test on a physical device before claiming runtime support.
EOF

REPORT="$OUT/dependency-report.txt"
: > "$REPORT"
for root in "$OUT/Frameworks" "$MODE_DIR"; do
  [ -d "$root" ] || continue
  while IFS= read -r -d '' binary; do
    if file "$binary" | grep -q 'Mach-O'; then
      {
        printf '\n===== %s =====\n' "${binary#"$OUT"/}"
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
find "$MODE_DIR" -type f -size +0c -print -quit | grep -q .
