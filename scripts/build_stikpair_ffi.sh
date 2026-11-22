#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/pairing-ffi/Cargo.toml"
TARGET="$ROOT/build/pairing-ffi"
OUT="$ROOT/build/dependencies/AkatsubakiPairingFFI.xcframework"
if ! command -v rustup >/dev/null 2>&1; then mkdir -p "$ROOT/build"; curl --fail --location --retry 3 https://sh.rustup.rs -o "$ROOT/build/rustup-init.sh"; sh "$ROOT/build/rustup-init.sh" -y --profile minimal; source "$HOME/.cargo/env"; fi
rustup toolchain install stable --profile minimal
rustup default stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo fmt --manifest-path "$MANIFEST"
cargo test --manifest-path "$MANIFEST" --locked --target-dir "$TARGET"
cargo build --manifest-path "$MANIFEST" --locked --release --target aarch64-apple-ios --target-dir "$TARGET"
cargo build --manifest-path "$MANIFEST" --locked --release --target aarch64-apple-ios-sim --target-dir "$TARGET"
mkdir -p "$(dirname "$OUT")"; rm -rf "$OUT"
xcodebuild -create-xcframework -library "$TARGET/aarch64-apple-ios/release/libakatsubaki_pairing_ffi.a" -headers "$ROOT/pairing-ffi/include" -library "$TARGET/aarch64-apple-ios-sim/release/libakatsubaki_pairing_ffi.a" -headers "$ROOT/pairing-ffi/include" -output "$OUT"
plutil -lint "$OUT/Info.plist"
grep -q ios-arm64 "$OUT/Info.plist"
grep -q ios-arm64-simulator "$OUT/Info.plist"
