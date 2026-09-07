#!/bin/bash
# Builds GitWall.app into ./dist and (optionally) installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP="dist/GitWall.app"

ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c "$CONFIG" "${ARCHS[@]}" >/dev/null 2>&1; then
  ARCHS=()   # fall back to a native-only build
  swift build -c "$CONFIG"
fi
BIN=$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GitWall" "$APP/Contents/MacOS/GitWall"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for the keychain and notifications to work locally.
codesign --force --deep --sign - --entitlements GitWall.entitlements "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/GitWall.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/GitWall.app"
fi
