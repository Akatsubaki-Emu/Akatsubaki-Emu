#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT/Icons"
DEST_DIR="$ROOT/iSteam/Icons"

extract_icon() {
  local archive="$1"
  local icon_name="$2"
  local temporary
  local source_icon

  test -s "$SOURCE_DIR/$archive" || {
    echo "Missing Icon Composer archive: $SOURCE_DIR/$archive" >&2
    return 1
  }

  temporary="$(mktemp -d)"
  (
    trap 'rm -rf "$temporary"' EXIT
    unzip -tq "$SOURCE_DIR/$archive" >/dev/null
    unzip -q "$SOURCE_DIR/$archive" -d "$temporary"
    source_icon="$(find "$temporary" -type d -name '*.icon' -print -quit)"
    test -n "$source_icon" || {
      echo "Archive does not contain an Icon Composer .icon package: $archive" >&2
      exit 1
    }
    test -s "$source_icon/icon.json" || {
      echo "Icon Composer metadata is missing from $archive" >&2
      exit 1
    }
    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_DIR/$icon_name.icon"
    mv "$source_icon" "$DEST_DIR/$icon_name.icon"
  )
}

extract_icon "Akatsubaki emu default icon .icon.zip" "AkatsubakiDefault"
extract_icon "Akatsubaki emu halo-petals icon.icon.zip" "AkatsubakiHaloPetals"
extract_icon "Akatsubaki emu petals icon .icon.zip" "AkatsubakiPetals"
extract_icon "Akatsubaki emu simple icon .icon.zip" "AkatsubakiSimple"

for icon in AkatsubakiDefault AkatsubakiHaloPetals AkatsubakiPetals AkatsubakiSimple; do
  test -s "$DEST_DIR/$icon.icon/icon.json"
done

echo "Prepared all four Icon Composer packages for XcodeGen."
