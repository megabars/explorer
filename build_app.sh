#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

LAUNCH=true
if [[ "${1:-}" == "--no-launch" ]]; then
    LAUNCH=false
    shift
fi

APP_NAME="Explorer"
APP_BUNDLE="${APP_NAME}.app"

echo "Building..."
swift build "$@" 2>&1
BUILD_DIR="$(swift build "$@" --show-bin-path)"

echo "Creating .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Sources/Explorer/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Sources/Explorer/Resources/AppIcon/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp -R "${BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle" "${APP_BUNDLE}/Contents/Resources/"

plutil -lint "${APP_BUNDLE}/Contents/Info.plist"
codesign --force --sign - "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}"

echo "Built ${APP_BUNDLE}"
if [[ "$LAUNCH" == true ]]; then
    open "${APP_BUNDLE}"
fi
