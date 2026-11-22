#!/usr/bin/env bash
set -euo pipefail
APP_PATH="$1"
HOST_BUNDLE_ID="$2"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
case "$HOST_BUNDLE_ID" in
 com.xthrx.isteam) HELPER_NAME="AkatsubakiJITHelper.appex" ;;
 com.xthrx.isteam.nightly) HELPER_NAME="AkatsubakiJITHelperNightly.appex" ;;
 *) echo "Unsupported host bundle identifier: $HOST_BUNDLE_ID" >&2; exit 1 ;;
esac
HELPER_PATH="$APP_PATH/Extensions/$HELPER_NAME"
HELPER_PLIST="$HELPER_PATH/Info.plist"
HOST_PLIST="$APP_PATH/Info.plist"
test -d "$APP_PATH" && test -d "$HELPER_PATH" && test -f "$HELPER_PLIST"
test -d "$HELPER_PATH/Frameworks/StikJIT.framework"
HELPER_BUNDLE_ID="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$HELPER_PLIST")"
POINT_ID="$("$PLIST_BUDDY" -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$HELPER_PLIST")"
EXECUTABLE="$("$PLIST_BUDDY" -c 'Print :CFBundleExecutable' "$HELPER_PLIST")"
[[ "$HELPER_BUNDLE_ID" == "$HOST_BUNDLE_ID.jit-helper" ]]
[[ "$POINT_ID" == "$HOST_BUNDLE_ID.AkatsubakiJITHelper" ]]
test -f "$HELPER_PATH/$EXECUTABLE"
"$PLIST_BUDDY" -c 'Print :NSLocalNetworkUsageDescription' "$HOST_PLIST" >/dev/null
"$PLIST_BUDDY" -c 'Print :NSBonjourServices:0' "$HELPER_PLIST" | grep -q '_remotepairing._tcp'
APPEXPT="$(find "$APP_PATH/Extensions" -maxdepth 1 -name '*.appexpt' -print -quit)"
if [[ -z "$APPEXPT" ]]; then echo "Missing ExtensionKit point definition (.appexpt)." >&2; exit 1; fi
echo "Embedded StikJIT helper validated: $HELPER_BUNDLE_ID"
