#!/usr/bin/env bash
# sign_dev_dmg.sh — sign the Focusly .app with the Developer ID cert and wrap it
# inside a "Dev Install" DMG that mirrors the regular installer layout.
# Usage: ./sign_dev_dmg.sh [/path/to/Focusly.app]

set -euo pipefail

APP_NAME="${APP_NAME:-Focusly}"
DEFAULT_CERT_NAME="Developer ID Application: Jan Feuerbacher (JHV68VH5AC)"
CERT_NAME="${CERT_NAME:-$DEFAULT_CERT_NAME}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
DEV_DMG_NAME="${DEV_DMG_NAME:-${APP_NAME} Dev Install}"
DEV_DMG_VOLUME_NAME="${DEV_DMG_VOLUME_NAME:-$DEV_DMG_NAME}"
README_SOURCE="${README_SOURCE:-README.md}"
APPLICATIONS_ALIAS_NAME="${APPLICATIONS_ALIAS_NAME:-Applications}"
INSTALL_NOTES_FILENAME="${INSTALL_NOTES_FILENAME:-Dev Install Instructions.txt}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
DEFAULT_ENTITLEMENTS_PATH="${PROJECT_ROOT}/Focusly.entitlements"
if [[ -z "$ENTITLEMENTS" && -f "$DEFAULT_ENTITLEMENTS_PATH" ]]; then
  ENTITLEMENTS="$DEFAULT_ENTITLEMENTS_PATH"
fi
DEFAULT_APP_BUNDLE="${PROJECT_ROOT}/${APP_NAME}.app"
APP_INPUT="${1:-$DEFAULT_APP_BUNDLE}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "✖ Required tool '$1' not found in PATH." >&2
    exit 1
  fi
}

require_tool /usr/bin/codesign
require_tool hdiutil

APP_BUNDLE_PATH="$(cd "$(dirname "$APP_INPUT")" && pwd)/$(basename "$APP_INPUT")"
if [[ ! -d "$APP_BUNDLE_PATH/Contents/MacOS" ]]; then
  echo "✖ $APP_BUNDLE_PATH is not an .app bundle." >&2
  exit 2
fi

if [[ ! -f "${PROJECT_ROOT}/${README_SOURCE}" ]]; then
  echo "✖ README missing at ${PROJECT_ROOT}/${README_SOURCE}" >&2
  exit 3
fi

if [[ "${FOCUSLY_SKIP_APP_BUILD:-0}" != "1" && "$APP_BUNDLE_PATH" == "$DEFAULT_APP_BUNDLE" ]]; then
  echo "› Building ${APP_NAME}.app (set FOCUSLY_SKIP_APP_BUILD=1 to skip)…"
  FOCUSLY_SKIP_DMG_BUILD=1 "${PROJECT_ROOT}/build_app.sh"
fi

if [[ "$CERT_NAME" == *"YOUR NAME"* || "$CERT_NAME" == *"TEAMID"* ]]; then
  echo "✖ Update CERT_NAME to your real Developer ID certificate or export CERT_NAME before running." >&2
  exit 4
fi

SIGN_ARGS=(--force --options runtime --timestamp --deep --sign "$CERT_NAME")
if [[ -n "$ENTITLEMENTS" ]]; then
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

echo "==> Signing ${APP_BUNDLE_PATH} with ${CERT_NAME}"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE_PATH"

echo "==> Verifying signature..."
/usr/bin/codesign -vvv --deep --strict "$APP_BUNDLE_PATH" >/dev/null

DMG_PATH="${PROJECT_ROOT}/${DEV_DMG_NAME}.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/focusly-dev-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "› Preparing DMG staging directory: ${STAGING_DIR}"
cp -R "$APP_BUNDLE_PATH" "${STAGING_DIR}/${APP_NAME}.app"
cp "${PROJECT_ROOT}/${README_SOURCE}" "${STAGING_DIR}/README.md"
cat <<EOF > "${STAGING_DIR}/${INSTALL_NOTES_FILENAME}"
${APP_NAME} Dev Install
=======================

1. Drag ${APP_NAME}.app onto the ${APPLICATIONS_ALIAS_NAME} shortcut.
2. Launch ${APP_NAME} from Applications (right-click → Open once if Gatekeeper warns).
3. This build is developer-signed only (no notarization) and is intended for internal testing.
EOF

echo "› Creating ${APPLICATIONS_ALIAS_NAME} shortcut"
ln -s /Applications "${STAGING_DIR}/${APPLICATIONS_ALIAS_NAME}"

echo "› Creating ${DMG_PATH}"
rm -f "$DMG_PATH"
hdiutil create \
  -fs HFS+ \
  -volname "$DEV_DMG_VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "✔ Developer install DMG created at $DMG_PATH"
echo "   Contents are signed with: $CERT_NAME"
