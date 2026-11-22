#!/usr/bin/env bash
set -euo pipefail

JIT_DIR="${1:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"
TCI_DIR="${2:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"
OUT_REQUEST="${3:?usage: merge-qemu-runtime-variants.sh <jit-package> <tci-package> <build/output-name>}"

fail() { echo "QEMU runtime merge failed: $*" >&2; exit 1; }

case "$OUT_REQUEST" in
  build/*) OUT="$PWD/$OUT_REQUEST" ;;
  *) fail "output must be a named child of build/: $OUT_REQUEST" ;;
esac
BUILD_ROOT="$PWD/build"
mkdir -p "$BUILD_ROOT"
[[ ! -L "$BUILD_ROOT" && "$(cd "$BUILD_ROOT" && pwd -P)" == "$BUILD_ROOT" ]] || fail "unsafe build directory"
[[ ! -L "$OUT" ]] || fail "refusing symlink output directory: $OUT"
[[ "$OUT" != "$JIT_DIR" && "$OUT" != "$TCI_DIR" ]] || fail "output must differ from input packages"

for package in "$JIT_DIR" "$TCI_DIR"; do
  [[ -d "$package/Frameworks" && -d "$package/QEMU" ]] || fail "incomplete package: $package"
  [[ -s "$package/UTM-SOURCE-REVISION.txt" ]] || fail "missing UTM source revision: $package"
  [[ -s "$package/QEMU/runtime-library-path.txt" ]] || fail "missing runtime library manifest: $package"
  [[ -s "$package/exports.txt" ]] || fail "missing exports report: $package"
done

jit_revision="$(tr -d '\r\n' < "$JIT_DIR/UTM-SOURCE-REVISION.txt")"
tci_revision="$(tr -d '\r\n' < "$TCI_DIR/UTM-SOURCE-REVISION.txt")"
[[ -n "$jit_revision" && "$jit_revision" == "$tci_revision" ]] || fail "JIT and TCI artifacts were built from different UTM revisions"

grep -q 'isteam_qemu_set_jit_callbacks' "$JIT_DIR/exports.txt" || fail "JIT artifact is missing the StikJIT callback export"
if grep -q 'isteam_qemu_set_jit_callbacks' "$TCI_DIR/exports.txt"; then
  fail "TCI artifact unexpectedly contains the StikJIT callback export"
fi

safe_relative_path() {
  case "$1" in
    ""|/*|../*|*/../*|*/..|*\\*) return 1 ;;
  esac
}
jit_library="$(tr -d '\r\n' < "$JIT_DIR/QEMU/runtime-library-path.txt")"
tci_library="$(tr -d '\r\n' < "$TCI_DIR/QEMU/runtime-library-path.txt")"
safe_relative_path "$jit_library" || fail "unsafe JIT library path in manifest"
safe_relative_path "$tci_library" || fail "unsafe TCI library path in manifest"
[[ -f "$JIT_DIR/$jit_library" ]] || fail "JIT library missing from package: $jit_library"
[[ -f "$TCI_DIR/$tci_library" ]] || fail "TCI library missing from package: $tci_library"

rm -rf "$OUT"
mkdir -p "$OUT/Frameworks" "$OUT/QEMU/JIT" "$OUT/QEMU/TCI"

merge_framework_tree() {
  local source_root="$1" destination_root="$2" entry relative target
  while IFS= read -r -d '' entry; do
    relative="${entry#"$source_root"/}"
    target="$destination_root/$relative"
    if [[ -L "$entry" ]]; then
      if [[ -e "$target" || -L "$target" ]]; then
        [[ -L "$target" && "$(readlink "$entry")" == "$(readlink "$target")" ]] || fail "conflicting framework symlink: $relative"
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

merge_framework_tree "$JIT_DIR/Frameworks" "$OUT/Frameworks"
merge_framework_tree "$TCI_DIR/Frameworks" "$OUT/Frameworks"
cp -a "$JIT_DIR/QEMU/." "$OUT/QEMU/JIT/"
cp -a "$TCI_DIR/QEMU/." "$OUT/QEMU/TCI/"
cp "$JIT_DIR/exports.txt" "$OUT/QEMU/JIT/exports.txt"
cp "$TCI_DIR/exports.txt" "$OUT/QEMU/TCI/exports.txt"
cp "$JIT_DIR/UTM-SOURCE-REVISION.txt" "$OUT/UTM-SOURCE-REVISION.txt"
cp "$JIT_DIR/UTM-archive-Info.plist" "$OUT/UTM-JIT-archive-Info.plist" 2>/dev/null || true
cp "$TCI_DIR/UTM-archive-Info.plist" "$OUT/UTM-TCI-archive-Info.plist" 2>/dev/null || true

{
  echo "JIT=$jit_library"
  echo "TCI=$tci_library"
  echo "UTM_REVISION=$jit_revision"
} > "$OUT/QEMU/runtime-mode-manifest.txt"
{
  echo "=== JIT runtime ==="
  cat "$JIT_DIR/BUILD-INFO.txt" 2>/dev/null || true
  echo "=== TCI runtime ==="
  cat "$TCI_DIR/BUILD-INFO.txt" 2>/dev/null || true
} > "$OUT/BUILD-INFO.txt"
{
  echo "=== JIT exports ==="
  cat "$JIT_DIR/exports.txt"
  echo "=== TCI exports ==="
  cat "$TCI_DIR/exports.txt"
} > "$OUT/exports.txt"
for report in runtime-file-inventory.txt dependency-report.txt; do
  : > "$OUT/$report"
  for package in "$JIT_DIR" "$TCI_DIR"; do
    if [[ -f "$package/$report" ]]; then
      echo "=== $package ===" >> "$OUT/$report"
      cat "$package/$report" >> "$OUT/$report"
    fi
  done
done

[[ -f "$OUT/$jit_library" && -f "$OUT/$tci_library" ]] || fail "merged runtime libraries are missing"
echo "Merged JIT and no-JIT TCI runtime variants from UTM $jit_revision."
