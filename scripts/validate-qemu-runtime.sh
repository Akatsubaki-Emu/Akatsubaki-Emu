#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/manifest-selected-QEMU-library [jit|tci] [signed|allow-unsigned]" >&2
  exit 64
fi
library="$1"
mode="${2:-jit}"
signature_policy="${3:-signed}"
case "$mode" in jit|tci) ;; *) echo "Runtime mode must be jit or tci: $mode" >&2; exit 64 ;; esac
case "$signature_policy" in signed|allow-unsigned) ;; *) echo "Signature policy must be signed or allow-unsigned: $signature_policy" >&2; exit 64 ;; esac
[[ -f "$library" ]] || { echo "Missing runtime library: $library" >&2; exit 2; }
for tool in file lipo nm codesign vtool; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required Apple validation tool is unavailable: $tool" >&2; exit 4; }
done
echo "== File type =="
file_description="$(file "$library")"
printf '%s\n' "$file_description"
if [[ "$file_description" != *"Mach-O"* || "$file_description" != *"dynamically linked shared library"* ]]; then
  echo "Runtime is not a Mach-O dynamic library." >&2; exit 3
fi
echo "== Device architecture =="
architectures="$(lipo -archs "$library")"
printf '%s\n' "$architectures"
case " $architectures " in *" arm64 "*) ;; *) echo "Runtime does not contain physical iOS arm64: $architectures" >&2; exit 3 ;; esac
echo "== Mach-O build platform =="
build_info="$(vtool -show-build "$library")"
printf '%s\n' "$build_info"
if ! grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<<"$build_info"; then
  echo "Runtime is not built for physical iOS." >&2; exit 3
fi
echo "== Defined external lifecycle and mode-specific symbols =="
symbols="$(nm -gU "$library")"
required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)
if [[ "$mode" == "jit" ]]; then required_symbols+=(isteam_qemu_set_jit_callbacks); fi
for symbol in "${required_symbols[@]}"; do
  if ! grep -Eq "[[:space:]][A-Za-z][[:space:]]_?${symbol}$" <<<"$symbols"; then
    echo "Missing required defined export for $mode mode: $symbol" >&2; exit 3
  fi
  echo "Found required export: $symbol"
done
if [[ "$mode" == "tci" ]] && grep -Eq '[[:space:]][A-Za-z][[:space:]]_?isteam_qemu_set_jit_callbacks$' <<<"$symbols"; then
  echo "TCI runtime must not export the StikJIT callback." >&2; exit 3
fi
echo "== Code signature =="
if codesign --verify --strict "$library" >/dev/null 2>&1; then
  echo "Existing code signature verified."
else
  signature_details="$(codesign -dv --verbose=2 "$library" 2>&1 || true)"
  if [[ "$signature_policy" == "allow-unsigned" ]] && grep -Fq "code object is not signed at all" <<<"$signature_details"; then
    echo "Unsigned CI runtime accepted; final app/sideload signing must sign nested code."
  else
    printf '%s\n' "$signature_details" >&2
    echo "Runtime code signature is invalid or missing under '$signature_policy'." >&2; exit 4
  fi
fi
echo "QEMU $mode runtime architecture, iOS platform, lifecycle/shutdown exports and mode-specific JIT policy verified."
echo "This does not prove dependent libraries load or that a guest boots."
