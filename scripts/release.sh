#!/bin/zsh
# Builds and ships a release of ezPDF: archive → sign with Developer ID (hardened runtime) → DMG → notarize →
# staple → upload to dl.harikanth.site/ezpdf (R2 bucket harikanth-downloads). Same steps as ezRecord's
# scripts/release.sh, without Sparkle (ezPDF doesn't update itself yet).
# Usage: scripts/release.sh <version> [build]      e.g. scripts/release.sh 1.0.0
# SKIP_NOTARIZE=1 for a local signing check, SKIP_UPLOAD=1 to stop before publishing. Guide: docs/release.md.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [build]}
BUILD=${2:-$(git rev-list --count HEAD)}
ROOT=${0:A:h:h}
OUT="$ROOT/build/release"
SHIPPED="$ROOT/build/shipped"                       # every DMG ever shipped, kept
NOTARY_PROFILE=${NOTARY_PROFILE:-KekasatoriNotary}  # notarytool keychain profile (shared with ezRecord, Owlish, ezHide)
DEV_ID="Developer ID Application: Harikanth Lingutla (2F5YSX6AK6)"
BUCKET=harikanth-downloads
PREFIX=ezpdf
DMG_NAME="ezPDF-$VERSION.dmg"

rm -rf "$OUT"; mkdir -p "$OUT" "$SHIPPED"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "▸ Archiving $VERSION ($BUILD)"
xcodebuild -project ezpdf.xcodeproj -scheme ezpdf -configuration Release \
  -archivePath "$OUT/ezpdf.xcarchive" -destination 'generic/platform=macOS' archive \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGN_IDENTITY=- -quiet
APP="$OUT/ezpdf.app"
cp -R "$OUT/ezpdf.xcarchive/Products/Applications/ezpdf.app" "$APP"

# Sign inside-out with Developer ID, hardened runtime and a secure timestamp (notarization needs all three).
echo "▸ Signing with Developer ID"
find "$APP/Contents" -type f \( -name "*.dylib" -o -perm +111 \) ! -path "*/MacOS/ezpdf" -print0 2>/dev/null |
  while IFS= read -r -d '' nested; do
    if file "$nested" | grep -q "Mach-O"; then codesign --force --timestamp --options runtime --sign "$DEV_ID" "$nested"; fi
  done
codesign --force --timestamp --options runtime --entitlements App/Support/ezpdf.entitlements --sign "$DEV_ID" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == "$VERSION" ]] || { echo "Version mismatch in Info.plist"; exit 1; }

echo "▸ Making the DMG"
# hdiutil can hit TCC "Operation not permitted" imaging from protected folders: stage in a temp folder.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ezpdf-dmg.XXXXXX")
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$SHIPPED/$DMG_NAME"
rm -f "$DMG"
hdiutil create -volname "ezPDF" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  echo "▸ Skipping notarization (SKIP_NOTARIZE=1): for testing only"
else
  echo "▸ Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

if [[ "${SKIP_UPLOAD:-0}" == 1 ]]; then
  echo "✓ $DMG (not uploaded)"
  exit 0
fi

echo "▸ Uploading to https://dl.harikanth.site/$PREFIX/"
npx -y wrangler r2 object put "$BUCKET/$PREFIX/$DMG_NAME" --file "$DMG" --remote \
  --content-type application/x-apple-diskimage --cache-control "public, max-age=31536000, immutable"

echo "✓ https://dl.harikanth.site/$PREFIX/$DMG_NAME"
echo "  Point DMG_URL in harikanth-site functions/api/ezpdf/download.ts at it and deploy the site."
