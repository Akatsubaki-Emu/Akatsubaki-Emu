#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
if [[ "$XCODE_VERSION" != "27.1" ]]; then echo "StikJIT helper builds require Xcode 27.1; found $XCODE_VERSION." >&2; exit 1; fi
bash "$ROOT/scripts/prepare_stikjit.sh"
xcodegen generate --spec "$ROOT/project-stikjit-helper.yml"
for SDK in iphoneos iphonesimulator; do
 if [[ "$SDK" == "iphoneos" ]]; then DESTINATION="generic/platform=iOS"; else DESTINATION="generic/platform=iOS Simulator"; fi
 DERIVED="$ROOT/build/StikJITHelper/$SDK"
 xcodebuild -project "$ROOT/AkatsubakiJITHelpers.xcodeproj" -scheme AkatsubakiJITHelpers -configuration Release -sdk "$SDK" -destination "$DESTINATION" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build
 PRODUCT_DIR="$DERIVED/Build/Products/Release-$SDK"
 OUTPUT_DIR="$ROOT/Vendor/Helpers/$SDK"
 mkdir -p "$OUTPUT_DIR"
 for PRODUCT in AkatsubakiJITHelper.appex AkatsubakiJITHelperNightly.appex; do
  if [[ ! -d "$PRODUCT_DIR/$PRODUCT" ]]; then echo "Missing helper product: $PRODUCT_DIR/$PRODUCT" >&2; exit 1; fi
  rm -rf "$OUTPUT_DIR/$PRODUCT"; cp -R "$PRODUCT_DIR/$PRODUCT" "$OUTPUT_DIR/$PRODUCT"
  test -d "$OUTPUT_DIR/$PRODUCT/Frameworks/StikJIT.framework"
 done
done
