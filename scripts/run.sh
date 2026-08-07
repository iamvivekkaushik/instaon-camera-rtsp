#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -x "$ROOT/Vendor/ffmpeg" ]]; then
  echo "Missing Vendor/ffmpeg. Download a macOS ffmpeg binary into CameraStreamer/Vendor/ffmpeg" >&2
  exit 1
fi

# Prefer a freshly built release binary when present (media path fixes live there).
if [[ -x "$ROOT/Vendor/dh-p2p/target/release/dh-p2p" ]]; then
  cp "$ROOT/Vendor/dh-p2p/target/release/dh-p2p" "$ROOT/Vendor/dh-p2p-bin"
  chmod +x "$ROOT/Vendor/dh-p2p-bin"
elif [[ ! -x "$ROOT/Vendor/dh-p2p-bin" ]]; then
  echo "Missing Vendor/dh-p2p-bin. Build with:" >&2
  echo "  cd Vendor/dh-p2p && CARGO_TARGET_DIR=target cargo build --release" >&2
  echo "  cp target/release/dh-p2p ../dh-p2p-bin" >&2
  exit 1
fi

swift build -c release
BIN="$ROOT/.build/release/CameraStreamer"
APP="$ROOT/CameraStreamer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CameraStreamer"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Vendor/ffmpeg" "$APP/Contents/Resources/ffmpeg"
cp "$ROOT/Vendor/dh-p2p-bin" "$APP/Contents/Resources/dh-p2p-bin"
chmod +x "$APP/Contents/MacOS/CameraStreamer" \
  "$APP/Contents/Resources/ffmpeg" \
  "$APP/Contents/Resources/dh-p2p-bin"

echo "Launching $APP"
open "$APP"
