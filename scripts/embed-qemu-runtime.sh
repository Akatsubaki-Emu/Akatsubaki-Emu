#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "QEMU runtime embedding failed: $*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/merged-runtime /path/to/iSteam.app" >&2
  exit 64
fi

RUNTIME_DIR="$1"
APP_DIR="$2"
[[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]] || fail "runtime directory is missing or unsafe"
[[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] || fail "app bundle directory is missing or unsafe"
RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd -P)"
APP_DIR="$(cd "$APP_DIR" && pwd -P)"
[[ -d "$RUNTIME_DIR/Frameworks" && ! -L "$RUNTIME_DIR/Frameworks" ]] || fail "Frameworks directory is missing or unsafe"
[[ -d "$RUNTIME_DIR/QEMU" && ! -L "$RUNTIME_DIR/QEMU" ]] || fail "QEMU data directory is missing or unsafe"

has_export() {
  local report="$1" symbol="$2"
  grep -Eq "[[:space:]][A-Za-z][[:space:]]_?${symbol}$" "$report"
}

validate_mode() {
  local mode="$1"
  local mode_dir="$RUNTIME_DIR/QEMU/$mode"
  local manifest="$mode_dir/runtime-library-path.txt"
  local exports="$mode_dir/exports.txt"
  [[ -d "$mode_dir" && ! -L "$mode_dir" ]] || fail "$mode mode data directory is missing or unsafe"
  [[ -s "$manifest" && ! -L "$manifest" ]] || fail "$mode runtime-library-path.txt is missing or unsafe"
  [[ -s "$exports" && ! -L "$exports" ]] || fail "$mode exports.txt is missing or unsafe"

  local relative_path
  IFS= read -r relative_path < "$manifest" || true
  relative_path="$(printf '%s' "$relative_path" | tr -d '\r')"
  [[ -n "$relative_path" ]] || fail "$mode runtime library manifest is empty"
  case "$relative_path" in
    Frameworks/*) ;;
    *) fail "$mode runtime path must be inside Frameworks/: $relative_path" ;;
  esac
  case "$relative_path" in
    *\\*) fail "$mode runtime path contains a backslash" ;;
  esac
  local part
  IFS='/' read -r -a path_parts <<< "$relative_path"
  for part in "${path_parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || fail "$mode runtime path contains an unsafe component"
  done

  local library="$RUNTIME_DIR/$relative_path"
  python3 - "$RUNTIME_DIR" "$library" "$mode" <<'PY'
import os
import sys
root = os.path.realpath(sys.argv[1])
library = os.path.realpath(sys.argv[2])
mode = sys.argv[3]
try:
    inside = os.path.commonpath((root, library)) == root
except ValueError:
    inside = False
if not inside or not os.path.isfile(library) or os.path.getsize(library) == 0:
    print(f"QEMU runtime embedding failed: {mode} library is missing or resolves outside the runtime package", file=sys.stderr)
    raise SystemExit(1)
PY

  local symbol
  for symbol in qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request; do
    has_export "$exports" "$symbol" || fail "$mode runtime is missing required export: $symbol"
  done
  if [[ "$mode" == "JIT" ]]; then
    has_export "$exports" "isteam_qemu_set_jit_callbacks" || fail "JIT runtime is missing the StikJIT callback export"
    JIT_RUNTIME_REL="$relative_path"
  else
    if has_export "$exports" "isteam_qemu_set_jit_callbacks"; then
      fail "TCI runtime unexpectedly exports the StikJIT callback"
    fi
    TCI_RUNTIME_REL="$relative_path"
  fi
}

# The merged artifact intentionally has one manifest per accelerator mode.
# Do not depend on the retired root QEMU/runtime-library-path.txt contract.
validate_mode JIT
validate_mode TCI

MODE_MANIFEST="$RUNTIME_DIR/QEMU/runtime-mode-manifest.txt"
[[ -s "$MODE_MANIFEST" && ! -L "$MODE_MANIFEST" ]] || fail "combined runtime-mode-manifest.txt is missing or unsafe"
combined_jit="$(sed -n 's/^JIT=//p' "$MODE_MANIFEST")"
combined_tci="$(sed -n 's/^TCI=//p' "$MODE_MANIFEST")"
[[ "$combined_jit" == "$JIT_RUNTIME_REL" ]] || fail "combined JIT manifest does not match the JIT mode manifest"
[[ "$combined_tci" == "$TCI_RUNTIME_REL" ]] || fail "combined TCI manifest does not match the TCI mode manifest"

for destination in Frameworks QEMU; do
  [[ ! -L "$APP_DIR/$destination" ]] || fail "app bundle $destination destination is a symlink"
  [[ ! -e "$APP_DIR/$destination" || -d "$APP_DIR/$destination" ]] || fail "app bundle $destination destination is not a directory"
done
mkdir -p "$APP_DIR/Frameworks" "$APP_DIR/QEMU"
cp -R "$RUNTIME_DIR/Frameworks/." "$APP_DIR/Frameworks/"
cp -R "$RUNTIME_DIR/QEMU/." "$APP_DIR/QEMU/"

[[ -s "$APP_DIR/QEMU/runtime-mode-manifest.txt" ]] || fail "embedded combined runtime-mode-manifest.txt is missing"
for mode in JIT TCI; do
  manifest="$APP_DIR/QEMU/$mode/runtime-library-path.txt"
  exports="$APP_DIR/QEMU/$mode/exports.txt"
  [[ -s "$manifest" && -s "$exports" ]] || fail "embedded $mode manifests are missing"
  relative_path="$(head -n 1 "$manifest" | tr -d '\r')"
  case "$relative_path" in
    Frameworks/*) ;;
    *) fail "embedded $mode runtime path is invalid: $relative_path" ;;
  esac
  [[ -s "$APP_DIR/$relative_path" ]] || fail "embedded $mode library is missing: $relative_path"
  python3 - "$APP_DIR" "$APP_DIR/$relative_path" "$mode" <<'PY'
import os
import sys
root = os.path.realpath(sys.argv[1])
library = os.path.realpath(sys.argv[2])
mode = sys.argv[3]
try:
    inside = os.path.commonpath((root, library)) == root
except ValueError:
    inside = False
if not inside or not os.path.isfile(library) or os.path.getsize(library) == 0:
    print(f"QEMU runtime embedding failed: embedded {mode} library is missing or resolves outside the app bundle", file=sys.stderr)
    raise SystemExit(1)
PY
  [[ -n "$(find "$APP_DIR/QEMU/$mode" -type f -size +0c -print -quit)" ]] || fail "embedded $mode QEMU data files are missing"
done
embedded_jit="$(sed -n 's/^JIT=//p' "$APP_DIR/QEMU/runtime-mode-manifest.txt")"
embedded_tci="$(sed -n 's/^TCI=//p' "$APP_DIR/QEMU/runtime-mode-manifest.txt")"
[[ "$embedded_jit" == "$JIT_RUNTIME_REL" && "$embedded_tci" == "$TCI_RUNTIME_REL" ]] || fail "embedded combined runtime manifest does not match the embedded mode manifests"

echo "Embedded both JIT and no-JIT TCI QEMU runtimes with mode-specific manifests and exports."
