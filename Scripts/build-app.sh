#!/bin/zsh
# Builds dist/InverterBar.app. Pass "install" to also copy it to ~/Applications and open it.
#   ./Scripts/build-app.sh            build only
#   ./Scripts/build-app.sh install    build, install to ~/Applications, relaunch
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/InverterBar.app"
# Ad-hoc signing ("-") is enough to run on this Mac. Set INVERTERBAR_CODESIGN_IDENTITY to sign properly.
SIGNER="${INVERTERBAR_CODESIGN_IDENTITY:--}"

swift build -c release --product InverterBar
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/InverterBar" "$APP/Contents/MacOS/InverterBar"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

swift Scripts/make-icon.swift "$PWD/dist/AppIcon.iconset" >/dev/null
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$SIGNER" --identifier com.ahkamboh.inverterbar "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/InverterBar.app"
  mkdir -p "$HOME/Applications"
  pkill -x InverterBar 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and opened $DEST"
fi
