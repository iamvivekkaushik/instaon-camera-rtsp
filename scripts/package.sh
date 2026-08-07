#!/usr/bin/env bash
# Build CameraStreamer.app and an installable DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="CameraStreamer"
APP="$ROOT/${APP_NAME}.app"
DMG="$ROOT/dist/${APP_NAME}-1.0.0.dmg"
VOL_NAME="CameraStreamer"
STAGE="$ROOT/dist/dmg-stage"

if [[ ! -x "$ROOT/Vendor/ffmpeg" ]]; then
  echo "Missing Vendor/ffmpeg. Download a macOS ffmpeg binary into CameraStreamer/Vendor/ffmpeg" >&2
  exit 1
fi

if [[ -x "$ROOT/Vendor/dh-p2p/target/release/dh-p2p" ]]; then
  cp "$ROOT/Vendor/dh-p2p/target/release/dh-p2p" "$ROOT/Vendor/dh-p2p-bin"
  chmod +x "$ROOT/Vendor/dh-p2p-bin"
elif [[ ! -x "$ROOT/Vendor/dh-p2p-bin" ]]; then
  echo "Missing Vendor/dh-p2p-bin. Build with:" >&2
  echo "  cd Vendor/dh-p2p && cargo build --release && cp target/release/dh-p2p ../dh-p2p-bin" >&2
  exit 1
fi

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "Missing Resources/AppIcon.icns" >&2
  exit 1
fi

echo "==> Building release binary"
swift build -c release
BIN="$ROOT/.build/release/CameraStreamer"

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CameraStreamer"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Vendor/ffmpeg" "$APP/Contents/Resources/ffmpeg"
cp "$ROOT/Vendor/dh-p2p-bin" "$APP/Contents/Resources/dh-p2p-bin"
chmod +x "$APP/Contents/MacOS/CameraStreamer" \
  "$APP/Contents/Resources/ffmpeg" \
  "$APP/Contents/Resources/dh-p2p-bin"

# Refresh Finder/Dock icon cache hints for local builds
touch "$APP"

echo "==> Creating DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
# Copy app into stage (not move — keep .app at repo root for run.sh)
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -sf /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGE"

echo ""
echo "App: $APP"
echo "DMG: $DMG"
ls -lh "$APP/Contents/Resources/AppIcon.icns" "$DMG"
