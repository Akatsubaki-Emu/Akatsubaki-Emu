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
if ! otool -l "$BINARY" | grep -A5 'LC_BUILD_VERSION' | grep -q 'platform IOS'; then
  echo 'App executable is not built for the iOS device platform.' >&2
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
printf 'QEMU runtime: absent (expected)\n'
printf 'Provisioning profile: absent (unsigned; sign with SideStore)\n'
