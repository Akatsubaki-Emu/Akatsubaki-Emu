#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: package-utm-qemu-tci-runtime.sh /path/to/UTM-TCI.xcarchive build/output-name}"
OUT_REQUEST="${2:?usage: package-utm-qemu-tci-runtime.sh /path/to/UTM-TCI.xcarchive build/output-name}"
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

APP=""
for app_candidate in \
  "$ARCHIVE/Products/Applications/UTM SE.app" \
  "$ARCHIVE/Products/Applications/UTM.app"; do
  if [ -d "$app_candidate" ]; then
    APP="$app_candidate"
    break
  fi
done
if [ -z "$APP" ]; then
  echo "Neither UTM SE.app nor UTM.app exists in the archive: $ARCHIVE/Products/Applications" >&2
  exit 1
fi

test -d "$APP/Frameworks" || { echo "UTM app Frameworks directory is missing: $APP" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/Frameworks" "$OUT/QEMU"
: > "$OUT/runtime-file-inventory.txt"
cp -R "$APP/Frameworks"/. "$OUT/Frameworks/"

find "$APP" -type f \( -name '*.dylib' -o -name 'QEMU' -o -name 'qemu-*softmmu*' \) -print \
  | tee "$OUT/runtime-file-inventory.txt"

candidate=""
exports=""
while IFS= read -r file_path; do
  [ -n "$file_path" ] || continue
  file_description="$(file "$file_path")"
  if [[ "$file_description" == *"Mach-O"* && "$file_description" == *"dynamically linked shared library"* ]]; then
    candidate_exports="$(nm -gU "$file_path" 2>/dev/null || true)"
    if printf '%s\n' "$candidate_exports" | grep -qE ' _?isteam_qemu_set_jit_callbacks$'; then
      continue
    fi
    if printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_init$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_main_loop$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_cleanup$' &&
       printf '%s\n' "$candidate_exports" | grep -qE ' _?qemu_system_shutdown_request$'; then
      candidate="$file_path"
      exports="$candidate_exports"
      break
    fi
  fi
done < "$OUT/runtime-file-inventory.txt"

if [ -z "$candidate" ]; then
  echo "No UTM TCI dynamic library with lifecycle/shutdown exports and without the StikJIT callback export was found." >&2
  echo "The TCI archive must be built without the JIT allocator patch." >&2
  exit 2
fi

ARCHS="$(lipo -archs "$candidate")"
case " $ARCHS " in
  *" arm64 "*) ;;
  *) echo "TCI QEMU candidate is not device arm64: $candidate ($ARCHS)" >&2; exit 3 ;;
esac
if ! PLATFORM_INFO="$(vtool -show-build "$candidate" 2>&1)"; then
  echo "Unable to inspect TCI QEMU Mach-O build platform: $candidate" >&2
  exit 3
fi
if ! printf '%s\n' "$PLATFORM_INFO" | grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)'; then
  echo "TCI QEMU candidate is not built for physical iOS: $candidate" >&2
  printf '%s\n' "$PLATFORM_INFO" >&2
  exit 3
fi

case "$candidate" in
  "$APP/Frameworks/"*)
    relative="${candidate#"$APP/Frameworks/"}"
    framework_path="$(dirname "$relative")"
    if [ "$(basename "$framework_path")" = "QEMU.framework" ]; then
      framework_parent="$(dirname "$framework_path")"
      framework_prefix=""
      [ "$framework_parent" = "." ] || framework_prefix="$framework_parent/"
      source_framework="$APP/Frameworks/$framework_path"
      target_framework="$OUT/Frameworks/${framework_prefix}QEMU-TCI.framework"
      mkdir -p "$(dirname "$target_framework")"
      rm -rf "$target_framework"
      cp -R "$source_framework" "$target_framework"
      rm -rf "$OUT/Frameworks/$framework_path"
      binary_relative="${candidate#"$APP/Frameworks/$framework_path/"}"
      runtime_relative="Frameworks/${framework_prefix}QEMU-TCI.framework/$binary_relative"
    elif [[ "$relative" == *.dylib ]]; then
      target_relative="${relative%.dylib}-tci.dylib"
      mkdir -p "$(dirname "$OUT/Frameworks/$target_relative")"
      cp "$candidate" "$OUT/Frameworks/$target_relative"
      rm -f "$OUT/Frameworks/$relative"
      runtime_relative="Frameworks/$target_relative"
    else
      echo "Cannot safely distinguish the TCI QEMU library from its dependencies: $relative" >&2
      exit 3
    fi
    ;;
  *)
    echo "TCI QEMU candidate is outside UTM.app/Frameworks: $candidate" >&2
    exit 3
    ;;
esac

printf '%s\n' "$runtime_relative" > "$OUT/QEMU/runtime-library-path.txt"
printf '%s\n' "$exports" | grep -E ' _?qemu_(init|main_loop|cleanup)$| _?qemu_system_shutdown_request$' > "$OUT/exports.txt"

found="$(find "$APP" -type f \( \
  -name 'bios-256k.bin' -o -name 'vgabios-stdvga.bin' \
  -o -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -o -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \) -print -quit 2>/dev/null || true)"
if [ -z "$found" ]; then
  echo "TCI QEMU library was found, but no recognizable BIOS/firmware data files were found." >&2
  exit 4
fi
data_dir="$(dirname "$found")"
cp -R "$data_dir"/. "$OUT/QEMU/"
printf '%s\n' "$runtime_relative" > "$OUT/QEMU/runtime-library-path.txt"

while IFS= read -r firmware_file; do
  [ -n "$firmware_file" ] || continue
  source_dir="$(dirname "$firmware_file")"
  [ "$source_dir" = "$data_dir" ] && continue
  case "$source_dir" in
    "$APP") relative_dir="root" ;;
    "$APP"/*) relative_dir="${source_dir#"$APP"/}" ;;
    *) echo "Refusing firmware path outside UTM app: $firmware_file" >&2; exit 5 ;;
  esac
  case "/$relative_dir/" in
    *"/../"*|*"/./"*) echo "Refusing unsafe firmware directory: $relative_dir" >&2; exit 5 ;;
  esac
  target_dir="$OUT/QEMU/firmware/$relative_dir"
  mkdir -p "$target_dir"
  cp "$firmware_file" "$target_dir/"
done < <(find "$APP" -type f \( \
  -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \
  -o -name 'OVMF_VARS.fd' -o -name 'OVMF_VARS_4M.fd' \
  -o -name 'edk2-x86_64-code.fd' -o -name 'edk2-x86_64-code.secboot.fd' \
  -o -name 'edk2-x86_64-vars.fd' \) -print 2>/dev/null || true)

cat > "$OUT/BUILD-INFO.txt" <<EOF2
Source: utmapp/UTM at the revision checked out by the workflow
Target: physical iOS arm64
Runtime mode: TCI (no JIT)
UTM app product: $(basename "$APP")
Library source: $candidate
Packaged library path: $runtime_relative
Architectures: $ARCHS
Lifecycle and graceful-shutdown exports: verified by nm before packaging
StikDebug JIT callback export: forbidden and verified absent
Data source: $data_dir
Package layout: Frameworks/QEMU-TCI.framework and QEMU/ (firmware/data plus runtime manifest)
EOF2

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
test -s "$OUT/QEMU/runtime-library-path.txt"
test -s "$OUT/exports.txt"
test -s "$OUT/$runtime_relative"
find "$OUT/Frameworks" -type f -size +0c -print -quit | grep -q .
find "$OUT/QEMU" -type f -size +0c -print -quit | grep -q .
bash "$SCRIPT_DIR/validate-qemu-runtime.sh" "$OUT/$runtime_relative" tci allow-unsigned

echo "Packaged and inspected the no-JIT TCI runtime from $(basename "$APP")."
