#!/usr/bin/env bash
set -euo pipefail

IPA="${1:-}"
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "Usage: $0 path/to/Akatsubaki-Emu-CoreOnly-iOS.ipa" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/akatsubaki-core-ipa.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

unzip -t "$IPA" >/dev/null
unzip -q "$IPA" -d "$WORK"
APP_COUNT="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" -ne 1 ]]; then
  echo "Expected exactly one app under Payload; found $APP_COUNT." >&2
  exit 1
fi
APP="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
INFO="$APP/Info.plist"
[[ -f "$INFO" ]] || { echo 'Info.plist missing.' >&2; exit 1; }
plutil -lint "$INFO" >/dev/null
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
EXECUTABLE="$("$PLIST_BUDDY" -c 'Print :CFBundleExecutable' "$INFO")"
BUNDLE_ID="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$INFO")"
MINIMUM_OS="$("$PLIST_BUDDY" -c 'Print :MinimumOSVersion' "$INFO")"
BINARY="$APP/$EXECUTABLE"
[[ -n "$BUNDLE_ID" && -f "$BINARY" ]] || { echo 'App identity or executable missing.' >&2; exit 1; }
lipo -verify_arch arm64 "$BINARY"
SUPPORTED_PLATFORM="$("$PLIST_BUDDY" -c 'Print :CFBundleSupportedPlatforms:0' "$INFO" 2>/dev/null || true)"
if [[ "$SUPPORTED_PLATFORM" != "iPhoneOS" ]]; then
  echo "Expected iPhoneOS in CFBundleSupportedPlatforms; found '${SUPPORTED_PLATFORM:-missing}'." >&2
  exit 1
fi
BUILD_PLATFORM="$(otool -l "$BINARY" | awk '
  $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
  in_build && $1 == "platform" { print $2; exit }
  in_build && $1 == "Load" && $2 == "command" { exit }
')"
if [[ "$BUILD_PLATFORM" != "IOS" && "$BUILD_PLATFORM" != "2" ]]; then
  echo "Expected Mach-O iOS device platform (IOS/2); found '${BUILD_PLATFORM:-missing}'." >&2
  otool -l "$BINARY" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { show = 1 }
    show { print }
    show && $1 == "ntools" { exit }
  ' >&2
  exit 1
fi

# A core-only IPA must not accidentally bundle any QEMU engine, firmware or manifest.
if find "$APP" -print | grep -Eiq '(^|/)(QEMU[^/]*\.framework|QEMU[^/]*\.dylib|QEMU|libqemu[^/]*|qemu-system-[^/]*|QEMU[-_].*manifest[^/]*|QEMU_EFI[^/]*)($|/)'; then
  echo 'QEMU runtime content found in a core-only IPA.' >&2
  find "$APP" -print | grep -Ei 'QEMU|libqemu|qemu-system' >&2 || true
  exit 1
fi
if otool -L "$BINARY" | grep -Eiq 'QEMU\.framework|QEMU-TCI|QEMU-JIT|libqemu'; then
  echo 'App executable links against a QEMU runtime.' >&2
  exit 1
fi
if [[ -e "$APP/embedded.mobileprovision" ]]; then
  echo 'Expected an unsigned IPA, but an embedded provisioning profile was found.' >&2
  exit 1
fi

printf 'Core-only IPA validation: PASS\n'
printf 'Bundle ID: %s\n' "$BUNDLE_ID"
printf 'Minimum iOS: %s\n' "$MINIMUM_OS"
printf 'Architecture: arm64\n'
printf 'Device platform: %s (Mach-O %s)\n' "$SUPPORTED_PLATFORM" "$BUILD_PLATFORM"
printf 'QEMU runtime: absent (expected)\n'
printf 'Provisioning profile: absent (unsigned; sign with SideStore)\n'
