#!/bin/bash
set -e

APP="Focusly.app"

swift build -c debug
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/Focusly "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

codesign --force --deep -s - "$APP"

echo "✅ Built: $APP"
echo "➡️  Run with: open $APP"
