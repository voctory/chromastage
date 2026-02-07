#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=""
TAG=""
NOTES=""

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh --version X.Y[.Z] [--tag vX.Y[.Z]] [--notes "Release notes"]

Builds and signs the app, generates Sparkle appcast, and publishes a GitHub release.
Requires: Xcode, gh CLI, Sparkle tools (auto-built if missing).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --notes)
      NOTES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Missing --version" >&2
  usage
  exit 1
fi

if [[ -z "$TAG" ]]; then
  TAG="v${VERSION}"
fi

if [[ -z "$NOTES" ]]; then
  NOTES="Release ${VERSION}."
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install GitHub CLI and authenticate." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode." >&2
  exit 1
fi

INFO_PLIST="$ROOT/Chromastage/Info.plist"
PLIST_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" 2>/dev/null || true)
if [[ -n "$PLIST_VERSION" && "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "Warning: CFBundleShortVersionString is $PLIST_VERSION, not $VERSION." >&2
fi

echo "Building + signing Chromastage ${VERSION}"
"$ROOT/Scripts/sign-and-notarize.sh"

ZIP_NAME="Chromastage-${VERSION}.zip"
ZIP_PATH="$ROOT/$ZIP_NAME"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing zip at $ZIP_PATH" >&2
  exit 1
fi

TOOLS_DERIVED_DATA="$ROOT/Build/SparkleTools"
APPCAST_TOOL="$TOOLS_DERIVED_DATA/Build/Products/Release/generate_appcast"
if [[ ! -x "$APPCAST_TOOL" ]]; then
  echo "Building Sparkle generate_appcast tool"
  xcodebuild \
    -project "$ROOT/Build/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj" \
    -scheme generate_appcast \
    -configuration Release \
    -derivedDataPath "$TOOLS_DERIVED_DATA" \
    build
fi

DIST_DIR="$ROOT/dist/sparkle"
mkdir -p "$DIST_DIR"
cp -f "$ZIP_PATH" "$DIST_DIR/"

echo "Generating appcast"
"$APPCAST_TOOL" \
  --download-url-prefix "https://github.com/voctory/chromastage/releases/download/${TAG}/" \
  -o "$DIST_DIR/appcast.xml" \
  "$DIST_DIR"

DMG_NAME="Chromastage-${VERSION}.dmg"
DMG_PATH="$ROOT/$DMG_NAME"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Updating existing GitHub release $TAG"
  gh release upload "$TAG" "$ZIP_PATH" "$DMG_PATH" "$DIST_DIR/appcast.xml" --clobber
else
  echo "Creating GitHub release $TAG"
  gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" "$DIST_DIR/appcast.xml" \
    --title "$TAG" \
    --notes "$NOTES"
fi

echo "Done: $TAG"
