#!/bin/sh
# Build Latent for iPhone and iPad into an unsigned IPA (Sideloadly or AltStore sign it with your
# Apple ID when installing). Needs macOS with Xcode, Rust with the aarch64-apple-ios target, and
# XcodeGen. Usage: apps/latent-ios/build.sh [OUT_DIR]   (default: out)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-out}
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 1. the engine bridge, as a static library for the device
cargo build --release --target aarch64-apple-ios -p lightcraft-latent --manifest-path "$root/Cargo.toml"

# 2. the Swift app
cd "$here"
xcodegen generate
# LATENT_VERSION / LATENT_BUILD (CI sets them from the run number) so each build is newer than the last
xcodebuild -project Latent.xcodeproj -target Latent -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="${LATENT_VERSION:-0.1.0}" CURRENT_PROJECT_VERSION="${LATENT_BUILD:-1}" \
  SYMROOT="$here/build" build

# 3. an unsigned IPA
rm -rf "$here/build/ipa" && mkdir -p "$here/build/ipa/Payload"
cp -R "$here/build/Release-iphoneos/Latent.app" "$here/build/ipa/Payload/"
(cd "$here/build/ipa" && zip -qry "$out/Latent-unsigned.ipa" Payload)
echo "wrote $out/Latent-unsigned.ipa"
