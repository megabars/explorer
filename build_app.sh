#!/bin/bash
set -e

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

echo "Done. Launching ${APP_BUNDLE}..."
open "${APP_BUNDLE}"
