#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chromastage"
PROJECT="Chromastage.xcodeproj"
SCHEME="Chromastage"
CONFIGURATION="Release"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  cat <<'EOF'
Usage: Scripts/sign-and-notarize.sh [options]

Options:
  --app-identity ID          Codesign identity (defaults to Victor's Developer ID)
  --notary-profile PROFILE   notarytool keychain profile name
  --apple-id EMAIL           Apple ID for notarization
  --password PASSWORD        App-specific password (used with --apple-id)
  --team-id TEAM_ID          Apple Developer Team ID (used with --apple-id)
  --arches "arm64 x86_64"    Build architectures (default: arm64 x86_64)
  --skip-dmg                 Skip DMG creation (zip only)
  --skip-notarization        Sign and zip without submitting to notarytool (default if no creds)
  -h, --help                 Show this message
EOF
}

SKIP_NOTARIZATION=1
SKIP_NOTARIZATION_EXPLICIT=0
SKIP_DMG=0
ARCHES_VALUE=${ARCHES:-""}
NOTARYTOOL_PROFILE=${NOTARYTOOL_PROFILE:-}
APPLE_ID=${APPLE_ID:-}
APPLE_ID_PASSWORD=${APPLE_ID_PASSWORD:-}
TEAM_ID=${TEAM_ID:-}
APP_IDENTITY=${APP_IDENTITY:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-identity)
      APP_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      NOTARYTOOL_PROFILE="$2"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="$2"
      shift 2
      ;;
    --password)
      APPLE_ID_PASSWORD="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --arches)
      ARCHES_VALUE="$2"
      shift 2
      ;;
    --skip-dmg)
      SKIP_DMG=1
      shift
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=1
      SKIP_NOTARIZATION_EXPLICIT=1
      shift
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

if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application: Victor Vannara \\(DA63W2Y8BK\\)/ {print $2; exit}')
fi
if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/ {print $2; exit}')
fi
if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY="Developer ID Application: Victor Vannara (DA63W2Y8BK)"
fi
if [[ -z "$APP_IDENTITY" ]]; then
  echo "Set APP_IDENTITY to your Developer ID Application identity." >&2
  echo "Example: APP_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"" >&2
  exit 1
fi
if [[ "$APP_IDENTITY" == *"Apple Development"* ]]; then
  echo "APP_IDENTITY must be a Developer ID Application identity for release notarization." >&2
  echo "Current: $APP_IDENTITY" >&2
  exit 1
fi

KEY_PATH=""
NOTARY_ARGS=()
if [[ $SKIP_NOTARIZATION_EXPLICIT -eq 0 ]]; then
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    SKIP_NOTARIZATION=0
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
  elif [[ -n "$APPLE_ID" && -n "$APPLE_ID_PASSWORD" && -n "$TEAM_ID" ]]; then
    SKIP_NOTARIZATION=0
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_ID_PASSWORD" --team-id "$TEAM_ID")
  elif [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    SKIP_NOTARIZATION=0
    if [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ]]; then
      KEY_PATH="/tmp/chromastage-api-key.p8"
      echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$KEY_PATH"
    elif [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
      KEY_PATH="$APP_STORE_CONNECT_API_KEY_PATH"
    else
      echo "Set APP_STORE_CONNECT_API_KEY_P8 (contents) or APP_STORE_CONNECT_API_KEY_PATH (file path)." >&2
      exit 1
    fi
    NOTARY_ARGS=(--key "$KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
  fi
fi

cleanup() {
  if [[ "$KEY_PATH" == "/tmp/chromastage-api-key.p8" ]]; then
    rm -f "$KEY_PATH"
  fi
  rm -f "/tmp/${APP_NAME}Notarize.zip"
}
trap cleanup EXIT

if [[ -z "$ARCHES_VALUE" ]]; then
  ARCHES_VALUE="arm64 x86_64"
fi

xcodebuild \
  -project "$ROOT/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$ROOT/Build" \
  ARCHS="$ARCHES_VALUE" \
  ONLY_ACTIVE_ARCH=NO \
  build

APP_BUNDLE="$ROOT/Build/Build/Products/$CONFIGURATION/${APP_NAME}.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle at $APP_BUNDLE" >&2
  exit 1
fi

MARKETING_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION="0.0.0"
fi
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
DMG_NAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
DMG_PATH="$ROOT/$DMG_NAME"

SIGN_ARGS_BASE=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-}
APP_SIGN_ARGS=("${SIGN_ARGS_BASE[@]}")
if [[ -n "$APP_ENTITLEMENTS" ]]; then
  if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
    echo "Entitlements file not found: $APP_ENTITLEMENTS" >&2
    exit 1
  fi
  APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")
fi

sign_item() {
  codesign "${SIGN_ARGS_BASE[@]}" "$1"
}

if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw; do
    sign_item "$fw"
  done < <(find "$APP_BUNDLE/Contents/Frameworks" -name "*.framework" -print0)
  while IFS= read -r -d '' dylib; do
    sign_item "$dylib"
  done < <(find "$APP_BUNDLE/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
fi

if [[ -d "$APP_BUNDLE/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' appex; do
    sign_item "$appex"
  done < <(find "$APP_BUNDLE/Contents/PlugIns" -name "*.appex" -print0)
fi

if [[ -d "$APP_BUNDLE/Contents/XPCServices" ]]; then
  while IFS= read -r -d '' xpc; do
    sign_item "$xpc"
  done < <(find "$APP_BUNDLE/Contents/XPCServices" -name "*.xpc" -print0)
fi

if [[ -d "$APP_BUNDLE/Contents/MacOS" ]]; then
  while IFS= read -r -d '' bin; do
    sign_item "$bin"
  done < <(find "$APP_BUNDLE/Contents/MacOS" -type f -perm +111 -print0)
fi

codesign "${APP_SIGN_ARGS[@]}" "$APP_BUNDLE"

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

# --- Create DMG -------------------------------------------------------------

if [[ $SKIP_DMG -eq 0 ]]; then
  echo "Creating DMG"
  DMG_RW_PATH="/tmp/${APP_NAME}-rw.dmg"
  DMG_MOUNT="/tmp/${APP_NAME}-dmg"
  rm -f "$DMG_RW_PATH" "$DMG_PATH"
  mkdir -p "$DMG_MOUNT"

  APP_SIZE_KB=$(du -sk "$APP_BUNDLE" | awk '{print $1}')
  DMG_SIZE_MB=$(((APP_SIZE_KB + 10240 + 1023) / 1024))
  if [[ $DMG_SIZE_MB -lt 50 ]]; then
    DMG_SIZE_MB=50
  fi

  hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs APFS \
    -volname "$APP_NAME" \
    "$DMG_RW_PATH" \
    >/dev/null

  hdiutil attach "$DMG_RW_PATH" \
    -mountpoint "$DMG_MOUNT" \
    -nobrowse \
    >/dev/null

  cleanup_dmg_mount() {
    hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
  }
  trap cleanup_dmg_mount EXIT INT TERM

  ditto "$APP_BUNDLE" "$DMG_MOUNT/${APP_NAME}.app"
  ln -s /Applications "$DMG_MOUNT/Applications"

  hdiutil detach "$DMG_MOUNT" >/dev/null
  trap - EXIT INT TERM

  hdiutil convert "$DMG_RW_PATH" \
    -format UDZO \
    -o "$DMG_PATH" \
    >/dev/null
  rm -f "$DMG_RW_PATH"
else
  echo "Skipping DMG creation"
fi

if [[ $SKIP_NOTARIZATION -eq 0 ]]; then
  NOTARY_TARGET="/tmp/${APP_NAME}Notarize.zip"
  if [[ $SKIP_DMG -eq 0 ]]; then
    NOTARY_TARGET="$DMG_PATH"
  fi

  xcrun notarytool submit "$NOTARY_TARGET" \
    "${NOTARY_ARGS[@]}" \
    --wait

  xcrun stapler staple "$APP_BUNDLE"
  if [[ $SKIP_DMG -eq 0 ]]; then
    xcrun stapler staple "$DMG_PATH" >/dev/null || true
  fi
fi

xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
if [[ $SKIP_NOTARIZATION -eq 0 ]]; then
  spctl -a -t exec -vv "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  if [[ $SKIP_DMG -eq 0 ]]; then
    xcrun stapler validate "$DMG_PATH" >/dev/null || true
  fi
fi

echo "Done: $ZIP_NAME"
if [[ $SKIP_DMG -eq 0 ]]; then
  echo "Done: $DMG_NAME"
fi
