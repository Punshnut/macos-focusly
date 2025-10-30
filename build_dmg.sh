#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT_DIR/Focusly.app"
README="$ROOT_DIR/README.md"
DMG="$ROOT_DIR/Focusly.dmg"
VOLUME_NAME="Focusly"

"$ROOT_DIR/build_app.sh"

if [ ! -d "$APP" ]; then
  echo "❌ Missing app bundle at $APP" >&2
  exit 1
fi

if [ ! -f "$README" ]; then
  echo "❌ Missing README at $README" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/"
cp "$README" "$STAGING_DIR/README.md"

if [ -f "$DMG" ]; then
  rm "$DMG"
fi

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG"

echo "✅ Created: $DMG"
