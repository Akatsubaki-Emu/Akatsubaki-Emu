#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /path/to/signed/manifest-selected-QEMU-library [jit|tci]" >&2
  exit 64
fi

library="$1"
mode="${2:-jit}"
case "$mode" in
  jit|tci) ;;
  *) echo "Runtime mode must be jit or tci: $mode" >&2; exit 64 ;;
esac
[[ -f "$library" ]] || { echo "Missing runtime library: $library" >&2; exit 2; }

for tool in file lipo nm codesign vtool; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Required Apple validation tool is unavailable: $tool" >&2
    exit 4
  }
done

echo "== File type =="
file_description="$(file "$library")"
printf '%s\n' "$file_description"
if [[ "$file_description" != *"Mach-O"* || "$file_description" != *"dynamically linked shared library"* ]]; then
  echo "Runtime is not a Mach-O dynamic library." >&2
  exit 3
fi

echo "== Device architecture =="
architectures="$(lipo -archs "$library")"
printf '%s\n' "$architectures"
case " $architectures " in
  *" arm64 "*) ;;
  *)
    echo "Runtime does not contain the physical iOS arm64 architecture: $architectures" >&2
    exit 3
    ;;
esac

echo "== Mach-O build platform =="
build_info="$(vtool -show-build "$library")"
printf '%s\n' "$build_info"
if ! grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<<"$build_info"; then
  echo "Runtime is not built for physical iOS." >&2
  exit 3
fi

echo "== Defined external lifecycle and mode-specific symbols =="
# -U excludes undefined imports. TCI deliberately has no StikJIT callback.
symbols="$(nm -gU "$library")"
required_symbols=(qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request)
if [[ "$mode" == "jit" ]]; then
  required_symbols+=(isteam_qemu_set_jit_callbacks)
fi
for symbol in "${required_symbols[@]}"; do
  if ! grep -Eq "[[:space:]][A-Za-z][[:space:]]_?${symbol}$" <<<"$symbols"; then
    echo "Missing required defined export for $mode mode: $symbol" >&2
    exit 3
  fi
  echo "Found required export: $symbol"
done

echo "== Code signature =="
codesign --verify --strict "$library"

echo "QEMU $mode runtime dynamic-library type, iOS platform, arm64 architecture, required lifecycle/shutdown exports, mode-specific JIT policy, and code signature verified."
echo "This does not prove dependent libraries load or that a guest boots."
