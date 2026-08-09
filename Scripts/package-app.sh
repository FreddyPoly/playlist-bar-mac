#!/bin/bash
# Wraps the swift-build executable into a minimal PlaylistBar.app bundle.
#
# This exists only because SMAppService (Launch-at-Login, startup-001) requires a real .app
# bundle with an Info.plist/CFBundleIdentifier — a bare `swift build` executable doesn't satisfy
# that. Day-to-day development still just uses `swift build`/`swift run`; only run this when you
# need the real bundled app (testing Launch-at-Login, or eventually distributing it).
set -euo pipefail

CONFIGURATION="${1:-release}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PlaylistBar"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "Building ($CONFIGURATION)..."
swift build -c "$CONFIGURATION" --package-path "$PROJECT_ROOT"

BINARY_PATH="$(swift build -c "$CONFIGURATION" --package-path "$PROJECT_ROOT" --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "error: built binary not found at $BINARY_PATH" >&2
    exit 1
fi

echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $APP_BUNDLE"
echo "Run it with: open \"$APP_BUNDLE\""
