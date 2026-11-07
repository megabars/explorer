#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--universal" ]]; then
    shift
    UNIVERSAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/explorer-universal.XXXXXX")
    trap 'rm -rf "$UNIVERSAL_DIR"' EXIT
    # Build each architecture with SwiftPM's native driver. The Xcode driver
    # selected by a multi-arch invocation cannot reliably load Swift 6 settings.
    for ARCH in arm64 x86_64; do
        bash build_app.sh --no-launch --configuration release --build-system native --arch "$ARCH" "$@"
        cp Explorer.app/Contents/MacOS/Explorer "$UNIVERSAL_DIR/$ARCH"
    done
    lipo -create "$UNIVERSAL_DIR/arm64" "$UNIVERSAL_DIR/x86_64" -output Explorer.app/Contents/MacOS/Explorer
    codesign --force --sign - Explorer.app
    codesign --verify --strict Explorer.app
else
    bash build_app.sh --no-launch --configuration release "$@"
fi

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
