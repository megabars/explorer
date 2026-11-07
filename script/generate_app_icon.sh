#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

ICON_DIR="Sources/Explorer/Resources/AppIcon"
ICON_SOURCE="${ICON_DIR}/AppIcon.png"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/explorer-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="${WORK_DIR}/AppIcon.iconset"
mkdir -p "$ICONSET"

# Standard macOS icon representations, including Retina resolutions.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" \
        --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" \
        --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "${ICON_DIR}/AppIcon.icns"
echo "Generated ${ICON_DIR}/AppIcon.icns"
