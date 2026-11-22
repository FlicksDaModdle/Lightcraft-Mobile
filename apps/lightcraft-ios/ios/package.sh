#!/usr/bin/env bash
# Builds LightCraft.app from the compiled binary, signs it with the developer's certificate and
# provisioning profile, and zips it as LightCraft.ipa. Runs on a macOS machine (the CI runner).
#
#   package.sh <binary> <output dir>
#
# Signing input, as environment variables (base64 for the two files):
#   IOS_CERT_P12, IOS_CERT_PASSWORD   the signing certificate and its password (a .p12 export)
#   IOS_PROVISION_PROFILE             the .mobileprovision for the app (development or ad hoc)
#   IOS_BUNDLE_ID                     only for a wildcard profile (its App ID ends in *)
# Without them the app is packaged as LightCraft-unsigned.ipa, for a tool that signs at install time.
set -euo pipefail

BIN=${1:?usage: package.sh <binary> <output dir>}
OUT=${2:?usage: package.sh <binary> <output dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
APP="$OUT/LightCraft.app"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)
BUILD=${GITHUB_RUN_NUMBER:-1}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP" "$OUT/Payload" "$OUT/LightCraft.ipa" "$OUT/LightCraft-unsigned.ipa"
mkdir -p "$APP"
cp "$BIN" "$APP/LightCraft"
chmod +x "$APP/LightCraft"

# Icons: PNGs of the sizes iOS looks for, made from the 1024 px original.
ICON="$ROOT/assets/app-icon/lightcraft-1024.png"
for spec in "AppIcon60x60@2x.png:120" "AppIcon60x60@3x.png:180" "AppIcon76x76@2x~ipad.png:152" "AppIcon83.5x83.5@2x~ipad.png:167"; do
  name=${spec%%:*}; px=${spec##*:}
  sips -z "$px" "$px" "$ICON" --out "$APP/$name" >/dev/null
done

BUNDLE_ID=${IOS_BUNDLE_ID:-com.example.lightcraft}
SIGN=false
if [ -n "${IOS_CERT_P12:-}" ] && [ -n "${IOS_PROVISION_PROFILE:-}" ]; then
  SIGN=true
  echo "$IOS_PROVISION_PROFILE" | base64 --decode > "$WORK/profile.mobileprovision"
  security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"
  APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")
  PREFIX=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' "$WORK/profile.plist")
  PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$WORK/profile.plist")
  PROFILE_BUNDLE=${APP_ID#"$PREFIX."}
  case "$PROFILE_BUNDLE" in
    *'*') [ -n "${IOS_BUNDLE_ID:-}" ] || { echo "the profile is a wildcard ($PROFILE_BUNDLE): set IOS_BUNDLE_ID" >&2; exit 1; } ;;
    *) BUNDLE_ID=$PROFILE_BUNDLE ;;
  esac
fi

sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|" -e "s|@VERSION@|$VERSION|" -e "s|@BUILD@|$BUILD|" \
  "$HERE/Info.plist.in" > "$APP/Info.plist"
echo "bundle id: $BUNDLE_ID, version $VERSION ($BUILD), signing: $SIGN"

if [ "$SIGN" = true ]; then
  KEYCHAIN="$WORK/build.keychain-db"
  KEYCHAIN_PASSWORD=$(uuidgen)
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  echo "$IOS_CERT_P12" | base64 --decode > "$WORK/cert.p12"
  security import "$WORK/cert.p12" -P "${IOS_CERT_PASSWORD:-}" -A -t cert -f pkcs12 -k "$KEYCHAIN"
  security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
  IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' | head -1)
  [ -n "$IDENTITY" ] || { echo "no signing identity in the certificate" >&2; exit 1; }
  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  cp "$WORK/profile.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
  cp "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"
  codesign --force --sign "$IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none --keychain "$KEYCHAIN" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

# An .ipa is a zip of Payload/LightCraft.app. Unsigned, it is for a tool that signs it at install time
# (Sideloadly, AltStore, ...); signed, it installs directly.
IPA=LightCraft.ipa
[ "$SIGN" = true ] || IPA=LightCraft-unsigned.ipa
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry "$IPA" Payload)
rm -rf "$OUT/Payload"
echo "wrote $OUT/$IPA"
