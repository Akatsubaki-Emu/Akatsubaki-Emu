#!/usr/bin/env bash
set -euo pipefail

JIT_REQUEST="${1:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"
TCI_REQUEST="${2:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"
OUT_REQUEST="${3:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"

fail() { echo "QEMU runtime merge failed: $*" >&2; exit 1; }

ROOT="$(pwd -P)"
BUILD_ROOT="$ROOT/build"
mkdir -p "$BUILD_ROOT"
[[ ! -L "$BUILD_ROOT" && "$(cd "$BUILD_ROOT" && pwd -P)" == "$BUILD_ROOT" ]] || fail "unsafe build directory"

case "$OUT_REQUEST" in
  build/*) OUT_NAME="${OUT_REQUEST#build/}" ;;
  *) fail "output must be a named direct child of build/: $OUT_REQUEST" ;;
esac
case "$OUT_NAME" in
  ""|"."|".."|*/*|*\\*) fail "output must be a simple directory name beneath build/: $OUT_REQUEST" ;;
esac
OUT="$BUILD_ROOT/$OUT_NAME"
[[ ! -L "$OUT" ]] || fail "refusing symlink output directory: $OUT"
[[ ! -e "$OUT" || -d "$OUT" ]] || fail "output exists and is not a directory: $OUT"

[[ -d "$JIT_REQUEST" && -d "$TCI_REQUEST" ]] || fail "input package directory is missing"
JIT_DIR="$(cd "$JIT_REQUEST" && pwd -P)"
TCI_DIR="$(cd "$TCI_REQUEST" && pwd -P)"
[[ "$JIT_DIR" != "$TCI_DIR" ]] || fail "JIT and TCI inputs must be different directories"

path_is_within() {
  local candidate="$1" parent="$2"
  case "$candidate/" in "$parent/"*) return 0 ;; esac
  return 1
}
if path_is_within "$JIT_DIR" "$OUT" || path_is_within "$TCI_DIR" "$OUT" \
  || path_is_within "$OUT" "$JIT_DIR" || path_is_within "$OUT" "$TCI_DIR"; then
  fail "output directory must not contain or be contained by either input package"
fi

for package in "$JIT_DIR" "$TCI_DIR"; do
  [[ -d "$package/Frameworks" && ! -L "$package/Frameworks" && -d "$package/QEMU" && ! -L "$package/QEMU" ]] || fail "incomplete or symlinked package: $package"
  [[ -s "$package/UTM-SOURCE-REVISION.txt" ]] || fail "missing UTM source revision: $package"
  [[ -s "$package/QEMU/runtime-library-path.txt" ]] || fail "missing runtime library manifest: $package"
  [[ -s "$package/exports.txt" ]] || fail "missing exports report: $package"
done

jit_revision="$(tr -d '\r\n' < "$JIT_DIR/UTM-SOURCE-REVISION.txt")"
tci_revision="$(tr -d '\r\n' < "$TCI_DIR/UTM-SOURCE-REVISION.txt")"
[[ -n "$jit_revision" && "$jit_revision" == "$tci_revision" ]] || fail "JIT and TCI artifacts were built from different UTM revisions"

required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)
for symbol in "${required_symbols[@]}"; do
  grep -Fq "$symbol" "$JIT_DIR/exports.txt" || fail "JIT artifact is missing required export: $symbol"
  grep -Fq "$symbol" "$TCI_DIR/exports.txt" || fail "TCI artifact is missing required export: $symbol"
done
grep -Fq 'isteam_qemu_set_jit_callbacks' "$JIT_DIR/exports.txt" || fail "JIT artifact is missing the StikJIT callback export"
if grep -Fq 'isteam_qemu_set_jit_callbacks' "$TCI_DIR/exports.txt"; then
  fail "TCI artifact unexpectedly contains the StikJIT callback export"
fi

safe_relative_path() {
  local value="$1" part
  local -a components=()
  [[ -n "$value" && "$value" != /* && "$value" != */ && "$value" != *\\* ]] || return 1
  IFS='/' read -r -a components <<< "$value"
  for part in "${components[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
  done
}
jit_library="$(tr -d '\r\n' < "$JIT_DIR/QEMU/runtime-library-path.txt")"
tci_library="$(tr -d '\r\n' < "$TCI_DIR/QEMU/runtime-library-path.txt")"
safe_relative_path "$jit_library" || fail "unsafe JIT library path in manifest"
safe_relative_path "$tci_library" || fail "unsafe TCI library path in manifest"
[[ "$jit_library" == Frameworks/* && "$tci_library" == Frameworks/* ]] || fail "runtime libraries must be inside Frameworks/"
[[ -f "$JIT_DIR/$jit_library" ]] || fail "JIT library missing from package: $jit_library"
[[ -f "$TCI_DIR/$tci_library" ]] || fail "TCI library missing from package: $tci_library"

tci_framework_relative="${tci_library#Frameworks/}"
tci_framework_component="${tci_framework_relative%%/*}"
[[ -n "$tci_framework_component" && "$tci_framework_component" != "TCI" ]] || fail "invalid TCI framework component in manifest"

TEMP_OUT="$BUILD_ROOT/.${OUT_NAME}.tmp.$$"
[[ ! -e "$TEMP_OUT" && ! -L "$TEMP_OUT" ]] || fail "temporary output already exists: $TEMP_OUT"
cleanup() { [[ -z "${TEMP_OUT:-}" ]] || rm -rf "$TEMP_OUT"; }
trap cleanup EXIT
mkdir -p "$TEMP_OUT/Frameworks" "$TEMP_OUT/QEMU/JIT" "$TEMP_OUT/QEMU/TCI"

merge_framework_tree() {
  local source_root="$1" destination_root="$2" excluded_top_level="${3:-}"
  local entry relative target link_target part
  while IFS= read -r -d '' entry; do
    relative="${entry#"$source_root"/}"
    if [[ -n "$excluded_top_level" && ( "$relative" == "$excluded_top_level" || "$relative" == "$excluded_top_level/"* ) ]]; then
      continue
    fi
    target="$destination_root/$relative"
    if [[ -L "$entry" ]]; then
      link_target="$(readlink "$entry")"
      [[ "$link_target" != /* && "$link_target" != *\\* ]] || fail "unsafe framework symlink: $relative -> $link_target"
      local -a link_components=()
      IFS='/' read -r -a link_components <<< "$link_target"
      for part in "${link_components[@]}"; do
        [[ "$part" != ".." ]] || fail "framework symlink escapes its tree: $relative -> $link_target"
      done
      if [[ -e "$target" || -L "$target" ]]; then
        [[ -L "$target" && "$link_target" == "$(readlink "$target")" ]] || fail "conflicting framework symlink: $relative"
      else
        mkdir -p "$(dirname "$target")"
        cp -a "$entry" "$target"
      fi
    elif [[ -d "$entry" ]]; then
      [[ ! -e "$target" || -d "$target" ]] || fail "framework file/directory collision: $relative"
      mkdir -p "$target"
    elif [[ -f "$entry" ]]; then
      if [[ -e "$target" ]]; then
        [[ -f "$target" ]] && cmp -s "$entry" "$target" || fail "different JIT/TCI dependency bytes: $relative"
      else
        mkdir -p "$(dirname "$target")"
        cp -a "$entry" "$target"
      fi
    else
      fail "unsupported framework entry: $relative"
    fi
  done < <(find "$source_root" -mindepth 1 -print0)
}

merge_framework_tree "$JIT_DIR/Frameworks" "$TEMP_OUT/Frameworks"
[[ ! -e "$TEMP_OUT/Frameworks/TCI" && ! -L "$TEMP_OUT/Frameworks/TCI" ]] || fail "JIT frameworks already use the reserved Frameworks/TCI path"
merge_framework_tree "$TCI_DIR/Frameworks" "$TEMP_OUT/Frameworks" "$tci_framework_component"
mkdir -p "$TEMP_OUT/Frameworks/TCI"
tci_component_source="$TCI_DIR/Frameworks/$tci_framework_component"
tci_component_destination="$TEMP_OUT/Frameworks/TCI/$tci_framework_component"
[[ ! -L "$tci_component_source" ]] || fail "TCI runtime library component must not be a symlink"
if [[ -d "$tci_component_source" ]]; then
  mkdir -p "$tci_component_destination"
  merge_framework_tree "$tci_component_source" "$tci_component_destination"
elif [[ -f "$tci_component_source" ]]; then
  cp -a "$tci_component_source" "$tci_component_destination"
else
  fail "TCI runtime library component is missing: $tci_framework_component"
fi

tci_library_merged="Frameworks/TCI/$tci_framework_relative"
cp -a "$JIT_DIR/QEMU/." "$TEMP_OUT/QEMU/JIT/"
cp -a "$TCI_DIR/QEMU/." "$TEMP_OUT/QEMU/TCI/"
printf '%s\n' "$jit_library" > "$TEMP_OUT/QEMU/JIT/runtime-library-path.txt"
printf '%s\n' "$tci_library_merged" > "$TEMP_OUT/QEMU/TCI/runtime-library-path.txt"
cp "$JIT_DIR/exports.txt" "$TEMP_OUT/QEMU/JIT/exports.txt"
cp "$TCI_DIR/exports.txt" "$TEMP_OUT/QEMU/TCI/exports.txt"
cp "$JIT_DIR/UTM-SOURCE-REVISION.txt" "$TEMP_OUT/UTM-SOURCE-REVISION.txt"
cp "$JIT_DIR/UTM-archive-Info.plist" "$TEMP_OUT/UTM-JIT-archive-Info.plist" 2>/dev/null || true
cp "$TCI_DIR/UTM-archive-Info.plist" "$TEMP_OUT/UTM-TCI-archive-Info.plist" 2>/dev/null || true

{
  echo "JIT=$jit_library"
  echo "TCI=$tci_library_merged"
  echo "UTM_REVISION=$jit_revision"
} > "$TEMP_OUT/QEMU/runtime-mode-manifest.txt"
{
  echo "=== JIT runtime ==="
  cat "$JIT_DIR/BUILD-INFO.txt" 2>/dev/null || true
  echo "=== TCI runtime ==="
  cat "$TCI_DIR/BUILD-INFO.txt" 2>/dev/null || true
} > "$TEMP_OUT/BUILD-INFO.txt"
{
  echo "=== JIT exports ==="
  cat "$JIT_DIR/exports.txt"
  echo "=== TCI exports ==="
  cat "$TCI_DIR/exports.txt"
} > "$TEMP_OUT/exports.txt"
for report in runtime-file-inventory.txt dependency-report.txt; do
  : > "$TEMP_OUT/$report"
  for package in "$JIT_DIR" "$TCI_DIR"; do
    if [[ -f "$package/$report" ]]; then
      echo "=== $package ===" >> "$TEMP_OUT/$report"
      cat "$package/$report" >> "$TEMP_OUT/$report"
    fi
  done
done

[[ -f "$TEMP_OUT/$jit_library" && -f "$TEMP_OUT/$tci_library_merged" ]] || fail "merged runtime libraries are missing"
[[ ! -L "$OUT" && ( ! -e "$OUT" || -d "$OUT" ) ]] || fail "output path changed during merge"
rm -rf "$OUT"
mv "$TEMP_OUT" "$OUT"
TEMP_OUT=""
echo "Merged JIT and no-JIT TCI runtime variants from UTM $jit_revision."
