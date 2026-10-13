#!/bin/zsh
# Builds dist/Inverterly-<version>.dmg: a Developer ID signed app in a signed disk image.
#   ./Scripts/make-dmg.sh
#
# Environment:
#   INVERTERLY_CODESIGN_IDENTITY  signing identity; default is the first "Developer ID Application" in the keychain
#   INVERTERLY_NOTARY_PROFILE     notarytool keychain profile; when set, the DMG is notarized and stapled
#                                  (create one with: xcrun notarytool store-credentials <name>)
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

IDENTITY="${INVERTERLY_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found. Set INVERTERLY_CODESIGN_IDENTITY." >&2; exit 1; }
echo "Signing as: $IDENTITY"

INVERTERLY_CODESIGN_IDENTITY="$IDENTITY" ./Scripts/build-app.sh

APP="$PWD/dist/Inverterly.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$PWD/dist/Inverterly-$VERSION.dmg"
STAGE="$PWD/dist/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Inverterly" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"

if [[ -n "${INVERTERLY_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$INVERTERLY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "Not notarized: set INVERTERLY_NOTARY_PROFILE to notarize and staple (other Macs will show a Gatekeeper warning until then)."
fi

echo "Built $DMG"
