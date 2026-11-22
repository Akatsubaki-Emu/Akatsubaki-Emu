#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then echo "Usage: $0 /path/to/manifest-selected-QEMU-library" >&2; exit 64; fi
library="$1"
[[ -f "$library" ]] || { echo "Missing runtime library: $library" >&2; exit 2; }
for tool in file lipo nm codesign vtool; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required Apple validation tool is unavailable: $tool" >&2; exit 4; }
done
file_description="$(file "$library")"
printf '%s\n' "$file_description"
if [[ "$file_description" != *"Mach-O"* || "$file_description" != *"dynamically linked shared library"* ]]; then echo "Runtime is not a Mach-O dynamic library." >&2; exit 3; fi
architectures="$(lipo -archs "$library")"
printf '%s\n' "$architectures"
case " $architectures " in *" arm64 "*) ;; *) echo "Runtime does not contain physical iOS arm64: $architectures" >&2; exit 3 ;; esac
build_info="$(vtool -show-build "$library")"
printf '%s\n' "$build_info"
if ! grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<<"$build_info"; then echo "Runtime is not built for physical iOS." >&2; exit 3; fi
symbols="$(nm -gU "$library")"
for symbol in qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request isteam_qemu_set_jit_callbacks; do
  if ! grep -Eq "[[:space:]][A-Za-z][[:space:]]_?${symbol}$" <<<"$symbols"; then echo "Missing required defined export: $symbol" >&2; exit 3; fi
done
codesign --verify --strict "$library"
echo "QEMU runtime dynamic-library type, iOS platform, arm64 architecture, required lifecycle/shutdown/JIT exports, and code signature verified."
echo "This does not prove dependent libraries load or that a guest boots."
