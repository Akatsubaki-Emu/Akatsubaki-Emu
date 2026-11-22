#!/bin/bash
set -euo pipefail
VERSION="2.0.1"
SHA256="c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95"
URL="https://github.com/StikDebug/StikJIT/releases/download/${VERSION}/StikJIT.xcframework.zip"
DEPENDENCIES_DIR="build/dependencies"
ARCHIVE="${DEPENDENCIES_DIR}/StikJIT-${VERSION}.zip"
DESTINATION="${DEPENDENCIES_DIR}/StikJIT.xcframework"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/akatsubaki-stikjit.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}" "${ARCHIVE}"' EXIT
mkdir -p "${DEPENDENCIES_DIR}"
curl --fail --location --retry 3 --retry-delay 2 "${URL}" --output "${ARCHIVE}"
printf '%s  %s\n' "${SHA256}" "${ARCHIVE}" | shasum -a 256 -c
unzip -q "${ARCHIVE}" -d "${TEMP_DIR}"
FRAMEWORK_PATH="$(find "${TEMP_DIR}" -type d -name StikJIT.xcframework -print -quit)"
test -n "${FRAMEWORK_PATH}" || { echo "StikJIT XCFramework archive did not contain StikJIT.xcframework." >&2; exit 1; }
test -f "${FRAMEWORK_PATH}/Info.plist" || { echo "StikJIT XCFramework is missing Info.plist." >&2; exit 1; }
rm -rf "${DESTINATION}"
mv "${FRAMEWORK_PATH}" "${DESTINATION}"
echo "Verified StikJIT ${VERSION} (${SHA256}) at ${DESTINATION}"
