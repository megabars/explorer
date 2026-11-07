#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash build_app.sh --no-launch --configuration release "$@"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Explorer.app/Contents/Info.plist)
ARCHS=$(lipo -archs Explorer.app/Contents/MacOS/Explorer)
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ARCH_LABEL=universal ;;
    arm64|x86_64) ARCH_LABEL="$ARCHS" ;;
    *) echo "Unexpected architectures: $ARCHS" >&2; exit 1 ;;
esac

mkdir -p dist
ARCHIVE="Explorer-${VERSION}-macos-${ARCH_LABEL}.zip"
ditto -c -k --sequesterRsrc --keepParent Explorer.app "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Packaged dist/$ARCHIVE"
