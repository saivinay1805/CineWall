#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBSITE_DIR="$ROOT_DIR/website"
UPDATES_DIR="$WEBSITE_DIR/updates"
PRODUCT_LINK="https://cinewall-site.vercel.app"
FEED_URL_PREFIX="${PRODUCT_LINK}/updates"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/prepare_sparkle_release.sh /absolute/path/to/CineWall.app [release-notes-file]

What it does:
  1. Reads version info from the .app bundle
  2. Creates a Sparkle-safe zip archive in website/updates/
  3. Optionally copies release notes beside the archive
  4. Regenerates website/appcast.xml using Sparkle's generate_appcast tool

Examples:
  ./scripts/prepare_sparkle_release.sh "/Applications/CineWall.app"
  ./scripts/prepare_sparkle_release.sh "/tmp/CineWall.app" "/tmp/CineWall-2.0.0.md"
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

APP_PATH="$1"
RELEASE_NOTES_PATH="${2:-}"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Expected a .app bundle, got: $APP_PATH" >&2
  exit 1
fi

if [[ -n "$RELEASE_NOTES_PATH" && ! -f "$RELEASE_NOTES_PATH" ]]; then
  echo "Release notes file not found: $RELEASE_NOTES_PATH" >&2
  exit 1
fi

GENERATE_APPCAST_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -print -quit)"

if [[ -z "$GENERATE_APPCAST_BIN" ]]; then
  echo "Could not find Sparkle's generate_appcast tool in DerivedData." >&2
  echo "Open the project in Xcode first so Swift Package Manager resolves Sparkle." >&2
  exit 1
fi

BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
APP_NAME="$(basename "$APP_PATH" .app)"

if [[ -z "$BUNDLE_SHORT_VERSION" || -z "$BUNDLE_VERSION" ]]; then
  echo "Could not read CFBundleShortVersionString / CFBundleVersion from $APP_PATH" >&2
  exit 1
fi

mkdir -p "$UPDATES_DIR"

ARCHIVE_BASENAME="${APP_NAME}-${BUNDLE_SHORT_VERSION}.zip"
ARCHIVE_PATH="$UPDATES_DIR/$ARCHIVE_BASENAME"

echo "Creating archive:"
echo "  $ARCHIVE_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  RELEASE_NOTES_EXTENSION="${RELEASE_NOTES_PATH##*.}"
  RELEASE_NOTES_TARGET="$UPDATES_DIR/${APP_NAME}-${BUNDLE_SHORT_VERSION}.${RELEASE_NOTES_EXTENSION}"
  echo "Copying release notes:"
  echo "  $RELEASE_NOTES_TARGET"
  /bin/cp "$RELEASE_NOTES_PATH" "$RELEASE_NOTES_TARGET"
fi

echo "Generating appcast:"
echo "  Tool: $GENERATE_APPCAST_BIN"
"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$FEED_URL_PREFIX" \
  --link "$PRODUCT_LINK" \
  -o "$WEBSITE_DIR/appcast.xml" \
  "$UPDATES_DIR"

python3 - "$WEBSITE_DIR/appcast.xml" "$PRODUCT_LINK" "$FEED_URL_PREFIX" <<'PY'
import sys
from pathlib import Path

appcast_path = Path(sys.argv[1])
site_root = sys.argv[2].rstrip("/")
updates_root = sys.argv[3].rstrip("/")
text = appcast_path.read_text()
text = text.replace(f'<enclosure url="{site_root}/', f'<enclosure url="{updates_root}/')
appcast_path.write_text(text)
PY

echo
echo "Sparkle release assets are ready."
echo "Archive: $ARCHIVE_PATH"
echo "Appcast: $WEBSITE_DIR/appcast.xml"
echo
echo "Next:"
echo "  1. Review website/appcast.xml"
echo "  2. Commit website/appcast.xml and website/updates/* into the website repo"
echo "  3. Push the website repo so Vercel serves the new update"
