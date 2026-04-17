#!/bin/bash
# make-dmg.sh — builds a distributable DMG for ToooT.
#
# Usage: ./scripts/make-dmg.sh [version]
#   version defaults to the CFBundleShortVersionString read from Info.plist.
#
# Requires:
#   - A built ToooT.app (run ./bundle.sh first)
#   - hdiutil (ships with macOS)
#   - Optional: `create-dmg` Homebrew formula for nicer layout.

set -euo pipefail

APP="ToooT.app"
VERSION="${1:-$(defaults read "$(pwd)/${APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")}"
OUT_DIR="dist"
DMG_PATH="${OUT_DIR}/ToooT-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
    echo "ToooT.app not found — run ./bundle.sh first."
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"

# Add a Symbolic link to /Applications so users can drag-install.
ln -s /Applications "$STAGING/Applications"

# Optional README inside the DMG.
cat > "$STAGING/README.txt" << EOF
ToooT ${VERSION}

Installation:
  1. Drag ToooT.app to the Applications folder.
  2. On first launch, right-click → Open (Gatekeeper needs authorization
     until we ship notarized builds).

Requires macOS 14 or later.
Source + documentation: https://github.com/mstits/Tooot
EOF

hdiutil create \
    -volname "ToooT ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

rm -rf "$STAGING"

echo ""
echo "✅ DMG: $(pwd)/${DMG_PATH}"
echo "   size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "Notarize with:"
echo "  xcrun notarytool submit ${DMG_PATH} --keychain-profile 'notary' --wait"
