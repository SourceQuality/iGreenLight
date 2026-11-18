#!/bin/zsh
# Builds an unsigned iGreenLight .ipa for sideloading: scripts/make-ipa.sh [output-dir]
# Nothing is signed, so no Apple account or team is involved; whoever installs it signs it with their own Apple ID
# (AltStore, SideStore, Sideloadly and similar tools do that). The result is <output-dir>/iGreenLight-<version>-unsigned.ipa.
set -e
set -o pipefail
ROOT=${0:A:h:h}
OUT=${1:-$ROOT/build/ipa}
DERIVED=$ROOT/build
cd "$ROOT"
LOG=$(xcodebuild build -project iGreenLight.xcodeproj -scheme iGreenLight-iOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" 2>&1) || true
echo "$LOG" | grep -E "\.swift:[0-9]+:[0-9]+: error:|error: |\*\* BUILD" || true
echo "$LOG" | grep -q "BUILD SUCCEEDED" || { echo "build failed"; exit 1; }
APP="$DERIVED/Build/Products/Release-iphoneos/iGreenLight.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
STAGE=$(mktemp -d)
mkdir -p "$STAGE/Payload" "$OUT"
cp -R "$APP" "$STAGE/Payload/"
# Nothing from a signing identity may ride along.
rm -rf "$STAGE/Payload/iGreenLight.app/_CodeSignature" "$STAGE/Payload/iGreenLight.app/embedded.mobileprovision"
IPA="$OUT/iGreenLight-$VERSION-unsigned.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
rm -rf "$STAGE"
echo "$IPA"
