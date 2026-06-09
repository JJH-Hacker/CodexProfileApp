#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CodexProfileManager.app"
BIN="$ROOT/CodexProfileManager"

swiftc \
  -parse-as-library \
  "$ROOT/CodexProfileApp/Sources/CodexProfileApp.swift" \
  -o "$BIN" \
  -framework SwiftUI \
  -framework AppKit

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CodexProfileManager"
cp "$ROOT/CodexProfileApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/CodexProfileApp/Resources/codexbar" "$APP/Contents/Resources/codexbar"
if [ -f "$ROOT/CodexProfileApp/Resources/AppIcon.icns" ]; then
    cp "$ROOT/CodexProfileApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Built $APP"
