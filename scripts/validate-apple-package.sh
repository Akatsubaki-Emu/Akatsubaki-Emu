#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <archive.ipa> <expected-app.app> <expected-bundle-id>" >&2
  exit 2
fi

archive="$1"
app_name="$2"
expected_bundle="$3"

case "$app_name" in
  ""|.|..|*/*)
    echo "Invalid app bundle name: $app_name" >&2
    exit 1
    ;;
esac

test -s "$archive"
listing="$(unzip -Z1 "$archive")"
printf '%s\n' "$listing" | grep -Fx "Payload/$app_name/Info.plist" >/dev/null || {
  echo "Invalid Apple package: Payload/$app_name/Info.plist is missing." >&2
  printf '%s\n' "$listing" | sed -n '1,40p' >&2
  exit 1
}

plist="$(mktemp)"
executable="$(mktemp)"
trap 'rm -f "$plist" "$executable" "$TMPDIR/akatsubaki-JIT-manifest" "$TMPDIR/akatsubaki-JIT-exports" "$TMPDIR/akatsubaki-JIT-library" "$TMPDIR/akatsubaki-TCI-manifest" "$TMPDIR/akatsubaki-TCI-exports" "$TMPDIR/akatsubaki-TCI-library"' EXIT
unzip -p "$archive" "Payload/$app_name/Info.plist" > "$plist"

actual_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
if [ "$actual_bundle" != "$expected_bundle" ]; then
  echo "Bundle ID mismatch: expected $expected_bundle, found $actual_bundle" >&2
  exit 1
fi

actual_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")"
if [ "$actual_package_type" != "APPL" ]; then
  echo "Invalid app package type: expected APPL, found $actual_package_type" >&2
  exit 1
fi

actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
case "$actual_executable" in
  ""|.|..|*/*|*\\*)
    echo "Invalid app executable name: $actual_executable" >&2
    exit 1
    ;;
esac

executable_path="Payload/$app_name/$actual_executable"
printf '%s\n' "$listing" | grep -Fx "$executable_path" >/dev/null || {
  echo "Invalid Apple package: $executable_path is missing." >&2
  exit 1
}

unzip -p "$archive" "$executable_path" > "$executable"
test -s "$executable" || {
  echo "Invalid Apple package: $executable_path is empty." >&2
  exit 1
}

if ! file "$executable" | grep -q "Mach-O"; then
  echo "Invalid Apple package: $executable_path is not a Mach-O executable." >&2
  exit 1
fi

lipo -verify_arch arm64 "$executable" >/dev/null 2>&1 || {
  echo "Invalid Apple package: $executable_path does not contain arm64." >&2
  exit 1
}

validate_runtime_variant() {
  local mode="$1"
  local manifest_path="$2"
  local exports_path="$3"
  local expected_prefix="$4"
  local require_jit_callback="$5"
  local manifest_tmp="$TMPDIR/akatsubaki-${mode,,}-manifest"
  local exports_tmp="$TMPDIR/akatsubaki-${mode,,}-exports"
  local library_tmp="$TMPDIR/akatsubaki-${mode,,}-library"
  local relative_path

  printf '%s\n' "$listing" | grep -Fx "Payload/$app_name/$manifest_path" >/dev/null || {
    echo "Invalid Apple package: $mode runtime manifest is missing: $manifest_path" >&2
    return 1
  }
  printf '%s\n' "$listing" | grep -Fx "Payload/$app_name/$exports_path" >/dev/null || {
    echo "Invalid Apple package: $mode export manifest is missing: $exports_path" >&2
    return 1
  }
  unzip -p "$archive" "Payload/$app_name/$manifest_path" > "$manifest_tmp"
  unzip -p "$archive" "Payload/$app_name/$exports_path" > "$exports_tmp"
  relative_path="$(head -n 1 "$manifest_tmp")"
  case "$relative_path" in
    "$expected_prefix"*) ;;
    *) echo "Invalid Apple package: unexpected $mode runtime path: $relative_path" >&2; return 1 ;;
  esac
  case "/$relative_path/" in
    *"/../"*|*"/./"*) echo "Invalid Apple package: unsafe $mode runtime path: $relative_path" >&2; return 1 ;;
  esac
  printf '%s\n' "$listing" | grep -Fx "Payload/$app_name/$relative_path" >/dev/null || {
    echo "Invalid Apple package: $mode runtime library is missing: $relative_path" >&2
    return 1
  }
  for symbol in qemu_init qemu_main_loop qemu_cleanup qemu_system_shutdown_request; do
    grep -Eq " _?${symbol}$" "$exports_tmp" || {
      echo "Invalid Apple package: $mode runtime is missing export $symbol" >&2
      return 1
    }
  done
  if [ "$require_jit_callback" = "yes" ]; then
    grep -Eq ' _?isteam_qemu_set_jit_callbacks
 "$exports_tmp" || {
      echo "Invalid Apple package: JIT runtime callback export is missing." >&2
      return 1
    }
  elif grep -Eq ' _?isteam_qemu_set_jit_callbacks
 "$exports_tmp"; then
    echo "Invalid Apple package: TCI runtime unexpectedly exports the JIT callback." >&2
    return 1
  fi
  unzip -p "$archive" "Payload/$app_name/$relative_path" > "$library_tmp"
  file "$library_tmp" | grep -q "Mach-O" || {
    echo "Invalid Apple package: $mode runtime is not a Mach-O library." >&2
    return 1
  }
  lipo -verify_arch arm64 "$library_tmp" >/dev/null 2>&1 || {
    echo "Invalid Apple package: $mode runtime does not contain arm64." >&2
    return 1
  }
  rm -f "$manifest_tmp" "$exports_tmp" "$library_tmp"
}

validate_runtime_variant "JIT" "QEMU/runtime-library-path.txt" "QEMU/JIT/exports.txt" "Frameworks/" "yes"
validate_runtime_variant "TCI" "QEMU/TCI/runtime-library-path.txt" "QEMU/TCI/exports.txt" "Frameworks/TCI/" "no"

printf 'Package OK: %s (%s, arm64)\n' "$app_name" "$actual_bundle"
