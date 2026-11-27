#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEX_PIN="1dc6ed4932bd231df1c53dd7b8043ffdee0ac34a"
FEX_SOURCE_DIR="${FEX_SOURCE_DIR:-$ROOT/build/third_party/FEX}"
FEX_BUILD_DIR="${FEX_BUILD_DIR:-$ROOT/build/fexcore-ios}"
FEX_DIST_DIR="${FEX_DIST_DIR:-$ROOT/build/fexcore-ios-dist}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$FEX_SOURCE_DIR/CMakeLists.txt" ]] || fail "FEX source tree missing at $FEX_SOURCE_DIR; checkout willfaust/FEX at $FEX_PIN with recursive submodules."
command -v cmake >/dev/null 2>&1 || fail "CMake is required."
command -v ninja >/dev/null 2>&1 || fail "Ninja is required."
command -v xcrun >/dev/null 2>&1 || fail "Xcode command-line tools are required."

actual_pin="$(git -C "$FEX_SOURCE_DIR" rev-parse HEAD)"
[[ "$actual_pin" == "$FEX_PIN" ]] || fail "FEX pin mismatch: expected $FEX_PIN, found $actual_pin."
if git -C "$FEX_SOURCE_DIR" submodule status --recursive | grep -qE '^[-+U]'; then
  git -C "$FEX_SOURCE_DIR" submodule status --recursive >&2
  fail "FEX submodules are missing or do not match the pinned gitlinks."
fi

SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
printf 'Building FEXCore for arm64-apple-ios (SDK %s) from %s\n' "$SDK_VERSION" "$FEX_PIN"

cmake -S "$FEX_SOURCE_DIR" -B "$FEX_BUILD_DIR" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DBUILD_STEAM_SUPPORT=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_ASSERTIONS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_CCACHE=OFF \
  -DENABLE_GDB_SYMBOLS=OFF \
  -DENABLE_OFFLINE_TELEMETRY=OFF \
  -DTUNE_CPU=generic \
  -DTUNE_ARCH=generic

cmake --build "$FEX_BUILD_DIR" \
  --target FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit softfloat_3e xxhash \
  --parallel "$JOBS"

libraries=(
  "$FEX_BUILD_DIR/FEXCore/Source/libFEXCore.a"
  "$FEX_BUILD_DIR/FEXCore/Source/libFEXCore_Base.a"
  "$FEX_BUILD_DIR/FEXCore/Source/libJemallocLibs.a"
  "$FEX_BUILD_DIR/External/fmt/libfmt.a"
  "$FEX_BUILD_DIR/External/cephes/libcephes_128bit.a"
  "$FEX_BUILD_DIR/External/SoftFloat-3e/libsoftfloat_3e.a"
  "$FEX_BUILD_DIR/External/xxhash/cmake_unofficial/libxxhash.a"
)
for library in "${libraries[@]}"; do
  [[ -s "$library" ]] || fail "Expected static library was not produced: $library"
  arch_info="$(xcrun lipo -info "$library")"
  [[ "$arch_info" == *arm64* ]] || fail "Library is not arm64: $library ($arch_info)"
done

symbols="$(xcrun nm -gU "$FEX_BUILD_DIR/FEXCore/Source/libFEXCore.a")"
for symbol in CreateNewContext ExecuteThread CreateThread DestroyThread; do
  grep -q "$symbol" <<<"$symbols" || fail "FEXCore archive is missing expected embedding API symbol: $symbol"
done

# Confirm that the archive contains an object carrying an iOS platform load command,
# not merely an arm64 macOS object. Keep the extraction outside the repository.
verify_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fexcore-ios-platform-check"
rm -rf "$verify_dir"
mkdir -p "$verify_dir"
(
  cd "$verify_dir"
  xcrun ar -x "$FEX_BUILD_DIR/FEXCore/Source/libFEXCore.a"
)
platform_verified=false
for object in "$verify_dir"/*.o; do
  [[ -f "$object" ]] || continue
  if xcrun vtool -show-build "$object" 2>/dev/null | grep -q 'platform IOS'; then
    platform_verified=true
    break
  fi
done
[[ "$platform_verified" == true ]] || fail "Could not verify an iOS LC_BUILD_VERSION in the FEXCore archive."

rm -rf "$FEX_DIST_DIR"
mkdir -p "$FEX_DIST_DIR/lib" "$FEX_DIST_DIR/include" "$FEX_DIST_DIR/licenses"
for library in "${libraries[@]}"; do cp "$library" "$FEX_DIST_DIR/lib/"; done
# FEX public headers include generated IR and configuration headers. Package both
# source and build-generated include trees so the artifact is a usable SDK input.
for generated_header in \
  "$FEX_BUILD_DIR/include/FEXCore/IR/IRDefines.inc" \
  "$FEX_BUILD_DIR/include/FEXCore/IR/IRDefines_Dispatch.inc" \
  "$FEX_BUILD_DIR/include/FEXCore/Config/ConfigValues.inl" \
  "$FEX_BUILD_DIR/include/FEXCore/Config/ConfigOptions.inl" \
  "$FEX_BUILD_DIR/generated/git_version.h"; do
  [[ -s "$generated_header" ]] || fail "Required generated FEXCore header is missing: $generated_header"
done
cp -R "$FEX_SOURCE_DIR/FEXCore/include/." "$FEX_DIST_DIR/include/"
cp -R "$FEX_BUILD_DIR/include/." "$FEX_DIST_DIR/include/"
cp "$FEX_BUILD_DIR/generated/git_version.h" "$FEX_DIST_DIR/include/"
cp "$FEX_SOURCE_DIR/LICENSE" "$FEX_DIST_DIR/licenses/FEX-MIT-LICENSE.txt"
cp "$FEX_SOURCE_DIR/LICENSE-MADEIRA.md" "$FEX_DIST_DIR/licenses/LICENSE-MADEIRA.md"
cp "$FEX_SOURCE_DIR/COPYING.GPL-3.0" "$FEX_DIST_DIR/licenses/COPYING.GPL-3.0"
cp "$FEX_SOURCE_DIR/.gitmodules" "$FEX_DIST_DIR/licenses/FEX-GITMODULES.txt"
mkdir -p "$FEX_DIST_DIR/licenses/third-party"
while IFS= read -r -d '' license_file; do
  relative="${license_file#"$FEX_SOURCE_DIR/"}"
  destination="$FEX_DIST_DIR/licenses/third-party/$relative"
  mkdir -p "$(dirname "$destination")"
  cp "$license_file" "$destination"
done < <(find "$FEX_SOURCE_DIR" -name .git -prune -o -type f \
  \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \) -print0)
{
  printf 'FEX repository: https://github.com/willfaust/FEX\n'
  printf 'FEX commit: %s\n' "$actual_pin"
  printf 'Submodules:\n'
  git -C "$FEX_SOURCE_DIR" submodule status --recursive
  printf 'Target: arm64-apple-ios\n'
  printf 'iOS deployment target: 16.0\n'
  printf 'iPhoneOS SDK: %s\n' "$SDK_VERSION"
  printf 'Xcode: %s\n' "$XCODE_VERSION"
  printf 'CMake: %s\n' "$(cmake --version | head -n 1)"
  printf 'Ninja: %s\n' "$(ninja --version)"
  printf 'Status: STATIC LIBRARY BUILD ONLY; NOT LINKED INTO AKATSUBAKI EMU\n'
  printf '\nSHA-256:\n'
  shasum -a 256 "${libraries[@]}"
} > "$FEX_DIST_DIR/manifest.txt"

printf 'FEXCore iOS arm64 libraries built and validated.\n'
