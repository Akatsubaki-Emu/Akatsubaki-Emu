#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.0.1"
ARCHIVE="$ROOT/Vendor/StikJIT.xcframework.zip"
DESTINATION="$ROOT/Vendor/StikJIT.xcframework"
VERSION_MARKER="$ROOT/Vendor/StikJIT.xcframework.version"
URL="https://github.com/StikDebug/StikJIT/releases/download/$VERSION/StikJIT.xcframework.zip"
EXPECTED_SHA256="c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95"
mkdir -p "$ROOT/Vendor"
if [[ -d "$DESTINATION" && -f "$VERSION_MARKER" && "$(cat "$VERSION_MARKER")" == "$VERSION" ]]; then plutil -lint "$DESTINATION/Info.plist"; exit 0; fi
rm -rf "$DESTINATION"
curl --fail --location --retry 3 --retry-all-errors "$URL" --output "$ARCHIVE"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then echo "StikJIT checksum mismatch: $ACTUAL_SHA256" >&2; exit 1; fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
unzip -q "$ARCHIVE" -d "$TEMP_DIR"
FRAMEWORK="$(find "$TEMP_DIR" -maxdepth 4 -type d -name 'StikJIT.xcframework' -print -quit)"
if [[ -z "$FRAMEWORK" ]]; then echo "Pinned archive did not contain StikJIT.xcframework." >&2; exit 1; fi
mv "$FRAMEWORK" "$DESTINATION"
echo "$VERSION" > "$VERSION_MARKER"
plutil -lint "$DESTINATION/Info.plist"
