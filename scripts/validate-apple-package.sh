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
trap 'rm -f "$plist" "$executable"' EXIT
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

printf 'Package OK: %s (%s, arm64)\n' "$app_name" "$actual_bundle"
