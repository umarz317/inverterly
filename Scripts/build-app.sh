#!/bin/zsh
# Builds dist/Inverterly.app. Pass "install" to also copy it to ~/Applications and open it.
#   ./Scripts/build-app.sh            build only
#   ./Scripts/build-app.sh install    build, install to ~/Applications, relaunch
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Inverterly.app"
# Ad-hoc signing ("-") is enough to run on this Mac. Set INVERTERLY_CODESIGN_IDENTITY to sign properly.
SIGNER="${INVERTERLY_CODESIGN_IDENTITY:--}"

swift build -c release --product Inverterly
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Inverterly" "$APP/Contents/MacOS/Inverterly"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

swift Scripts/make-icon.swift "$PWD/dist/AppIcon.iconset" >/dev/null
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# A real identity gets the hardened runtime and a secure timestamp, which notarization requires.
SIGN_OPTIONS=()
[[ "$SIGNER" != "-" ]] && SIGN_OPTIONS=(--options runtime --timestamp)
codesign --force --sign "$SIGNER" "${SIGN_OPTIONS[@]}" --identifier com.loopbreak.inverterly "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/Inverterly.app"
  mkdir -p "$HOME/Applications"
  pkill -x Inverterly 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and opened $DEST"
fi
